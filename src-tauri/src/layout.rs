//! 사이드바 직접 정렬 순서와 구분선(`.modoit/layout.json`).
//! 폴더는 실제 디렉터리라서 순서를 담을 곳이 따로 필요하다(PRD 7장 결정 기록).
//! 파일이 없거나 깨졌으면 기본값으로 동작한다.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const META_DIR: &str = ".modoit";
const LAYOUT_FILE: &str = "layout.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SortMode {
    #[default]
    Custom,
    Name,
    Recent,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Layout {
    pub sort: SortMode,
    /// 부모 폴더 경로("" = 최상위) → 하위 폴더 이름 또는 구분선 id("sep:…")의 순서
    pub order: BTreeMap<String, Vec<String>>,
}

fn file_path(vault: &Path) -> PathBuf {
    vault.join(META_DIR).join(LAYOUT_FILE)
}

pub fn load(vault: &Path) -> Layout {
    std::fs::read_to_string(file_path(vault))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(vault: &Path, layout: &Layout) -> Result<(), String> {
    let json = serde_json::to_string_pretty(layout).map_err(|e| e.to_string())?;
    crate::vault::atomic_write(&file_path(vault), &json)
}

/// 읽고 고친 뒤 바뀐 것이 있을 때만 쓴다(없던 파일을 괜히 만들지 않는다).
pub fn update(vault: &Path, f: impl FnOnce(&mut Layout)) -> Result<(), String> {
    let mut layout = load(vault);
    let before = layout.clone();
    f(&mut layout);
    if layout != before {
        save(vault, &layout)?;
    }
    Ok(())
}

/// "a/b/c" → ("a/b", "c"), "c" → ("", "c")
fn split_parent(rel: &str) -> (&str, &str) {
    match rel.rfind('/') {
        Some(i) => (&rel[..i], &rel[i + 1..]),
        None => ("", rel),
    }
}

fn is_self_or_under(key: &str, dir: &str) -> bool {
    key == dir || key.strip_prefix(dir).is_some_and(|r| r.starts_with('/'))
}

impl Layout {
    /// 폴더 이름 변경·이동(from → to)을 반영한다.
    /// 그 폴더와 하위 폴더의 키를 옮기고, 부모 순서 목록의 이름을 고친다.
    pub fn move_dir(&mut self, from: &str, to: &str) {
        let keys: Vec<String> = self
            .order
            .keys()
            .filter(|k| is_self_or_under(k, from))
            .cloned()
            .collect();
        for k in keys {
            if let Some(v) = self.order.remove(&k) {
                self.order.insert(format!("{to}{}", &k[from.len()..]), v);
            }
        }
        let (from_parent, from_name) = split_parent(from);
        let (to_parent, to_name) = split_parent(to);
        if from_parent == to_parent {
            if let Some(list) = self.order.get_mut(from_parent) {
                for item in list.iter_mut().filter(|i| *i == from_name) {
                    *item = to_name.to_string();
                }
            }
        } else {
            if let Some(list) = self.order.get_mut(from_parent) {
                list.retain(|i| i != from_name);
            }
            // 새 부모에 직접 정렬 목록이 있으면 맨 뒤에 붙여 둔다
            if let Some(list) = self.order.get_mut(to_parent) {
                if !list.iter().any(|i| i == to_name) {
                    list.push(to_name.to_string());
                }
            }
        }
    }

    /// 폴더 삭제를 반영한다. 그 폴더와 하위 키, 부모 목록의 이름을 지운다.
    pub fn remove_dir(&mut self, rel: &str) {
        self.order.retain(|k, _| !is_self_or_under(k, rel));
        let (parent, name) = split_parent(rel);
        if let Some(list) = self.order.get_mut(parent) {
            list.retain(|i| i != name);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Layout {
        let mut l = Layout::default();
        l.order.insert("".into(), vec!["업무".into(), "sep:1".into(), "개인".into()]);
        l.order.insert("업무".into(), vec!["회의".into(), "보고".into()]);
        l.order.insert("업무/회의".into(), vec!["2026".into()]);
        l.order.insert("업무-2024".into(), vec!["x".into()]);
        l
    }

    #[test]
    fn missing_or_broken_file_gives_default() {
        let v = tempfile::tempdir().unwrap();
        assert_eq!(load(v.path()), Layout::default());
        crate::vault::atomic_write(&file_path(v.path()), "{깨진 json").unwrap();
        assert_eq!(load(v.path()), Layout::default());
        // 일부 필드만 있어도 나머지는 기본값
        crate::vault::atomic_write(&file_path(v.path()), r#"{"sort":"name"}"#).unwrap();
        let l = load(v.path());
        assert_eq!(l.sort, SortMode::Name);
        assert!(l.order.is_empty());
    }

    #[test]
    fn save_and_load_roundtrip() {
        let v = tempfile::tempdir().unwrap();
        let mut l = sample();
        l.sort = SortMode::Recent;
        save(v.path(), &l).unwrap();
        assert_eq!(load(v.path()), l);
        let raw = std::fs::read_to_string(file_path(v.path())).unwrap();
        assert!(raw.contains("\"recent\""));
    }

    #[test]
    fn rename_updates_keys_and_parent_order() {
        let mut l = sample();
        l.move_dir("업무", "일");
        assert_eq!(l.order[""], vec!["일", "sep:1", "개인"]);
        assert_eq!(l.order["일"], vec!["회의", "보고"]);
        assert_eq!(l.order["일/회의"], vec!["2026"]);
        // 접두사만 같은 다른 폴더는 그대로
        assert!(l.order.contains_key("업무-2024"));
        assert!(!l.order.contains_key("업무"));
    }

    #[test]
    fn move_to_other_parent_updates_both_lists() {
        let mut l = sample();
        l.move_dir("업무/회의", "개인/회의");
        assert_eq!(l.order["업무"], vec!["보고"]);
        assert_eq!(l.order["개인/회의"], vec!["2026"]);
        // 최상위로 옮기면 최상위 목록 끝에 붙는다
        l.move_dir("개인/회의", "회의");
        assert_eq!(l.order[""], vec!["업무", "sep:1", "개인", "회의"]);
        assert!(l.order.contains_key("회의"));
    }

    #[test]
    fn remove_drops_keys_and_name() {
        let mut l = sample();
        l.remove_dir("업무");
        assert_eq!(l.order[""], vec!["sep:1", "개인"]);
        assert!(!l.order.contains_key("업무"));
        assert!(!l.order.contains_key("업무/회의"));
        assert!(l.order.contains_key("업무-2024"));
    }

    #[test]
    fn update_does_not_create_file_without_change() {
        let v = tempfile::tempdir().unwrap();
        update(v.path(), |l| l.remove_dir("없는폴더")).unwrap();
        assert!(!file_path(v.path()).exists());
    }
}
