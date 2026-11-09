//! 종료 전 저장 (BUG-10, BUG-35).
//!
//! ⌘Q, Dock "종료", 로그아웃·재시동, AppleScript `quit`은 모두 NSApp `terminate:`로 들어온다.
//! tao의 앱 delegate에는 `applicationShouldTerminate:`가 없어서, 그대로 두면 창들이 남은 입력을
//! 저장할 틈 없이 앱이 끝난다. 그래서 시작할 때 이 메서드를 delegate 클래스에 붙인다.
//!
//! 1. 종료 요청 → `NSTerminateLater`로 답하고 모든 창에 `app-will-quit`을 보낸다.
//! 2. 창마다 남은 입력을 저장하고 `quit_ready(unsaved)`로 알린다.
//! 3. 모든 창이 답하면(또는 QUIT_TIMEOUT이 지나면) 종료를 허락한다.
//!    - 저장하지 못한 입력이 있으면 한 번은 종료를 멈추고 `quit-cancelled`를 보낸다.
//!    - 그 뒤 다시 종료하면 저장 결과와 관계없이 끝낸다(디스크 고장 등으로 영영 못 끄는 일을 막는다).

use crate::{AppState, show_main_window};
use objc2::runtime::{AnyObject, Bool, Imp, Sel};
use objc2::{class, msg_send, sel};
use std::collections::HashSet;
use std::sync::atomic::Ordering;
use std::sync::{LazyLock, Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

/// 답하지 않는 창(멈춘 웹뷰 등)을 기다리는 최대 시간. 로그아웃을 오래 막지 않도록 짧게 둔다.
const QUIT_TIMEOUT: Duration = Duration::from_secs(4);

// NSApplicationTerminateReply
const NS_TERMINATE_CANCEL: usize = 0;
const NS_TERMINATE_NOW: usize = 1;
const NS_TERMINATE_LATER: usize = 2;

/// 저장을 기다리는 한 번의 종료 요청
struct Round {
    id: u64,
    waiting: HashSet<String>,
    unsaved: u32,
    /// 지난 종료를 저장 실패로 멈췄다 — 이번에는 그대로 끝낸다
    force: bool,
}

#[derive(Default)]
struct QuitState {
    round: Option<Round>,
    next_id: u64,
    /// 종료를 허락했다 — 다시 들어오면 바로 끝낸다
    approved: bool,
    force_next: bool,
}

static APP: OnceLock<AppHandle> = OnceLock::new();
static STATE: LazyLock<Mutex<QuitState>> = LazyLock::new(Mutex::default);

macro_rules! trace {
    ($($t:tt)*) => {
        if cfg!(debug_assertions) {
            eprintln!("[quit] {}", format!($($t)*));
        }
    };
}

fn ns_app() -> *mut AnyObject {
    unsafe { msg_send![class!(NSApplication), sharedApplication] }
}

/// 앱 delegate에 `applicationShouldTerminate:`를 붙인다. 메인 스레드(setup)에서 부른다.
pub fn install(app: &AppHandle) {
    let _ = APP.set(app.clone());
    unsafe {
        let ns_app = ns_app();
        let delegate: *mut AnyObject = msg_send![ns_app, delegate];
        let Some(delegate_ref) = delegate.as_ref() else {
            eprintln!("[quit] 앱 delegate가 없어 종료 전 저장을 설치하지 못했습니다");
            return;
        };
        let cls = delegate_ref.class() as *const _ as *mut objc2::runtime::AnyClass;
        let f: extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject) -> usize = should_terminate;
        let imp: Imp = std::mem::transmute(f);
        // 반환 NSUInteger(Q), self(@), _cmd(:), sender(@)
        let added = objc2::ffi::class_addMethod(cls, sel!(applicationShouldTerminate:), imp, c"Q@:@".as_ptr());
        if !added.as_bool() {
            eprintln!("[quit] applicationShouldTerminate:가 이미 있어 붙이지 못했습니다");
            return;
        }
        // AppKit은 setDelegate: 때 delegate가 응답하는 메서드를 기억해 두므로 같은 객체로 다시 지정한다
        let _: () = msg_send![ns_app, setDelegate: delegate];
    }
    trace!("설치함");
}

/// 메뉴의 종료(⌘Q)도 같은 경로로 보낸다. 메인 스레드에서 부른다.
///
/// `terminate:`를 여기서 바로 부르면 안 된다. 메뉴 이벤트와 `run_on_main_thread`는 tao 이벤트 처리
/// 안에서 실행되는데, `NSTerminateLater`면 `terminate:`가 모달 런 루프를 돌며 답을 기다린다. 그동안
/// tao는 처리 중이라 새 `run_on_main_thread`(= `replyToApplicationShouldTerminate:`)를 실행하지 않아
/// 앱이 멈춘다(MC-02). 그래서 런 루프 다음 차례로 미뤄 tao 처리 밖에서 부르게 한다.
pub fn request() {
    unsafe {
        let _: () = msg_send![
            ns_app(),
            performSelector: sel!(terminate:),
            withObject: std::ptr::null_mut::<AnyObject>(),
            afterDelay: 0.0f64
        ];
    }
}

pub fn is_approved() -> bool {
    STATE.lock().unwrap().approved
}

extern "C-unwind" fn should_terminate(_this: &AnyObject, _sel: Sel, _sender: *mut AnyObject) -> usize {
    let Some(app) = APP.get() else { return NS_TERMINATE_NOW };
    let mut s = STATE.lock().unwrap();
    if s.approved {
        return NS_TERMINATE_NOW;
    }
    if s.round.is_some() {
        // 이미 저장을 기다리는 중이다. 그 결과로 끝난다
        return NS_TERMINATE_CANCEL;
    }
    let waiting: HashSet<String> = app.webview_windows().into_keys().collect();
    if waiting.is_empty() {
        s.approved = true;
        return NS_TERMINATE_NOW;
    }
    s.next_id += 1;
    let id = s.next_id;
    let force = std::mem::take(&mut s.force_next);
    trace!("요청 #{id}: 창 {}개에 저장을 맡김 (force={force})", waiting.len());
    s.round = Some(Round { id, waiting, unsaved: 0, force });
    drop(s);

    // 종료 중에는 메인 창 닫기를 막지 않는다
    app.state::<AppState>().quitting.store(true, Ordering::SeqCst);
    let _ = app.emit("app-will-quit", ());
    let handle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(QUIT_TIMEOUT);
        finish(&handle, id);
    });
    NS_TERMINATE_LATER
}

/// 창 하나가 남은 입력 저장을 끝냈다
pub fn ready(app: &AppHandle, label: &str, unsaved: u32) {
    let mut s = STATE.lock().unwrap();
    let Some(r) = s.round.as_mut() else { return };
    r.waiting.remove(label);
    r.unsaved += unsaved;
    trace!("{label} 저장 끝 (못 한 것 {unsaved}), 남은 창 {}", r.waiting.len());
    if r.waiting.is_empty() {
        let id = r.id;
        drop(s);
        finish(app, id);
    }
}

/// 종료를 허락하거나 멈춘다. 같은 요청에 두 번 불려도(시간 초과와 마지막 응답) 한 번만 처리한다.
fn finish(app: &AppHandle, id: u64) {
    let mut s = STATE.lock().unwrap();
    let Some(r) = s.round.take_if(|r| r.id == id) else { return };
    let allow = r.unsaved == 0 || r.force;
    if allow {
        s.approved = true;
    } else {
        s.force_next = true;
    }
    drop(s);
    trace!(
        "요청 #{id}: {} (응답 없는 창 {}, 못 한 것 {})",
        if allow { "종료" } else { "멈춤" },
        r.waiting.len(),
        r.unsaved
    );
    if !allow {
        app.state::<AppState>().quitting.store(false, Ordering::SeqCst);
        show_main_window(app);
        let _ = app.emit("quit-cancelled", r.unsaved);
    }
    let _ = app.run_on_main_thread(move || unsafe {
        let _: () = msg_send![ns_app(), replyToApplicationShouldTerminate: Bool::new(allow)];
    });
}
