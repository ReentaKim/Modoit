//! 스티키 창 = 메모 하나를 꺼내 둔 macOS NSPanel(FR-30, FR-40).
//! - non-activating: 눌러도 다른 앱이 비활성화되지 않는다.
//! - 모든 Spaces와 전체 화면 앱 위에 보인다.
//! - 글을 입력할 때는 key window가 되어 키 입력을 받는다.
//! Rust가 `path → label` 표를 들고 있고, 메모 경로가 바뀌면(entry-moved) 표를 고친다.
//! 패널 조작은 AppKit 규칙에 따라 모두 메인 스레드에서 한다.

use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, Position, Size, WebviewUrl};
use tauri_nspanel::{
    CollectionBehavior, ManagerExt, PanelBuilder, PanelLevel, StyleMask, tauri_panel,
};

tauri_panel! {
    panel!(StickyPanel {
        config: {
            // 테두리 없는 창은 기본적으로 key window가 될 수 없으므로 열어 준다
            can_become_key_window: true,
            can_become_main_window: false
        }
    })
}

const LABEL_PREFIX: &str = "sticky-";
const MIN_W: f64 = 160.0;
const MIN_H: f64 = 120.0;
/// 끌 수 있는 상단 막대 높이(디자인 7장)
const BAR_H: f64 = 28.0;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Geometry {
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub w: f64,
    pub h: f64,
    #[serde(default)]
    pub on_top: bool,
}

/// 열린 스티키 표. 앱 상태로 관리한다.
#[derive(Default)]
pub struct Stickies {
    by_path: Mutex<HashMap<String, String>>,
    next: AtomicU64,
}

impl Stickies {
    fn label_of(&self, path: &str) -> Option<String> {
        self.by_path.lock().unwrap().get(path).cloned()
    }

    fn take(&self, path: &str) -> Option<String> {
        self.by_path.lock().unwrap().remove(path)
    }

    fn take_all(&self) -> Vec<String> {
        self.by_path.lock().unwrap().drain().map(|(_, l)| l).collect()
    }

    fn take_under(&self, rel: &str) -> Vec<String> {
        let mut map = self.by_path.lock().unwrap();
        let keys: Vec<String> = map.keys().filter(|p| is_self_or_under(p, rel)).cloned().collect();
        keys.into_iter().filter_map(|k| map.remove(&k)).collect()
    }

    fn forget_label(&self, label: &str) {
        self.by_path.lock().unwrap().retain(|_, l| l != label);
    }

    /// entry-moved를 반영한다. 폴더면 from/ 접두사를 to/로 바꾼다.
    pub fn entry_moved(&self, from: &str, to: &str, is_dir: bool) {
        let mut map = self.by_path.lock().unwrap();
        let moved: Vec<String> = map
            .keys()
            .filter(|p| if is_dir { is_self_or_under(p, from) } else { p.as_str() == from })
            .cloned()
            .collect();
        for old in moved {
            if let Some(label) = map.remove(&old) {
                map.insert(format!("{to}{}", &old[from.len()..]), label);
            }
        }
    }

    #[cfg(test)]
    fn insert(&self, path: &str, label: &str) {
        self.by_path.lock().unwrap().insert(path.into(), label.into());
    }
}

fn is_self_or_under(p: &str, dir: &str) -> bool {
    p == dir || p.strip_prefix(dir).is_some_and(|r| r.starts_with('/'))
}

/// 상단 막대가 어느 모니터 안에 충분히(가로 40, 세로 14 이상)보이는가(BUG-12).
/// 모니터 목록을 못 얻으면 위치를 믿는다.
pub fn bar_visible(x: f64, y: f64, w: f64, monitors: &[(f64, f64, f64, f64)]) -> bool {
    if monitors.is_empty() {
        return true;
    }
    let overlap = |a0: f64, a1: f64, b0: f64, b1: f64| (a1.min(b1) - a0.max(b0)).max(0.0);
    monitors.iter().any(|&(mx, my, mw, mh)| {
        overlap(x, x + w, mx, mx + mw) >= w.min(40.0) && overlap(y, y + BAR_H, my, my + mh) >= 14.0
    })
}

fn monitor_rects(app: &AppHandle) -> Vec<(f64, f64, f64, f64)> {
    app.available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| {
            let s = m.scale_factor();
            let p = m.position();
            let z = m.size();
            (p.x as f64 / s, p.y as f64 / s, z.width as f64 / s, z.height as f64 / s)
        })
        .collect()
}

fn level_for(on_top: bool) -> i64 {
    if on_top { PanelLevel::Floating.value() } else { PanelLevel::Normal.value() }
}

fn build_panel(app: &AppHandle, label: &str, path: &str, g: &Geometry, fresh: bool) -> Result<(), String> {
    // 창이 어떤 메모를 여는지, ⌘⇧N으로 방금 만든 메모인지(BUG-23) 페이지에 미리 알려 준다
    let init = format!(
        "window.__MODOIT_STICKY__ = {}; window.__MODOIT_STICKY_FRESH__ = {};",
        serde_json::to_string(path).map_err(|e| e.to_string())?,
        fresh
    );
    let w = g.w.max(MIN_W);
    let h = g.h.max(MIN_H);
    let mut b = PanelBuilder::<_, StickyPanel>::new(app, label)
        .url(WebviewUrl::App("index.html".into()))
        .title("Sticky")
        .size(Size::Logical(LogicalSize::new(w, h)))
        .min_size(Size::Logical(LogicalSize::new(MIN_W, MIN_H)))
        .resizable(true)
        .floating(g.on_top)
        .level(if g.on_top { PanelLevel::Floating } else { PanelLevel::Normal })
        .has_shadow(true)
        .hides_on_deactivate(false)
        .becomes_key_only_if_needed(false)
        .works_when_modal(true)
        .add_style_mask(StyleMask::empty().nonactivating_panel())
        .collection_behavior(CollectionBehavior::new().can_join_all_spaces().full_screen_auxiliary())
        .transparent(true)
        .with_window(move |wb| {
            wb.initialization_script(&init)
                .decorations(false)
                .transparent(true)
                .shadow(true)
                .visible(false)
                // 비활성 상태에서도 첫 클릭이 버튼에 바로 전달되게 한다
                .accept_first_mouse(true)
                // HTML5 끌어 놓기(Finder 이미지 등)를 webview가 직접 받는다
                .disable_drag_drop_handler()
        });
    // 저장된 위치가 연결된 모니터 밖이면 OS 기본 위치를 쓴다(BUG-12)
    if let (Some(x), Some(y)) = (g.x, g.y) {
        if bar_visible(x, y, w, &monitor_rects(app)) {
            b = b.position(Position::Logical(LogicalPosition::new(x, y)));
        }
    }
    let panel = b.build().map_err(|e| e.to_string())?;
    panel.show();
    Ok(())
}

/// 메모를 스티키로 띄운다. 이미 열려 있으면 앞으로 가져온다.
pub fn open(app: &AppHandle, path: &str, g: Geometry, fresh: bool) -> Result<(), String> {
    let reg = app.state::<Stickies>();
    if let Some(label) = reg.label_of(path) {
        if app.get_webview_window(&label).is_some() {
            let app2 = app.clone();
            return app
                .run_on_main_thread(move || {
                    if let Ok(p) = app2.get_webview_panel(&label) {
                        p.show();
                    }
                })
                .map_err(|e| e.to_string());
        }
        reg.take(path);
    }
    let label = format!("{LABEL_PREFIX}{}", reg.next.fetch_add(1, Ordering::Relaxed) + 1);
    // 두 번 연달아 불려도 창이 하나만 생기도록 먼저 표에 넣는다
    reg.by_path.lock().unwrap().insert(path.to_string(), label.clone());
    let app2 = app.clone();
    let path = path.to_string();
    app.run_on_main_thread(move || {
        if let Err(e) = build_panel(&app2, &label, &path, &g, fresh) {
            eprintln!("스티키 창을 만들지 못했습니다({path}): {e}");
            app2.state::<Stickies>().forget_label(&label);
        }
    })
    .map_err(|e| e.to_string())
}

fn close_labels(app: &AppHandle, labels: Vec<String>) {
    if labels.is_empty() {
        return;
    }
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        for label in labels {
            // 패널 클래스를 원래 창 클래스로 되돌린 뒤 닫는다(tauri-nspanel 권장 방식)
            let window = match app2.get_webview_panel(&label) {
                Ok(p) => p.to_window(),
                Err(_) => app2.get_webview_window(&label),
            };
            if let Some(w) = window {
                let _ = w.close();
            }
        }
    });
}

pub fn close(app: &AppHandle, path: &str) {
    let labels = app.state::<Stickies>().take(path).into_iter().collect();
    close_labels(app, labels);
}

/// 그 경로이거나 그 폴더 아래에 있는 스티키를 모두 닫는다(휴지통으로 보낼 때).
pub fn close_under(app: &AppHandle, rel: &str) {
    let labels = app.state::<Stickies>().take_under(rel);
    close_labels(app, labels);
}

/// 열린 스티키 창을 모두 닫는다(저장 폴더를 바꿀 때, BUG-09).
pub fn close_all(app: &AppHandle) {
    let mut labels = app.state::<Stickies>().take_all();
    for label in app.webview_windows().into_keys() {
        if label.starts_with(LABEL_PREFIX) && !labels.contains(&label) {
            labels.push(label);
        }
    }
    close_labels(app, labels);
}

pub fn set_on_top(app: &AppHandle, path: &str, on_top: bool) -> Result<(), String> {
    let Some(label) = app.state::<Stickies>().label_of(path) else {
        return Err(format!("열려 있지 않은 스티키입니다: {path}"));
    };
    let app2 = app.clone();
    app.run_on_main_thread(move || {
        if let Ok(p) = app2.get_webview_panel(&label) {
            p.set_floating_panel(on_top);
            p.set_level(level_for(on_top));
        }
    })
    .map_err(|e| e.to_string())
}

/// 그 메모의 스티키 창이 지금 화면에 떠 있는지 (BUG-36). 숨겨 둔 창은 떠 있지 않은 것으로 본다
pub fn is_open(app: &AppHandle, path: &str) -> bool {
    app.state::<Stickies>()
        .label_of(path)
        .and_then(|label| app.get_webview_window(&label))
        .is_some_and(|w| w.is_visible().unwrap_or(false))
}

/// 창을 닫지 않고 숨긴다. 스크립트가 늦은(가려진) 스티키에 다시 넣기를 요청했을 때,
/// 입력을 잃지 않도록 창은 살려 두고 화면에서만 치운다. 스티키가 깨어나면 저장한 뒤 스스로 닫는다 (BUG-42)
pub fn hide(app: &AppHandle, path: &str) -> Result<(), String> {
    let Some(label) = app.state::<Stickies>().label_of(path) else {
        return Ok(());
    };
    let app2 = app.clone();
    app.run_on_main_thread(move || {
        if let Ok(p) = app2.get_webview_panel(&label) {
            p.hide();
        }
    })
    .map_err(|e| e.to_string())
}

/// 스티키 창이 어떤 경로로든 닫혀 사라졌을 때 표와 패널 저장소를 정리한다.
pub fn on_destroyed(app: &AppHandle, label: &str) {
    if !label.starts_with(LABEL_PREFIX) {
        return;
    }
    app.state::<Stickies>().forget_label(label);
    let _ = app.remove_webview_panel(label);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_moved_updates_paths() {
        let s = Stickies::default();
        s.insert("업무/a.md", "sticky-1");
        s.insert("업무/회의/b.md", "sticky-2");
        s.insert("업무-2024/c.md", "sticky-3");
        s.entry_moved("업무/a.md", "업무/가.md", false);
        assert_eq!(s.label_of("업무/가.md").as_deref(), Some("sticky-1"));
        assert!(s.label_of("업무/a.md").is_none());
        s.entry_moved("업무", "보관/업무", true);
        assert_eq!(s.label_of("보관/업무/가.md").as_deref(), Some("sticky-1"));
        assert_eq!(s.label_of("보관/업무/회의/b.md").as_deref(), Some("sticky-2"));
        assert_eq!(s.label_of("업무-2024/c.md").as_deref(), Some("sticky-3"));
        let mut under = s.take_under("보관");
        under.sort();
        assert_eq!(under, vec!["sticky-1", "sticky-2"]);
        s.forget_label("sticky-3");
        assert!(s.take_all().is_empty());
    }

    #[test]
    fn offscreen_positions_are_rejected() {
        let mons = [(0.0, 0.0, 1440.0, 900.0), (1440.0, -200.0, 1920.0, 1080.0)];
        assert!(bar_visible(100.0, 100.0, 260.0, &mons));
        assert!(bar_visible(1500.0, -150.0, 260.0, &mons));
        // 떼어 낸 모니터 자리
        assert!(!bar_visible(3500.0, 100.0, 260.0, &mons));
        assert!(!bar_visible(-600.0, 100.0, 260.0, &mons));
        // 막대가 화면 아래로 빠짐
        assert!(!bar_visible(100.0, 895.0, 260.0, &mons[..1]));
        // 왼쪽 끝에 조금만 걸침(40 미만)
        assert!(!bar_visible(-230.0, 100.0, 260.0, &mons[..1]));
        assert!(bar_visible(-200.0, 100.0, 260.0, &mons[..1]));
        assert!(bar_visible(5000.0, 5000.0, 260.0, &[]));
    }
}
