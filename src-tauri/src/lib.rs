//! Modoit 백엔드 진입점. 명령·이벤트는 docs/dev/api-v0.2.md 계약서를 따른다.

mod config;
mod layout;
mod sticky;
mod vault;
mod watcher;

use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WindowEvent, Wry};

const MAIN: &str = "main";
/// ⌘Q 뒤 창들이 남은 입력을 저장할 시간(BUG-10)
const QUIT_GRACE: Duration = Duration::from_millis(700);

pub struct AppState {
    vault: Mutex<Option<PathBuf>>,
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    config: Mutex<config::Config>,
    quitting: AtomicBool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct EntryMoved {
    from: String,
    to: String,
    is_dir: bool,
}

#[derive(Serialize, Clone)]
struct OpenNote {
    path: String,
}

fn current_vault(state: &State<AppState>) -> Result<PathBuf, String> {
    state
        .vault
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "저장 폴더가 지정되지 않았습니다".to_string())
}

/// 저장 폴더를 바꾼다: 감시를 다시 시작하고 에셋 프로토콜 범위를 연다.
fn activate_vault(app: &AppHandle, state: &State<AppState>, path: PathBuf) -> Result<(), String> {
    if !path.is_dir() {
        return Err(format!("폴더를 찾을 수 없습니다: {}", path.display()));
    }
    app.asset_protocol_scope()
        .allow_directory(&path, true)
        .map_err(|e| e.to_string())?;
    *state.watcher.lock().unwrap() = watcher::watch(app.clone(), &path).ok();
    *state.vault.lock().unwrap() = Some(path);
    Ok(())
}

/// 경로가 바뀌었으면 스티키 표를 고치고 entry-moved를 보낸다.
fn announce_move(app: &AppHandle, from: &str, to: &str, is_dir: bool) {
    if from == to {
        return;
    }
    app.state::<sticky::Stickies>().entry_moved(from, to, is_dir);
    let _ = app.emit(
        "entry-moved",
        EntryMoved { from: from.to_string(), to: to.to_string(), is_dir },
    );
}

fn show_main_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(MAIN) {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

// ───────────────────────── 명령 ─────────────────────────

#[tauri::command]
fn get_vault(state: State<AppState>) -> Option<String> {
    state
        .vault
        .lock()
        .unwrap()
        .as_ref()
        .map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn set_vault(app: AppHandle, state: State<AppState>, path: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    // 이전 저장 폴더의 스티키가 새 폴더에 쓰지 않도록 모두 닫는다(BUG-09)
    sticky::close_all(&app);
    activate_vault(&app, &state, path.clone())?;
    // 비어 있는 폴더라면 기본 "메모" 폴더를 만들어 둔다
    let tree = vault::list_tree(&path)?;
    if tree.folders.is_empty() && tree.notes.is_empty() {
        std::fs::create_dir_all(path.join(vault::DEFAULT_FOLDER)).map_err(|e| e.to_string())?;
    }
    let mut cfg = state.config.lock().unwrap();
    cfg.vault = Some(path.to_string_lossy().into_owned());
    config::save(&app, &cfg)
}

#[tauri::command]
fn get_prefs(state: State<AppState>) -> config::Prefs {
    state.config.lock().unwrap().prefs.clone()
}

#[tauri::command]
fn set_prefs(app: AppHandle, state: State<AppState>, prefs: config::Prefs) -> Result<(), String> {
    let prefs = prefs.normalized();
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.prefs = prefs.clone();
        config::save(&app, &cfg)?;
    }
    config::apply_theme(&app, &prefs);
    let _ = app.emit("prefs-changed", prefs);
    Ok(())
}

#[tauri::command(async)]
fn list_tree(state: State<'_, AppState>) -> Result<vault::Tree, String> {
    vault::list_tree(&current_vault(&state)?)
}

#[tauri::command(async)]
fn read_note(state: State<'_, AppState>, path: String) -> Result<String, String> {
    vault::read_note(&current_vault(&state)?, &path)
}

#[tauri::command(async)]
fn write_note(state: State<'_, AppState>, path: String, content: String) -> Result<(), String> {
    let full = vault::resolve(&current_vault(&state)?, &path)?;
    vault::atomic_write(&full, &content)
}

#[tauri::command(async)]
fn create_note(state: State<'_, AppState>, folder: String) -> Result<String, String> {
    vault::create_note(&current_vault(&state)?, &folder)
}

#[tauri::command(async)]
fn sync_note_name(app: AppHandle, state: State<'_, AppState>, path: String) -> Result<String, String> {
    let v = current_vault(&state)?;
    let from = vault::to_rel(&v, &vault::resolve(&v, &path)?);
    let to = vault::sync_note_name(&v, &from)?;
    announce_move(&app, &from, &to, false);
    Ok(to)
}

#[tauri::command(async)]
fn trash_note(app: AppHandle, state: State<'_, AppState>, path: String) -> Result<(), String> {
    let v = current_vault(&state)?;
    let full = vault::resolve(&v, &path)?;
    vault::trash_path(&full)?;
    sticky::close(&app, &vault::to_rel(&v, &full));
    Ok(())
}

#[tauri::command(async)]
fn create_folder(state: State<'_, AppState>, parent: String, name: String) -> Result<String, String> {
    vault::create_folder(&current_vault(&state)?, &parent, &name)
}

#[tauri::command(async)]
fn rename_folder(app: AppHandle, state: State<'_, AppState>, path: String, name: String) -> Result<String, String> {
    let v = current_vault(&state)?;
    let from = vault::to_rel(&v, &vault::resolve_dir(&v, &path)?);
    let to = vault::rename_folder(&v, &from, &name)?;
    announce_move(&app, &from, &to, true);
    Ok(to)
}

#[tauri::command(async)]
fn trash_folder(app: AppHandle, state: State<'_, AppState>, path: String) -> Result<(), String> {
    let v = current_vault(&state)?;
    let rel = vault::to_rel(&v, &vault::resolve_dir(&v, &path)?);
    vault::trash_folder(&v, &rel)?;
    sticky::close_under(&app, &rel);
    Ok(())
}

#[tauri::command(async)]
fn move_entry(app: AppHandle, state: State<'_, AppState>, from: String, to_folder: String) -> Result<String, String> {
    let m = vault::move_entry(&current_vault(&state)?, &from, &to_folder)?;
    announce_move(&app, &m.from, &m.to, m.is_dir);
    Ok(m.to)
}

#[tauri::command(async)]
fn set_layout(state: State<'_, AppState>, layout: layout::Layout) -> Result<(), String> {
    layout::save(&current_vault(&state)?, &layout)
}

#[tauri::command(async)]
fn save_attachment(
    state: State<'_, AppState>,
    note_path: String,
    file_name: String,
    data_base64: String,
) -> Result<String, String> {
    vault::save_attachment(&current_vault(&state)?, &note_path, &file_name, &data_base64)
}

#[tauri::command]
fn open_sticky(
    app: AppHandle,
    state: State<AppState>,
    path: String,
    geom: sticky::Geometry,
    fresh: Option<bool>,
) -> Result<(), String> {
    let v = current_vault(&state)?;
    let full = vault::resolve(&v, &path)?;
    if !full.is_file() {
        return Err(format!("메모를 찾을 수 없습니다: {path}"));
    }
    sticky::open(&app, &vault::to_rel(&v, &full), geom, fresh.unwrap_or(false))
}

#[tauri::command]
fn has_sticky_window(app: AppHandle, path: String) -> bool {
    sticky::is_open(&app, &path)
}

#[tauri::command]
fn hide_sticky_window(app: AppHandle, path: String) -> Result<(), String> {
    sticky::hide(&app, &path)
}

#[tauri::command]
fn close_sticky_window(app: AppHandle, path: String) {
    sticky::close(&app, &path);
}

#[tauri::command]
fn set_sticky_on_top(app: AppHandle, path: String, on_top: bool) -> Result<(), String> {
    sticky::set_on_top(&app, &path, on_top)
}

#[tauri::command]
fn show_main(app: AppHandle, path: Option<String>) {
    show_main_window(&app);
    if let Some(path) = path {
        let _ = app.emit("open-note", OpenNote { path });
    }
}

// ───────────────────────── 메뉴 막대 (디자인 9장, FR-41) ─────────────────────────

/// 메인 창에서 결과가 보여야 하는 메뉴. 메인 창이 숨어 있으면 먼저 보인다.
// 모양 메뉴(theme-*)도 메인 창이 설정을 저장하므로 메인 창이 받는다
const MENU_NEEDS_MAIN: [&str; 7] =
    ["new-note", "new-folder", "find", "settings", "about", "change-vault", "toggle-sidebar"];

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let item = |id: &str, text: &str, accel: Option<&str>| MenuItem::with_id(app, id, text, true, accel);
    let sep = || PredefinedMenuItem::separator(app);

    let app_menu = Submenu::with_items(
        app,
        "Modoit",
        true,
        &[
            &item("about", "Modoit 정보", None)?,
            &sep()?,
            &item("settings", "설정…", Some("CmdOrCtrl+,"))?,
            &sep()?,
            &PredefinedMenuItem::services(app, Some("서비스"))?,
            &sep()?,
            &PredefinedMenuItem::hide(app, Some("Modoit 가리기"))?,
            &PredefinedMenuItem::hide_others(app, Some("기타 가리기"))?,
            &PredefinedMenuItem::show_all(app, Some("모두 보기"))?,
            &sep()?,
            // 기본 종료(terminate:)는 ExitRequested를 거치지 않아 저장 기회가 없으므로 직접 처리한다
            &item("quit", "Modoit 종료", Some("CmdOrCtrl+Q"))?,
        ],
    )?;
    let file_menu = Submenu::with_items(
        app,
        "파일",
        true,
        &[
            &item("new-note", "새 메모", Some("CmdOrCtrl+N"))?,
            &item("new-sticky-note", "새 스티키 메모", Some("CmdOrCtrl+Shift+N"))?,
            &item("new-folder", "새 폴더", Some("Alt+CmdOrCtrl+N"))?,
            &sep()?,
            &item("pop-out", "스티키로 꺼내기", Some("CmdOrCtrl+Shift+S"))?,
            &item("toggle-pin", "고정", Some("CmdOrCtrl+Shift+P"))?,
            &sep()?,
            &item("change-vault", "저장 폴더 변경…", None)?,
        ],
    )?;
    let edit_menu = Submenu::with_items(
        app,
        "편집",
        true,
        &[
            &PredefinedMenuItem::undo(app, Some("실행 취소"))?,
            &PredefinedMenuItem::redo(app, Some("다시 실행"))?,
            &sep()?,
            &PredefinedMenuItem::cut(app, Some("잘라내기"))?,
            &PredefinedMenuItem::copy(app, Some("복사"))?,
            &PredefinedMenuItem::paste(app, Some("붙여넣기"))?,
            &PredefinedMenuItem::select_all(app, Some("모두 선택"))?,
            &sep()?,
            &item("find", "찾기", Some("CmdOrCtrl+F"))?,
        ],
    )?;
    let view_menu = Submenu::with_items(
        app,
        "보기",
        true,
        &[
            &item("toggle-sidebar", "사이드바 보기·가리기", Some("Alt+CmdOrCtrl+S"))?,
            &sep()?,
            // 모양 (FR-45): 설정 시트 밖에서도 바로 바꿀 수 있게
            &Submenu::with_items(
                app,
                "모양",
                true,
                &[
                    &item("theme-system", "시스템 설정 따르기", None)?,
                    &item("theme-light", "라이트", None)?,
                    &item("theme-dark", "다크", None)?,
                ],
            )?,
        ],
    )?;
    let window_menu = Submenu::with_items(
        app,
        "창",
        true,
        &[
            &PredefinedMenuItem::minimize(app, Some("최소화"))?,
            &PredefinedMenuItem::maximize(app, Some("확대/축소"))?,
            &sep()?,
            &item("show-main", "메인 창", Some("CmdOrCtrl+0"))?,
        ],
    )?;
    let help_menu = Submenu::with_items(app, "도움말", true, &[])?;

    let menu = Menu::with_items(app, &[&app_menu, &file_menu, &edit_menu, &view_menu, &window_menu, &help_menu])?;
    // 창 목록과 도움말 검색 칸은 macOS가 채운다
    window_menu.set_as_windows_menu_for_nsapp()?;
    help_menu.set_as_help_menu_for_nsapp()?;
    Ok(menu)
}

fn on_menu(app: &AppHandle, id: &str) {
    match id {
        "quit" => app.exit(0),
        "show-main" => show_main_window(app),
        // 모양은 Rust가 바로 적용한다. 숨은 메인 창의 스크립트가 늦어도 화면은 즉시 바뀐다 (OBS-11).
        // 설정 저장은 메인 창이 이어서 한다(같은 값으로 한 번 더 적용될 뿐이다)
        "theme-system" | "theme-light" | "theme-dark" => {
            let prefs = config::Prefs { theme: id["theme-".len()..].to_string(), ..Default::default() };
            config::apply_theme(app, &prefs);
            let _ = app.emit("menu", id);
        }
        _ => {
            if MENU_NEEDS_MAIN.contains(&id) {
                show_main_window(app);
            }
            let _ = app.emit("menu", id);
        }
    }
}

// ───────────────────────── 창·앱 이벤트 ─────────────────────────

/// 메인 창 사이드바 뒤로 비치는 macOS 기본 반투명 효과
fn apply_main_window_effects(window: &tauri::WebviewWindow) {
    use window_vibrancy::{NSVisualEffectMaterial, NSVisualEffectState, apply_vibrancy};
    let _ = apply_vibrancy(
        window,
        NSVisualEffectMaterial::Sidebar,
        Some(NSVisualEffectState::FollowsWindowActiveState),
        None,
    );
}

fn on_window_event(window: &tauri::Window, event: &WindowEvent) {
    match event {
        // 빨간 버튼은 메인 창을 숨기기만 한다. 앱과 스티키는 그대로(FR-42)
        WindowEvent::CloseRequested { api, .. } if window.label() == MAIN => {
            if !window.state::<AppState>().quitting.load(Ordering::SeqCst) {
                api.prevent_close();
                let _ = window.hide();
            }
        }
        WindowEvent::Destroyed => sticky::on_destroyed(window.app_handle(), window.label()),
        _ => {}
    }
}

fn on_run_event(app: &AppHandle, event: RunEvent) {
    match event {
        // 독 아이콘을 누르면 메인 창을 다시 보인다(FR-42, BUG-11)
        RunEvent::Reopen { .. } => show_main_window(app),
        // 처음 종료 요청은 막고 창들에 저장을 맡긴 뒤 잠시 후 종료한다(BUG-10)
        RunEvent::ExitRequested { api, .. } => {
            let state = app.state::<AppState>();
            if !state.quitting.swap(true, Ordering::SeqCst) {
                api.prevent_exit();
                let _ = app.emit("app-will-quit", ());
                let app = app.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(QUIT_GRACE);
                    app.exit(0);
                });
            }
        }
        _ => {}
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_nspanel::init())
        .manage(AppState {
            vault: Mutex::new(None),
            watcher: Mutex::new(None),
            config: Mutex::new(config::Config::default()),
            quitting: AtomicBool::new(false),
        })
        .manage(sticky::Stickies::default())
        .setup(|app| {
            let handle = app.handle().clone();
            let cfg = config::load(&handle);
            let state = handle.state::<AppState>();
            if let Some(v) = cfg.vault.clone() {
                if let Err(e) = activate_vault(&handle, &state, PathBuf::from(v)) {
                    eprintln!("저장 폴더를 열지 못했습니다: {e}");
                }
            }
            config::apply_theme(&handle, &cfg.prefs);
            *state.config.lock().unwrap() = cfg;
            app.set_menu(build_menu(&handle)?)?;
            app.on_menu_event(|app, event| on_menu(app, event.id().as_ref()));
            if let Some(main) = app.get_webview_window(MAIN) {
                apply_main_window_effects(&main);
            }
            Ok(())
        })
        .on_window_event(on_window_event)
        .invoke_handler(tauri::generate_handler![
            get_vault,
            set_vault,
            get_prefs,
            set_prefs,
            list_tree,
            read_note,
            write_note,
            create_note,
            sync_note_name,
            trash_note,
            create_folder,
            rename_folder,
            trash_folder,
            move_entry,
            set_layout,
            save_attachment,
            open_sticky,
            has_sticky_window,
            hide_sticky_window,
            close_sticky_window,
            set_sticky_on_top,
            show_main,
        ])
        .build(tauri::generate_context!())
        .expect("error while running tauri application");
    app.run(on_run_event);
}
