//! 앱 설정(저장 폴더 경로, 화면 설정)을 앱 설정 폴더의 config.json에 보관한다.
//! 읽을 때는 관대하게 읽는다. 설정 일부가 이상해도 저장 폴더 경로는 잃지 않는다.

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

const FONT_FAMILIES: [&str; 5] = ["system", "pretendard", "serif", "mono", "custom"];
const NOTE_SORTS: [&str; 3] = ["modified", "created", "name"];
const THEMES: [&str; 3] = ["system", "light", "dark"];
const ACCENTS: [&str; 8] = ["yellow", "orange", "red", "pink", "purple", "blue", "green", "graphite"];
pub const FONT_SIZE_MIN: f64 = 14.0;
pub const FONT_SIZE_MAX: f64 = 22.0;
pub const FONT_SIZE_DEFAULT: f64 = 17.0;

/// 계약서 1장의 Prefs
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    pub font_family: String,
    pub custom_font: String,
    pub font_size: f64,
    pub sidebar_collapsed: bool,
    pub note_sort: String,
    /// 모양: system | light | dark (FR-45)
    pub theme: String,
    /// 강조 색 이름 (FR-46)
    pub accent: String,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            font_family: "system".into(),
            custom_font: String::new(),
            font_size: FONT_SIZE_DEFAULT,
            sidebar_collapsed: false,
            note_sort: "modified".into(),
            theme: "system".into(),
            accent: "yellow".into(),
        }
    }
}

impl Prefs {
    /// 허용 범위 밖의 값을 기본값이나 경계값으로 바꾼다.
    pub fn normalized(mut self) -> Self {
        let d = Prefs::default();
        if !FONT_FAMILIES.contains(&self.font_family.as_str()) {
            self.font_family = d.font_family;
        }
        if !NOTE_SORTS.contains(&self.note_sort.as_str()) {
            self.note_sort = d.note_sort;
        }
        if !THEMES.contains(&self.theme.as_str()) {
            self.theme = d.theme;
        }
        if !ACCENTS.contains(&self.accent.as_str()) {
            self.accent = d.accent;
        }
        self.font_size = if self.font_size.is_finite() {
            self.font_size.clamp(FONT_SIZE_MIN, FONT_SIZE_MAX)
        } else {
            FONT_SIZE_DEFAULT
        };
        self.custom_font = self.custom_font.trim().to_string();
        self
    }
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct Config {
    pub vault: Option<String>,
    pub prefs: Prefs,
}

impl Config {
    fn from_json(s: &str) -> Self {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(s) else {
            return Self::default();
        };
        let vault = v.get("vault").and_then(|x| x.as_str()).map(str::to_string);
        let prefs = v
            .get("prefs")
            .and_then(|p| serde_json::from_value::<Prefs>(p.clone()).ok())
            .unwrap_or_default()
            .normalized();
        Self { vault, prefs }
    }
}

fn path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("config.json"))
}

pub fn load(app: &AppHandle) -> Config {
    path(app)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|s| Config::from_json(&s))
        .unwrap_or_default()
}

pub fn save(app: &AppHandle, cfg: &Config) -> Result<(), String> {
    let p = path(app).ok_or("설정 폴더를 찾을 수 없습니다")?;
    let json = serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    crate::vault::atomic_write(&p, &json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults() {
        let p = Prefs::default();
        assert_eq!(p.font_family, "system");
        assert_eq!(p.custom_font, "");
        assert_eq!(p.font_size, 17.0);
        assert!(!p.sidebar_collapsed);
        assert_eq!(p.note_sort, "modified");
        let json = serde_json::to_value(&p).unwrap();
        assert_eq!(json["fontFamily"], "system");
        assert_eq!(json["fontSize"], 17.0);
        assert_eq!(json["sidebarCollapsed"], false);
        assert_eq!(json["noteSort"], "modified");
    }

    #[test]
    fn v01_config_keeps_vault() {
        let c = Config::from_json(r#"{"vault":"/tmp/v"}"#);
        assert_eq!(c.vault.as_deref(), Some("/tmp/v"));
        assert_eq!(c.prefs, Prefs::default());
    }

    #[test]
    fn broken_prefs_do_not_lose_vault() {
        let c = Config::from_json(r#"{"vault":"/tmp/v","prefs":{"fontSize":"큼"}}"#);
        assert_eq!(c.vault.as_deref(), Some("/tmp/v"));
        assert_eq!(c.prefs, Prefs::default());
        let c = Config::from_json(r#"{"vault":"/tmp/v","prefs":{"fontSize":40,"fontFamily":"comic","noteSort":"x","sidebarCollapsed":true}}"#);
        assert_eq!(c.prefs.font_size, 22.0);
        assert_eq!(c.prefs.font_family, "system");
        assert_eq!(c.prefs.note_sort, "modified");
        assert!(c.prefs.sidebar_collapsed);
        assert_eq!(Config::from_json("깨짐").vault, None);
    }

    #[test]
    fn partial_prefs_from_frontend() {
        let p: Prefs = serde_json::from_str(r#"{"fontFamily":"custom","customFont":" D2Coding "}"#).unwrap();
        let p = p.normalized();
        assert_eq!(p.font_family, "custom");
        assert_eq!(p.custom_font, "D2Coding");
        assert_eq!(p.font_size, 17.0);
        assert_eq!((p.theme.as_str(), p.accent.as_str()), ("system", "yellow"));
        let p: Prefs = serde_json::from_str(r#"{"theme":"dark","accent":"blue","noteSort":"created"}"#).unwrap();
        let p = p.normalized();
        assert_eq!((p.theme.as_str(), p.accent.as_str(), p.note_sort.as_str()), ("dark", "blue", "created"));
        let p: Prefs = serde_json::from_str(r#"{"theme":"sepia","accent":"rainbow"}"#).unwrap();
        let p = p.normalized();
        assert_eq!((p.theme.as_str(), p.accent.as_str()), ("system", "yellow"));
    }
}

/// 모양 설정을 앱 전체 macOS appearance로 적용한다 (FR-45).
/// 웹 화면의 prefers-color-scheme, 사이드바 반투명 효과, 네이티브 메뉴가 함께 바뀐다.
pub fn apply_theme(app: &AppHandle, prefs: &Prefs) {
    let theme = match prefs.theme.as_str() {
        "light" => Some(tauri::Theme::Light),
        "dark" => Some(tauri::Theme::Dark),
        _ => None,
    };
    app.set_theme(theme);
}
