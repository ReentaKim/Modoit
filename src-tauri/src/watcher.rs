//! 저장 폴더를 감시하다가 바뀌면 "vault-changed" 이벤트를 모든 창에 보낸다.
//! 짧은 시간에 몰려오는 이벤트는 하나로 묶는다(250ms).
//! `.modoit/` 안의 변경과 임시 파일(`*.modoit-tmp`)만 있는 이벤트는 무시한다.

use notify::{RecursiveMode, Watcher};
use std::path::{Component, Path};
use std::sync::mpsc;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

/// 앱 내부 파일이라 목록 갱신이 필요 없는 경로인가
fn is_internal(p: &Path) -> bool {
    let tmp = p
        .file_name()
        .is_some_and(|n| n.to_string_lossy().ends_with(crate::vault::TMP_SUFFIX));
    let meta = p
        .components()
        .any(|c| matches!(c, Component::Normal(n) if n == crate::layout::META_DIR));
    tmp || meta
}

pub fn watch(app: AppHandle, vault: &Path) -> notify::Result<notify::RecommendedWatcher> {
    let (tx, rx) = mpsc::channel::<()>();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(ev) = res {
            // 경로 없는 이벤트(재검사 요청 등)는 보수적으로 알린다
            if ev.paths.is_empty() || !ev.paths.iter().all(|p| is_internal(p)) {
                let _ = tx.send(());
            }
        }
    })?;
    watcher.watch(vault, RecursiveMode::Recursive)?;

    std::thread::spawn(move || {
        // watcher가 교체되면 tx가 사라지고 recv가 Err를 돌려 스레드가 끝난다
        while rx.recv().is_ok() {
            while rx.recv_timeout(Duration::from_millis(250)).is_ok() {}
            let _ = app.emit("vault-changed", ());
        }
    });
    Ok(watcher)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn internal_paths() {
        assert!(is_internal(Path::new("/v/.modoit/layout.json")));
        assert!(is_internal(Path::new("/v/.modoit")));
        assert!(is_internal(Path::new("/v/메모/.a.md.modoit-tmp")));
        assert!(!is_internal(Path::new("/v/메모/a.md")));
        assert!(!is_internal(Path::new("/v/.modoitx/a.md")));
        assert!(!is_internal(Path::new("/v/attachments/a.png")));
    }
}
