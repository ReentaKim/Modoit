//! 저장 폴더(볼트) 안의 파일·폴더 입출력.
//! 프런트엔드는 볼트 기준 상대 경로("업무/회의/주간 회의.md")만 다루고,
//! 여기서 볼트 밖으로 벗어나는 경로를 모두 막는다.
//! 제목 추출과 파일 이름 규칙은 이 파일에만 있다(계약서 5장, BUG-17/18).

use crate::layout::{self, Layout};
use serde::Serialize;
use serde_yaml_ng::{Mapping, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const DEFAULT_FOLDER: &str = "메모";
pub const ATTACHMENTS_DIR: &str = "attachments";
pub const UNTITLED: &str = "새 메모";
pub const NOT_UTF8: &str = "NOT_UTF8";
const NAME_MAX_CHARS: usize = 60;
pub const ATTACHMENT_MAX_BYTES: usize = 20 * 1024 * 1024;
pub const ATTACHMENT_EXTS: [&str; 8] = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"];
/// 감시기가 무시하는 임시 파일 꼬리표
pub const TMP_SUFFIX: &str = ".modoit-tmp";
const STICKY_COLORS: [&str; 5] = ["yellow", "pink", "blue", "green", "purple"];
const STICKY_DEFAULT_SIZE: f64 = 280.0; // TS DEFAULT_STICKY와 같게 (BUG-37)

// ───────────────────────── 자료형 (계약서 1장) ─────────────────────────

#[derive(Debug, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StickyMeta {
    pub color: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub w: f64,
    pub h: f64,
    pub on_top: bool,
    pub open: bool,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct NoteMeta {
    pub path: String,
    pub folder: String,
    pub title: String,
    pub preview: String,
    pub modified: u64,
    /// 파일 생성 시각(ms). 알 수 없으면 modified (FR-47)
    pub created: u64,
    pub pinned: bool,
    pub sticky: Option<StickyMeta>,
    pub readable: bool,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct FolderNode {
    pub path: String,
    pub name: String,
    pub modified: u64,
    pub children: Vec<FolderNode>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tree {
    pub folders: Vec<FolderNode>,
    pub notes: Vec<NoteMeta>,
    pub layout: Layout,
}

// ───────────────────────── 경로 ─────────────────────────

/// 상대 경로를 검증해 볼트 안의 절대 경로로 바꾼다.
pub fn resolve(vault: &Path, rel: &str) -> Result<PathBuf, String> {
    let rel_path = Path::new(rel);
    if rel.is_empty() || rel_path.is_absolute() {
        return Err(format!("잘못된 경로: {rel}"));
    }
    for c in rel_path.components() {
        match c {
            Component::Normal(_) => {}
            _ => return Err(format!("허용되지 않는 경로: {rel}")),
        }
    }
    let full = vault.join(rel_path);
    // 심볼릭 링크로 밖을 가리키는 경우도 차단
    let base = fs::canonicalize(vault).map_err(|e| e.to_string())?;
    let mut probe = full.clone();
    while !probe.exists() {
        match probe.parent() {
            Some(p) => probe = p.to_path_buf(),
            None => break,
        }
    }
    let real = fs::canonicalize(&probe).map_err(|e| e.to_string())?;
    if !real.starts_with(&base) {
        return Err(format!("저장 폴더 밖의 경로: {rel}"));
    }
    Ok(full)
}

/// 폴더 경로("" = 저장 폴더 자체)를 검증한다. 있는 폴더여야 한다.
pub fn resolve_dir(vault: &Path, rel: &str) -> Result<PathBuf, String> {
    let dir = if rel.is_empty() {
        vault.to_path_buf()
    } else {
        resolve(vault, rel.trim_end_matches('/'))?
    };
    if !dir.is_dir() {
        return Err(format!("폴더를 찾을 수 없습니다: {rel}"));
    }
    Ok(dir)
}

pub fn to_rel(vault: &Path, p: &Path) -> String {
    p.strip_prefix(vault)
        .unwrap_or(p)
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

/// "a/b/c.md" → "a/b", "c.md" → ""
pub fn parent_rel(rel: &str) -> &str {
    rel.rfind('/').map(|i| &rel[..i]).unwrap_or("")
}

fn is_md(p: &Path) -> bool {
    p.extension().is_some_and(|e| e.eq_ignore_ascii_case("md"))
}

fn is_attachments_name(name: &str) -> bool {
    name.eq_ignore_ascii_case(ATTACHMENTS_DIR)
}

/// 두 경로가 같은 파일인가(대소문자·유니코드 정규화만 다른 이름 포함)
fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

fn random_u64() -> u64 {
    use std::hash::{BuildHasher, Hasher};
    // RandomState는 실행마다 임의 키를 쓰므로 가벼운 난수원으로 충분하다
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    );
    h.finish()
}

// ───────────────────────── 쓰기 도구 ─────────────────────────

/// 임시 파일에 쓴 뒤 rename — 쓰는 도중 앱이 죽어도 원본이 깨지지 않는다.
pub fn atomic_write(path: &Path, content: &str) -> Result<(), String> {
    atomic_write_bytes(path, content.as_bytes())
}

pub fn atomic_write_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("상위 폴더 없음")?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let name = path.file_name().ok_or("파일 이름 없음")?.to_string_lossy();
    // 여러 창이 같은 파일을 동시에 써도 임시 파일이 섞이지 않게 이름에 임의값을 붙인다
    let tmp = dir.join(format!(".{name}.{:08x}{TMP_SUFFIX}", random_u64() as u32));
    // 임시 파일로 바꿔 끼우면 새 파일이 되므로 원래 생성 시각을 옮겨 준다 (FR-47)
    let created = fs::metadata(path).and_then(|m| m.created()).ok();
    let result = (|| {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        if let Some(t) = created {
            set_created(&f, t);
        }
        f.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result.map_err(|e| e.to_string())
}

/// from을 to로 옮긴다. to가 from과 같은 파일(대소문자나 정규화만 다른 이름)이면
/// 임시 이름을 거쳐 바꾼다(BUG-14). 다른 파일이 이미 있으면 오류.
fn rename_entry(from: &Path, to: &Path) -> Result<(), String> {
    if from == to {
        return Ok(());
    }
    if same_file(from, to) {
        let tmp = from.with_file_name(format!(".modoit-rename-{:016x}{TMP_SUFFIX}", random_u64()));
        fs::rename(from, &tmp).map_err(|e| e.to_string())?;
        if let Err(e) = fs::rename(&tmp, to) {
            let _ = fs::rename(&tmp, from);
            return Err(e.to_string());
        }
        return Ok(());
    }
    if to.exists() {
        return Err(format!("이미 같은 이름이 있습니다: {}", to.display()));
    }
    fs::rename(from, to).map_err(|e| e.to_string())
}

/// dir 안에서 겹치지 않는 "<base>.<ext>", "<base> 2.<ext>" … 경로.
/// own과 같은 파일이면 비어 있는 것으로 본다(자기 자신의 이름 바꾸기).
fn unique_file(dir: &Path, base: &str, ext: &str, own: Option<&Path>) -> PathBuf {
    let mut n = 1;
    loop {
        let name = match n {
            1 => format!("{base}.{ext}"),
            _ => format!("{base} {n}.{ext}"),
        };
        let candidate = dir.join(name);
        if !candidate.exists() || own.is_some_and(|o| same_file(o, &candidate)) {
            return candidate;
        }
        n += 1;
    }
}

/// 폴더용 unique. 저장 폴더 바로 아래에서는 `attachments`를 예약 이름으로 본다.
fn unique_dir(dir: &Path, base: &str, own: Option<&Path>, top_level: bool) -> PathBuf {
    let mut n = 1;
    loop {
        let name = match n {
            1 => base.to_string(),
            _ => format!("{base} {n}"),
        };
        let candidate = dir.join(&name);
        let reserved = top_level && is_attachments_name(&name);
        if !reserved && (!candidate.exists() || own.is_some_and(|o| same_file(o, &candidate))) {
            return candidate;
        }
        n += 1;
    }
}

/// 휴지통으로 보낸다. 기본값(Finder 방식)은 "Finder 제어 허용" 권한 창을 띄우므로 NSFileManager를 쓴다.
pub fn trash_path(p: &Path) -> Result<(), String> {
    use trash::macos::{DeleteMethod, TrashContextExtMacos};
    let mut ctx = trash::TrashContext::default();
    ctx.set_delete_method(DeleteMethod::NsFileManager);
    ctx.delete(p).map_err(|e| e.to_string())
}

// ───────────────────────── frontmatter ─────────────────────────

fn strip_bom(s: &str) -> &str {
    s.strip_prefix('\u{feff}').unwrap_or(s)
}

fn line_text(line: &str) -> &str {
    line.trim_end_matches(['\n', '\r'])
}

fn looks_like_yaml_key(line: &str) -> bool {
    let t = line.trim();
    match t.find(':') {
        Some(i) if i > 0 => t[..i]
            .chars()
            .all(|c| c.is_alphanumeric() || c == '_' || c == '-' || c == ' '),
        _ => false,
    }
}

/// 맨 앞 BOM과 frontmatter를 떼어 (YAML 매핑, 본문)을 돌려준다.
/// `---`로 시작해도 안쪽이 YAML 매핑이 아니면 구분선으로 보고 frontmatter로 치지 않는다(BUG-18).
/// YAML 파싱에 실패해도 `키:` 꼴이면 frontmatter로 보되 매핑은 None이다.
pub fn split_frontmatter(content: &str) -> (Option<Mapping>, &str) {
    let s = strip_bom(content);
    let mut lines = s.split_inclusive('\n');
    let Some(first) = lines.next() else {
        return (None, s);
    };
    if line_text(first).trim_end() != "---" {
        return (None, s);
    }
    let yaml_start = first.len();
    let mut pos = yaml_start;
    for line in lines {
        let t = line_text(line).trim_end();
        if t == "---" || t == "..." {
            let yaml = &s[yaml_start..pos];
            let body = &s[pos + line.len()..];
            return match serde_yaml_ng::from_str::<Value>(yaml) {
                Ok(Value::Mapping(m)) => (Some(m), body),
                Ok(Value::Null) => (Some(Mapping::new()), body),
                Ok(_) => (None, s),
                Err(_) => {
                    let first_key = yaml.lines().find(|l| !l.trim().is_empty());
                    if first_key.is_some_and(looks_like_yaml_key) {
                        (None, body)
                    } else {
                        (None, s)
                    }
                }
            };
        }
        pos += line.len();
    }
    (None, s)
}

fn parse_sticky(v: &Value) -> Option<StickyMeta> {
    let m = v.as_mapping()?;
    let get = |k: &str| m.get(Value::String(k.to_string()));
    let num = |k: &str| get(k).and_then(Value::as_f64);
    let flag = |k: &str| get(k).and_then(Value::as_bool).unwrap_or(false);
    let color = get("color")
        .and_then(Value::as_str)
        .filter(|c| STICKY_COLORS.contains(c))
        .unwrap_or("yellow")
        .to_string();
    Some(StickyMeta {
        color,
        x: num("x"),
        y: num("y"),
        w: num("w").filter(|w| *w > 0.0).unwrap_or(STICKY_DEFAULT_SIZE),
        h: num("h").filter(|h| *h > 0.0).unwrap_or(STICKY_DEFAULT_SIZE),
        on_top: flag("onTop"),
        open: flag("open"),
    })
}

/// frontmatter의 pinned와 sticky. v0.1 형식(최상위 color: 등)은 sticky가 없으므로 None.
fn note_flags(fm: Option<&Mapping>) -> (bool, Option<StickyMeta>) {
    let Some(m) = fm else {
        return (false, None);
    };
    let pinned = m
        .get(Value::String("pinned".into()))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let sticky = m.get(Value::String("sticky".into())).and_then(parse_sticky);
    (pinned, sticky)
}

// ───────────────────────── 제목 추출 (계약서 5장) ─────────────────────────

fn is_thematic_break(t: &str) -> bool {
    let compact: String = t.chars().filter(|c| !c.is_whitespace()).collect();
    compact.len() >= 3
        && ['-', '*', '_']
            .iter()
            .any(|m| compact.chars().all(|c| c == *m))
}

fn is_fence(t: &str) -> bool {
    t.starts_with("```") || t.starts_with("~~~")
}

/// `[` 위치에서 시작하는 `[글](주소)`를 읽는다. (글, 끝 다음 위치)
fn parse_inline_link(chars: &[char], open: usize) -> Option<(String, usize)> {
    let mut depth = 0;
    let mut i = open;
    let close = loop {
        match chars.get(i)? {
            '\\' => i += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    break i;
                }
            }
            _ => {}
        }
        i += 1;
    };
    if chars.get(close + 1) != Some(&'(') {
        return None;
    }
    let mut depth = 0;
    let mut j = close + 2;
    loop {
        match chars.get(j)? {
            '\\' => j += 1,
            '(' => depth += 1,
            ')' if depth == 0 => break,
            ')' => depth -= 1,
            _ => {}
        }
        j += 1;
    }
    Some((chars[open + 1..close].iter().collect(), j + 1))
}

fn is_word(c: Option<&char>) -> bool {
    c.is_some_and(|c| c.is_alphanumeric())
}

/// 인라인 강조 기호를 떼고 링크는 글만, 이미지는 지운다. 역슬래시 이스케이프는 글자로 둔다.
fn strip_inline(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '\\' if chars.get(i + 1).is_some_and(|n| n.is_ascii_punctuation()) => {
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            '!' if chars.get(i + 1) == Some(&'[') => {
                if let Some((_, end)) = parse_inline_link(&chars, i + 1) {
                    i = end;
                    continue;
                }
                out.push(c);
            }
            '[' => {
                if let Some((text, end)) = parse_inline_link(&chars, i) {
                    out.push_str(&strip_inline(&text));
                    i = end;
                    continue;
                }
                out.push(c);
            }
            '*' | '`' => {}
            '~' if chars.get(i + 1) == Some(&'~') => i += 1,
            // snake_case처럼 단어 안의 밑줄은 남긴다
            '_' if is_word(i.checked_sub(1).and_then(|p| chars.get(p))) && is_word(chars.get(i + 1)) => {
                out.push(c)
            }
            '_' => {}
            _ => out.push(c),
        }
        i += 1;
    }
    out
}

fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        // 엔티티는 짧으므로 앞 12글자 안에서만 ';'를 찾는다
        let semi = rest.char_indices().take(12).find(|(_, c)| *c == ';').map(|(i, _)| i);
        let decoded = semi.and_then(|semi| {
            let name = &rest[1..semi];
            let ch = match name {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => {
                    let code = if let Some(hex) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                        u32::from_str_radix(hex, 16).ok()
                    } else if let Some(dec) = name.strip_prefix('#') {
                        dec.parse::<u32>().ok()
                    } else {
                        None
                    };
                    code.and_then(char::from_u32)
                }
            };
            ch.map(|c| (c, semi + 1))
        });
        match decoded {
            Some((c, len)) => {
                out.push(c);
                rest = &rest[len..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// 줄 앞의 목록·체크박스·제목·인용 기호를 뗀다(여러 겹도).
fn strip_block_prefix(mut s: &str) -> &str {
    loop {
        let before = s;
        s = s.trim_start();
        if let Some(r) = s.strip_prefix('>') {
            s = r;
        } else if s.starts_with('#') {
            let hashes = s.chars().take_while(|c| *c == '#').count();
            let r = &s[hashes..];
            if hashes <= 6 && (r.is_empty() || r.starts_with(char::is_whitespace)) {
                s = r;
            }
        } else if let Some(r) = ["- ", "* ", "+ "].iter().find_map(|p| s.strip_prefix(p)) {
            s = r;
        } else if let Some(r) = ["[ ]", "[x]", "[X]"].iter().find_map(|p| s.strip_prefix(p)) {
            if r.is_empty() || r.starts_with(char::is_whitespace) {
                s = r;
            }
        } else {
            let digits = s.chars().take_while(|c| c.is_ascii_digit()).count();
            if (1..=9).contains(&digits) {
                let r = &s[digits..];
                if let Some(r) = r.strip_prefix(". ").or_else(|| r.strip_prefix(") ")) {
                    s = r;
                }
            }
        }
        if s == before {
            return s;
        }
    }
}

/// 한 줄을 표시용 글로 바꾼다. 의미 없는 줄이면 None.
fn clean_line(line: &str) -> Option<String> {
    let t = line.trim();
    if t.is_empty() || is_thematic_break(t) || is_fence(t) {
        return None;
    }
    let text = strip_inline(strip_block_prefix(t));
    let text: String = decode_entities(&text)
        .chars()
        .map(|c| if c == '\u{a0}' || c == '\u{3000}' { ' ' } else { c })
        .collect();
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// (제목, 미리보기) — 의미 있는 첫째·둘째 줄
pub fn title_and_preview(content: &str) -> (String, String) {
    let (_, body) = split_frontmatter(content);
    let mut lines = body.lines().filter_map(clean_line);
    let title = lines.next().unwrap_or_default();
    let preview = lines.next().unwrap_or_default();
    (title, preview)
}

pub fn extract_title(content: &str) -> String {
    title_and_preview(content).0
}

// ───────────────────────── 파일 이름 규칙 (계약서 5장) ─────────────────────────

/// 파일·폴더 이름에 쓸 수 없는 문자를 걸러 내고 60자로 자른다. 비면 빈 문자열.
pub fn sanitize_component(s: &str) -> String {
    let replaced: String = s
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => ' ',
            '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{feff}' => ' ',
            c => c,
        })
        .collect();
    let collapsed = replaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let trim = |s: &str| s.trim_matches(|c: char| c == '.' || c == ' ').to_string();
    let short: String = trim(&collapsed).chars().take(NAME_MAX_CHARS).collect();
    trim(&short)
}

/// 제목 → 파일 이름(확장자 제외). 비면 "새 메모".
pub fn file_base(title: &str) -> String {
    let s = sanitize_component(title);
    if s.is_empty() { UNTITLED.to_string() } else { s }
}

/// 폴더 이름 검증. 빈 이름과 점으로만 된 이름은 거부한다(BUG-16).
pub fn folder_name(name: &str) -> Result<String, String> {
    let t = name.trim();
    if t.is_empty() || t.chars().all(|c| c == '.') {
        return Err(format!("사용할 수 없는 폴더 이름입니다: \"{name}\""));
    }
    let s = sanitize_component(t);
    if s.is_empty() {
        return Err(format!("사용할 수 없는 폴더 이름입니다: \"{name}\""));
    }
    Ok(s)
}

#[cfg(target_os = "macos")]
fn set_created(f: &fs::File, t: std::time::SystemTime) {
    use std::os::macos::fs::FileTimesExt;
    let _ = f.set_times(fs::FileTimes::new().set_created(t));
}

#[cfg(not(target_os = "macos"))]
fn set_created(_f: &fs::File, _t: std::time::SystemTime) {}

// ───────────────────────── 목록 ─────────────────────────

fn created_ms(p: &Path) -> Option<u64> {
    fs::metadata(p)
        .and_then(|m| m.created())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
}

fn modified_ms(p: &Path) -> u64 {
    fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn note_meta(vault: &Path, p: &Path) -> NoteMeta {
    let path = to_rel(vault, p);
    let folder = parent_rel(&path).to_string();
    let modified = modified_ms(p);
    let created = created_ms(p).unwrap_or(modified);
    let bytes = fs::read(p);
    let (title, preview, pinned, sticky, readable) = match bytes {
        Ok(b) => match String::from_utf8(b) {
            Ok(text) => {
                let (title, preview) = title_and_preview(&text);
                let (fm, _) = split_frontmatter(&text);
                let (pinned, sticky) = note_flags(fm.as_ref());
                (title, preview, pinned, sticky, true)
            }
            Err(e) => {
                // UTF-8이 아니면 목록에는 보이되 열 수 없다고 표시한다(BUG-19)
                let lossy = String::from_utf8_lossy(e.as_bytes()).into_owned();
                let (title, preview) = title_and_preview(&lossy);
                (title, preview, false, None, false)
            }
        },
        Err(_) => (String::new(), String::new(), false, None, false),
    };
    NoteMeta { path, folder, title, preview, modified, created, pinned, sticky, readable }
}

pub fn list_tree(vault: &Path) -> Result<Tree, String> {
    let entries = fs::read_dir(vault).map_err(|e| e.to_string())?;
    let mut notes = Vec::new();
    let folders = walk(vault, vault, entries, &mut notes);
    notes.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| a.path.cmp(&b.path)));
    Ok(Tree { folders, notes, layout: layout::load(vault) })
}

fn walk(vault: &Path, dir: &Path, entries: fs::ReadDir, notes: &mut Vec<NoteMeta>) -> Vec<FolderNode> {
    let mut folders = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let Ok(ft) = entry.file_type() else { continue };
        let p = entry.path();
        if ft.is_dir() {
            if dir == vault && is_attachments_name(&name) {
                continue;
            }
            // 읽을 수 없는 폴더는 그 폴더만 건너뛴다(BUG-07)
            let Ok(sub) = fs::read_dir(&p) else { continue };
            let first = notes.len();
            let children = walk(vault, &p, sub, notes);
            // notes[first..]는 이 폴더 하위 트리의 메모 전부다
            let modified = notes[first..]
                .iter()
                .map(|n| n.modified)
                .max()
                .unwrap_or_else(|| modified_ms(&p));
            folders.push(FolderNode { path: to_rel(vault, &p), name, modified, children });
        } else if ft.is_file() && is_md(&p) {
            notes.push(note_meta(vault, &p));
        }
    }
    folders.sort_by(|a, b| a.name.cmp(&b.name));
    folders
}

// ───────────────────────── 메모 ─────────────────────────

pub fn read_note(vault: &Path, rel: &str) -> Result<String, String> {
    let bytes = fs::read(resolve(vault, rel)?).map_err(|e| e.to_string())?;
    String::from_utf8(bytes).map_err(|_| NOT_UTF8.to_string())
}

/// folder가 ""이면 `메모/`에 만들고, 그 폴더가 없으면 만든다(BUG-08).
pub fn create_note(vault: &Path, folder: &str) -> Result<String, String> {
    let dir = if folder.is_empty() {
        let d = vault.join(DEFAULT_FOLDER);
        fs::create_dir_all(&d).map_err(|e| e.to_string())?;
        d
    } else {
        resolve_dir(vault, folder)?
    };
    let path = unique_file(&dir, UNTITLED, "md", None);
    atomic_write(&path, "")?;
    Ok(to_rel(vault, &path))
}

/// 디스크 내용의 제목으로 파일 이름을 맞춘다. 새 상대 경로를 돌려준다.
pub fn sync_note_name(vault: &Path, rel: &str) -> Result<String, String> {
    let from = resolve(vault, rel)?;
    let rel = to_rel(vault, &from);
    let content = read_note(vault, &rel)?;
    let base = file_base(&extract_title(&content));
    if from.file_stem().is_some_and(|s| s.to_string_lossy() == base) {
        return Ok(rel);
    }
    let dir = from.parent().ok_or("상위 폴더 없음")?;
    let ext = from.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_else(|| "md".into());
    let to = unique_file(dir, &base, &ext, Some(&from));
    if to == from {
        return Ok(rel);
    }
    rename_entry(&from, &to)?;
    Ok(to_rel(vault, &to))
}

// ───────────────────────── 폴더 ─────────────────────────

pub fn create_folder(vault: &Path, parent: &str, name: &str) -> Result<String, String> {
    let name = folder_name(name)?;
    let pdir = resolve_dir(vault, parent)?;
    let path = unique_dir(&pdir, &name, None, pdir == vault);
    fs::create_dir(&path).map_err(|e| e.to_string())?;
    Ok(to_rel(vault, &path))
}

pub fn rename_folder(vault: &Path, rel: &str, name: &str) -> Result<String, String> {
    let from = resolve_dir(vault, rel)?;
    if from == vault {
        return Err("저장 폴더 자체는 이름을 바꿀 수 없습니다".into());
    }
    let rel = to_rel(vault, &from);
    let name = folder_name(name)?;
    if from.file_name().is_some_and(|n| n.to_string_lossy() == name) {
        return Ok(rel);
    }
    let pdir = from.parent().ok_or("상위 폴더 없음")?;
    let to = unique_dir(pdir, &name, Some(&from), pdir == vault);
    if to == from {
        return Ok(rel);
    }
    rename_entry(&from, &to)?;
    let new_rel = to_rel(vault, &to);
    layout::update(vault, |l| l.move_dir(&rel, &new_rel))?;
    Ok(new_rel)
}

pub fn trash_folder(vault: &Path, rel: &str) -> Result<(), String> {
    let dir = resolve_dir(vault, rel)?;
    if dir == vault {
        return Err("저장 폴더 자체는 지울 수 없습니다".into());
    }
    let rel = to_rel(vault, &dir);
    trash_path(&dir)?;
    layout::update(vault, |l| l.remove_dir(&rel))
}

/// 옮긴 결과
#[derive(Debug, Clone, PartialEq)]
pub struct Moved {
    pub from: String,
    pub to: String,
    pub is_dir: bool,
}

/// 파일이나 폴더를 다른 폴더로 옮긴다. 옮겨진 .md의 상대 링크를 다시 계산한다(계약서 6장).
pub fn move_entry(vault: &Path, from: &str, to_folder: &str) -> Result<Moved, String> {
    let src = resolve(vault, from)?;
    let meta = fs::symlink_metadata(&src).map_err(|_| format!("찾을 수 없습니다: {from}"))?;
    let from_rel = to_rel(vault, &src);
    let dest_dir = resolve_dir(vault, to_folder)?;
    let dest_rel = to_rel(vault, &dest_dir);
    let is_dir = meta.is_dir();
    if is_dir && (dest_rel == from_rel || dest_rel.starts_with(&format!("{from_rel}/"))) {
        return Err("폴더를 자기 자신이나 하위 폴더로 옮길 수 없습니다".into());
    }
    if parent_rel(&from_rel) == dest_rel {
        return Ok(Moved { from: from_rel.clone(), to: from_rel, is_dir });
    }

    let dst = if is_dir {
        let name = src.file_name().ok_or("이름 없음")?.to_string_lossy().into_owned();
        unique_dir(&dest_dir, &name, None, dest_dir == vault)
    } else {
        let stem = src.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        match src.extension() {
            Some(ext) => unique_file(&dest_dir, &stem, &ext.to_string_lossy(), None),
            None => unique_dir(&dest_dir, &stem, None, false),
        }
    };
    let to_rel_path = to_rel(vault, &dst);

    // 옮기기 전에 새 내용을 계산해 둔다(옮긴 뒤 새 위치에 쓴다)
    let mut rewrites: Vec<(String, String)> = Vec::new();
    let moved = Some((from_rel.as_str(), to_rel_path.as_str()));
    let mut plan = |old_file: &str| {
        let new_file = format!("{to_rel_path}{}", &old_file[from_rel.len()..]);
        if let Ok(content) = read_note(vault, old_file) {
            let next = rewrite_links(&content, parent_rel(old_file), parent_rel(&new_file), moved);
            if next != content {
                rewrites.push((new_file, next));
            }
        }
    };
    if is_dir {
        for f in md_files_under(&src) {
            plan(&to_rel(vault, &f));
        }
    } else if is_md(&src) {
        plan(&from_rel);
    }

    rename_entry(&src, &dst)?;
    for (rel, content) in rewrites {
        if let Err(e) = atomic_write(&vault.join(&rel), &content) {
            eprintln!("링크 고치기 실패 {rel}: {e}");
        }
    }
    if is_dir {
        layout::update(vault, |l| l.move_dir(&from_rel, &to_rel_path))?;
    }
    Ok(Moved { from: from_rel, to: to_rel_path, is_dir })
}

fn md_files_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(dir) else { return out };
    for e in entries.flatten() {
        let p = e.path();
        match e.file_type() {
            Ok(ft) if ft.is_dir() => out.extend(md_files_under(&p)),
            Ok(ft) if ft.is_file() && is_md(&p) => out.push(p),
            _ => {}
        }
    }
    out
}

// ───────────────────────── 상대 링크 재작성 (계약서 6장) ─────────────────────────

fn has_scheme(s: &str) -> bool {
    let mut chars = s.char_indices();
    if !chars.next().is_some_and(|(_, c)| c.is_ascii_alphabetic()) {
        return false;
    }
    for (_, c) in chars {
        if c == ':' {
            return true;
        }
        if !(c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.') {
            return false;
        }
    }
    false
}

fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit() {
            let hex = |c: u8| (c as char).to_digit(16).unwrap_or(0) as u8;
            out.push(hex(b[i + 1]) * 16 + hex(b[i + 2]));
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8(out).ok()
}

fn percent_encode_path(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            ' ' => out.push_str("%20"),
            '%' => out.push_str("%25"),
            '(' => out.push_str("%28"),
            ')' => out.push_str("%29"),
            '<' => out.push_str("%3C"),
            '>' => out.push_str("%3E"),
            '#' => out.push_str("%23"),
            '?' => out.push_str("%3F"),
            c => out.push(c),
        }
    }
    out
}

/// base 폴더 기준 상대 경로를 풀어 저장 폴더 기준 경로로. 밖으로 벗어나면 None.
fn join_normalize(base_dir: &str, rel: &str) -> Option<String> {
    let mut parts: Vec<&str> = base_dir.split('/').filter(|s| !s.is_empty()).collect();
    for seg in rel.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            s => parts.push(s),
        }
    }
    Some(parts.join("/"))
}

/// from_dir에서 target(둘 다 저장 폴더 기준)으로 가는 상대 경로
pub fn relative_path(from_dir: &str, target: &str) -> String {
    let from: Vec<&str> = from_dir.split('/').filter(|s| !s.is_empty()).collect();
    let to: Vec<&str> = target.split('/').filter(|s| !s.is_empty()).collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts: Vec<&str> = vec![".."; from.len() - common];
    parts.extend(&to[common..]);
    parts.join("/")
}

/// 링크 대상 하나를 고친다. 고칠 필요가 없으면 None.
fn rewrite_target(raw: &str, old_dir: &str, new_dir: &str, moved: Option<(&str, &str)>) -> Option<String> {
    if raw.is_empty() || raw.starts_with('#') || raw.starts_with('/') || raw.starts_with('~') || has_scheme(raw) {
        return None;
    }
    let cut = raw.find(['#', '?']).unwrap_or(raw.len());
    let (path_part, suffix) = raw.split_at(cut);
    if path_part.is_empty() {
        return None;
    }
    let decoded = percent_decode(path_part)?;
    let mut abs = join_normalize(old_dir, &decoded)?;
    if let Some((from, to)) = moved {
        if abs == from {
            abs = to.to_string();
        } else if let Some(rest) = abs.strip_prefix(from).filter(|r| r.starts_with('/')) {
            abs = format!("{to}{rest}");
        }
    }
    let rel = relative_path(new_dir, &abs);
    if rel.is_empty() || rel == decoded {
        return None;
    }
    Some(format!("{}{suffix}", percent_encode_path(&rel)))
}

/// `](` 바로 뒤의 링크 대상을 읽는다. (앞 공백 길이, 대상 글, 대상이 차지한 길이)
fn parse_destination(s: &str) -> Option<(usize, &str, usize)> {
    let lead = s.len() - s.trim_start_matches([' ', '\t']).len();
    let rest = &s[lead..];
    if let Some(inner) = rest.strip_prefix('<') {
        let end = inner.find(['>', '\n'])?;
        if !inner[end..].starts_with('>') {
            return None;
        }
        return Some((lead, &inner[..end], end + 2));
    }
    let mut depth = 0i32;
    let mut end = rest.len();
    let mut escaped = false;
    for (i, c) in rest.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            '\\' => escaped = true,
            '(' => depth += 1,
            ')' if depth == 0 => {
                end = i;
                break;
            }
            ')' => depth -= 1,
            c if c.is_whitespace() => {
                end = i;
                break;
            }
            _ => {}
        }
    }
    (end > 0).then(|| (lead, &rest[..end], end))
}

/// 메모 내용의 Markdown 링크·이미지 대상을 옛 위치(old_dir) 기준에서 새 위치(new_dir) 기준으로 다시 쓴다.
/// moved = (옛 경로, 새 경로): 함께 옮겨진 파일·폴더를 가리키는 링크는 새 자리로 맞춘다.
pub fn rewrite_links(content: &str, old_dir: &str, new_dir: &str, moved: Option<(&str, &str)>) -> String {
    let mut out = String::with_capacity(content.len());
    let mut in_fence = false;
    for line in content.split_inclusive('\n') {
        if is_fence(line.trim_start()) {
            in_fence = !in_fence;
            out.push_str(line);
            continue;
        }
        if in_fence {
            out.push_str(line);
            continue;
        }
        let mut rest = line;
        while let Some(idx) = rest.find("](") {
            out.push_str(&rest[..idx + 2]);
            rest = &rest[idx + 2..];
            let Some((lead, target, len)) = parse_destination(rest) else { continue };
            out.push_str(&rest[..lead]);
            match rewrite_target(target, old_dir, new_dir, moved) {
                Some(new_target) => out.push_str(&new_target),
                None => out.push_str(&rest[lead..lead + len]),
            }
            rest = &rest[lead + len..];
        }
        out.push_str(rest);
    }
    out
}

// ───────────────────────── 첨부 이미지 ─────────────────────────

fn local_timestamp() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let t = secs as libc::time_t;
    // SAFETY: localtime_r는 넘겨준 tm 구조체에만 쓴다
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

/// 이미지를 `attachments/`에 저장하고 메모 기준 상대 링크를 돌려준다.
pub fn save_attachment(vault: &Path, note_path: &str, file_name: &str, data_base64: &str) -> Result<String, String> {
    use base64::Engine;
    let note = resolve(vault, note_path)?;
    let note_rel = to_rel(vault, &note);
    let ext = Path::new(file_name)
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    if !ATTACHMENT_EXTS.contains(&ext.as_str()) {
        return Err(format!("지원하지 않는 이미지 형식입니다: {file_name}"));
    }
    // "data:image/png;base64,..." 형태도 받는다
    let b64 = match data_base64.strip_prefix("data:") {
        Some(r) => r.split_once(',').map(|(_, d)| d).unwrap_or(r),
        None => data_base64,
    };
    let too_big = || "이미지가 20MB를 넘습니다".to_string();
    // 디코드 전에 터무니없이 큰 입력을 거른다(줄바꿈 등 5% 여유)
    if b64.len() > ATTACHMENT_MAX_BYTES / 3 * 4 * 21 / 20 + 64 {
        return Err(too_big());
    }
    let compact: String = b64.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(compact)
        .map_err(|e| format!("이미지 데이터를 읽을 수 없습니다: {e}"))?;
    if bytes.len() > ATTACHMENT_MAX_BYTES {
        return Err(too_big());
    }
    if bytes.is_empty() {
        return Err("빈 이미지입니다".into());
    }
    let dir = vault.join(ATTACHMENTS_DIR);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let stamp = local_timestamp();
    let path = (0..64)
        .map(|_| dir.join(format!("{stamp}-{:04x}.{ext}", random_u64() & 0xffff)))
        .find(|p| !p.exists())
        .ok_or("이미지 이름을 만들 수 없습니다")?;
    atomic_write_bytes(&path, &bytes)?;
    Ok(relative_path(parent_rel(&note_rel), &to_rel(vault, &path)))
}

// ───────────────────────── 테스트 ─────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn vault() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    fn write(v: &Path, rel: &str, content: &str) {
        atomic_write(&v.join(rel), content).unwrap();
    }

    fn names_in(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !n.starts_with('.'))
            .collect();
        v.sort();
        v
    }

    // ── 경로 ──

    #[test]
    fn rejects_escaping_paths() {
        let v = vault();
        assert!(resolve(v.path(), "../x.md").is_err());
        assert!(resolve(v.path(), "a/../../x.md").is_err());
        assert!(resolve(v.path(), "/etc/passwd").is_err());
        assert!(resolve(v.path(), "").is_err());
        assert!(resolve(v.path(), "메모/새 메모.md").is_ok());
    }

    #[test]
    fn rejects_symlink_escape() {
        let v = vault();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), v.path().join("link")).unwrap();
        assert!(resolve(v.path(), "link/x.md").is_err());
    }

    #[test]
    fn atomic_write_replaces_and_leaves_no_tmp() {
        let v = vault();
        let p = v.path().join("a/b.md");
        atomic_write(&p, "one").unwrap();
        atomic_write(&p, "two").unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "two");
        assert_eq!(fs::read_dir(v.path().join("a")).unwrap().count(), 1);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn atomic_write_keeps_creation_time() {
        let v = vault();
        let p = v.path().join("c.md");
        atomic_write(&p, "one").unwrap();
        let born = fs::metadata(&p).unwrap().created().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        atomic_write(&p, "two").unwrap();
        let m = fs::metadata(&p).unwrap();
        assert_eq!(m.created().unwrap(), born);
        assert!(m.modified().unwrap() > born);
    }

    // ── 제목 추출 ──

    #[test]
    fn title_basic_markdown() {
        let (t, p) = title_and_preview("# 장보기\n\n- [ ] 우유\n- 빵");
        assert_eq!(t, "장보기");
        assert_eq!(p, "우유");
        assert_eq!(extract_title("> 인용 *기울임* 제목"), "인용 기울임 제목");
        assert_eq!(extract_title("1. 첫째"), "첫째");
        assert_eq!(extract_title("+ 더하기"), "더하기");
        assert_eq!(extract_title("#해시태그"), "#해시태그");
    }

    #[test]
    fn title_entities() {
        assert_eq!(extract_title("R&amp;D 회의"), "R&D 회의");
        assert_eq!(extract_title("a &lt; b &gt; c &quot;x&quot; &#39;y&#39;"), "a < b > c \"x\" 'y'");
        assert_eq!(extract_title("&#44032;&#x B; &#xAC00;"), "가&#x B; 가");
        assert_eq!(extract_title("앞&nbsp;뒤\u{3000}끝&nbsp;"), "앞 뒤 끝");
        assert_eq!(extract_title("&nbsp;\n두 번째"), "두 번째");
        assert_eq!(extract_title("AT&T"), "AT&T");
    }

    #[test]
    fn title_emphasis_and_links() {
        assert_eq!(extract_title("**굵게** __밑줄__ ~~취소~~ `코드` 끝"), "굵게 밑줄 취소 코드 끝");
        assert_eq!(extract_title("*기울임* 제목"), "기울임 제목");
        assert_eq!(extract_title("_기울임_ snake_case"), "기울임 snake_case");
        assert_eq!(extract_title("[링크 글](https://a.com/x_(y)) 뒤"), "링크 글 뒤");
        assert_eq!(extract_title("앞 ![그림](a.png) 뒤"), "앞  뒤");
        assert_eq!(extract_title("\\*별\\* \\[ \\]"), "*별* [ ]");
        assert_eq!(extract_title("10~20"), "10~20");
    }

    #[test]
    fn title_checkboxes() {
        assert_eq!(extract_title("* [X] 완료"), "완료");
        assert_eq!(extract_title("- [x] 끝냄"), "끝냄");
        assert_eq!(extract_title("- [ ] 할 일"), "할 일");
        assert_eq!(extract_title("[X] 맨 체크"), "맨 체크");
        assert_eq!(extract_title("- [ ]\n둘째"), "둘째");
    }

    #[test]
    fn title_bom_and_frontmatter() {
        assert_eq!(extract_title("\u{feff}BOM 제목"), "BOM 제목");
        assert_eq!(extract_title("\u{feff}---\npinned: true\n---\n본문 제목"), "본문 제목");
        assert_eq!(extract_title("---\ncolor: yellow\n---\n오늘 할 일"), "오늘 할 일");
        assert_eq!(extract_title("---\r\ntags: [a, b]\r\n---\r\n# 윈도 줄바꿈\r\n"), "윈도 줄바꿈");
        // 깨진 YAML이어도 키 꼴이면 frontmatter
        assert_eq!(extract_title("---\ntags: [a, b\n---\n본문"), "본문");
        // 빈 frontmatter
        assert_eq!(extract_title("---\n---\n빈 머리"), "빈 머리");
    }

    #[test]
    fn title_starting_with_thematic_break() {
        // 구분선으로 시작하는 메모는 frontmatter가 아니다(BUG-18)
        assert_eq!(extract_title("---\n첫 글\n---\n둘째 글"), "첫 글");
        assert_eq!(extract_title("---\n\n본문"), "본문");
        assert_eq!(extract_title("***\n* * *\n별 구분선 뒤"), "별 구분선 뒤");
    }

    #[test]
    fn title_skips_fences_and_images() {
        assert_eq!(extract_title("```\n코드\n```\n뒤"), "코드");
        assert_eq!(extract_title("![](a.png)\n![x](b.png) ![y](c.png)\n사진 설명"), "사진 설명");
        assert_eq!(extract_title(""), "");
        assert_eq!(extract_title("   \n\n"), "");
    }

    // ── 파일 이름 규칙 ──

    #[test]
    fn file_name_rules() {
        assert_eq!(file_base("회의: 1/2분기"), "회의 1 2분기");
        assert_eq!(file_base("a\u{0}b\u{1f}c\u{7f}d\u{85}e\u{9f}f\u{feff}g"), "a b c d e f g");
        assert_eq!(file_base("탭\t과\n줄"), "탭 과 줄");
        assert_eq!(file_base("  ..숨김 이름..  "), "숨김 이름");
        assert_eq!(file_base("..."), UNTITLED);
        assert_eq!(file_base(""), UNTITLED);
        assert_eq!(file_base("R&D <회의> | \"끝\"?"), "R&D 회의 끝");
    }

    #[test]
    fn file_name_truncates_then_trims() {
        let long = format!("{}가 나", "가".repeat(58));
        // 60자에서 자르면 "가…가 "로 끝나므로 끝 공백을 지운다
        let b = file_base(&long);
        assert_eq!(b.chars().count(), 59);
        assert!(!b.ends_with(' '));
        let dots = format!("{}...끝", "a".repeat(58));
        let b = file_base(&dots);
        assert_eq!(b, "a".repeat(58));
        assert_eq!(file_base(&"한".repeat(80)).chars().count(), 60);
    }

    #[test]
    fn folder_name_rejects_dots_and_empty() {
        assert!(folder_name("").is_err());
        assert!(folder_name("   ").is_err());
        assert!(folder_name(".").is_err());
        assert!(folder_name("..").is_err());
        assert!(folder_name(" ... ").is_err());
        assert!(folder_name("///").is_err());
        assert_eq!(folder_name(".숨김").unwrap(), "숨김");
        assert_eq!(folder_name("Stickies").unwrap(), "Stickies");
    }

    // ── 목록 ──

    #[test]
    fn tree_nested_and_excludes_attachments_and_hidden() {
        let v = vault();
        write(v.path(), "업무/회의/주간.md", "# 주간 회의\n안건");
        write(v.path(), "업무/a.md", "가");
        write(v.path(), "업무-2024/b.md", "나");
        write(v.path(), "Stickies/s.md", "스티키");
        write(v.path(), "top.md", "최상위");
        write(v.path(), "attachments/x.md", "첨부 안 md");
        write(v.path(), ".modoit/layout.json", r#"{"sort":"name","order":{"":["업무"]}}"#);
        write(v.path(), ".hidden/x.md", "숨김");
        write(v.path(), "업무/attachments/ok.md", "하위의 attachments는 보통 폴더");
        let t = list_tree(v.path()).unwrap();
        let top: Vec<&str> = t.folders.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(top, vec!["Stickies", "업무", "업무-2024"]);
        let work = &t.folders[1];
        assert_eq!(work.path, "업무");
        let kids: Vec<&str> = work.children.iter().map(|f| f.path.as_str()).collect();
        assert_eq!(kids, vec!["업무/attachments", "업무/회의"]);
        let mut paths: Vec<&str> = t.notes.iter().map(|n| n.path.as_str()).collect();
        paths.sort();
        assert_eq!(
            paths,
            vec!["Stickies/s.md", "top.md", "업무-2024/b.md", "업무/a.md", "업무/attachments/ok.md", "업무/회의/주간.md"]
        );
        let n = t.notes.iter().find(|n| n.path == "업무/회의/주간.md").unwrap();
        assert_eq!(n.folder, "업무/회의");
        assert_eq!(n.title, "주간 회의");
        assert_eq!(n.preview, "안건");
        assert!(n.readable);
        assert_eq!(t.notes.iter().find(|n| n.path == "top.md").unwrap().folder, "");
        assert_eq!(t.layout.sort, layout::SortMode::Name);
        // 폴더 modified = 하위 메모의 최대 modified
        let max_note = t.notes.iter().filter(|n| n.path.starts_with("업무/")).map(|n| n.modified).max().unwrap();
        assert_eq!(work.modified, max_note);
        // 메모는 최신순
        assert!(t.notes.windows(2).all(|w| w[0].modified >= w[1].modified));
    }

    #[test]
    fn tree_skips_unreadable_folder() {
        use std::os::unix::fs::PermissionsExt;
        let v = vault();
        write(v.path(), "열림/a.md", "가");
        write(v.path(), "잠김/b.md", "나");
        let locked = v.path().join("잠김");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        let readable_anyway = fs::read_dir(&locked).is_ok(); // root로 돌리면 권한이 무시된다
        let t = list_tree(v.path());
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        let t = t.unwrap();
        assert!(t.notes.iter().any(|n| n.path == "열림/a.md"));
        if !readable_anyway {
            assert!(t.folders.iter().all(|f| f.name != "잠김"));
            assert_eq!(t.notes.len(), 1);
        }
    }

    #[test]
    fn tree_non_utf8_is_listed_unreadable() {
        let v = vault();
        // CP949 "가나" + 줄바꿈
        fs::create_dir(v.path().join("메모")).unwrap();
        fs::write(v.path().join("메모/옛메모.md"), [0xb0, 0xa1, 0xb3, 0xaa, b'\n', b'x']).unwrap();
        let t = list_tree(v.path()).unwrap();
        let n = &t.notes[0];
        assert!(!n.readable);
        assert!(n.title.contains('\u{fffd}'));
        assert_eq!(read_note(v.path(), "메모/옛메모.md").unwrap_err(), NOT_UTF8);
        assert_eq!(sync_note_name(v.path(), "메모/옛메모.md").unwrap_err(), NOT_UTF8);
    }

    #[test]
    fn tree_parses_pinned_and_sticky() {
        let v = vault();
        write(
            v.path(),
            "a.md",
            "---\npinned: true\nsticky: {color: pink, x: 1250, y: 140, w: 300, h: 200, onTop: true, open: true}\ntags: [x]\n---\n장보기",
        );
        write(v.path(), "b.md", "---\nsticky:\n  color: green\n  x: 10.5\n---\n블록 형식");
        write(v.path(), "old.md", "---\ncolor: yellow\nx: 1\ny: 2\n---\nv0.1 형식");
        write(v.path(), "bad.md", "---\nsticky: {color: [\n---\n깨진 yaml");
        write(v.path(), "weird.md", "---\npinned: 'yes'\nsticky: {color: orange, w: -1}\n---\n이상한 값");
        let t = list_tree(v.path()).unwrap();
        let get = |p: &str| t.notes.iter().find(|n| n.path == p).unwrap().clone();
        let a = get("a.md");
        assert!(a.pinned);
        assert_eq!(a.title, "장보기");
        assert_eq!(
            a.sticky,
            Some(StickyMeta { color: "pink".into(), x: Some(1250.0), y: Some(140.0), w: 300.0, h: 200.0, on_top: true, open: true })
        );
        let b = get("b.md");
        assert!(!b.pinned);
        let s = b.sticky.unwrap();
        assert_eq!((s.color.as_str(), s.x, s.y, s.w, s.on_top, s.open), ("green", Some(10.5), None, 280.0, false, false));
        let old = get("old.md");
        assert!(old.sticky.is_none());
        assert_eq!(old.title, "v0.1 형식");
        let bad = get("bad.md");
        assert!(!bad.pinned && bad.sticky.is_none());
        let weird = get("weird.md");
        assert!(!weird.pinned);
        assert_eq!(weird.sticky.unwrap().color, "yellow");
        // camelCase 직렬화
        let json = serde_json::to_value(&a).unwrap();
        assert_eq!(json["sticky"]["onTop"], true);
        assert_eq!(json["readable"], true);
    }

    // ── 메모 ──

    #[test]
    fn create_note_makes_default_folder() {
        let v = vault();
        let a = create_note(v.path(), "").unwrap();
        assert_eq!(a, "메모/새 메모.md");
        assert_eq!(create_note(v.path(), "").unwrap(), "메모/새 메모 2.md");
        fs::create_dir(v.path().join("업무")).unwrap();
        assert_eq!(create_note(v.path(), "업무").unwrap(), "업무/새 메모.md");
        assert!(create_note(v.path(), "없는폴더").is_err());
    }

    #[test]
    fn sync_note_name_follows_title() {
        let v = vault();
        let a = create_note(v.path(), "").unwrap();
        let b = create_note(v.path(), "").unwrap();
        write(v.path(), &a, "회의: 1/2분기\n본문");
        write(v.path(), &b, "# 회의: 1/2분기");
        let a2 = sync_note_name(v.path(), &a).unwrap();
        assert_eq!(a2, "메모/회의 1 2분기.md");
        let b2 = sync_note_name(v.path(), &b).unwrap();
        assert_eq!(b2, "메모/회의 1 2분기 2.md");
        // 같은 제목이면 그대로
        assert_eq!(sync_note_name(v.path(), &a2).unwrap(), a2);
        assert_eq!(sync_note_name(v.path(), &b2).unwrap(), b2);
        // 엔티티는 풀어서 쓴다(BUG-03)
        write(v.path(), &a2, "R&amp;D 회의");
        assert_eq!(sync_note_name(v.path(), &a2).unwrap(), "메모/R&D 회의.md");
    }

    #[test]
    fn sync_note_name_case_only_change() {
        let v = vault();
        write(v.path(), "메모/Abc.md", "abc");
        let to = sync_note_name(v.path(), "메모/Abc.md").unwrap();
        assert_eq!(to, "메모/abc.md");
        assert_eq!(names_in(&v.path().join("메모")), vec!["abc.md"]);
        assert_eq!(fs::read_to_string(v.path().join("메모/abc.md")).unwrap(), "abc");
        // 다시 대문자로
        write(v.path(), "메모/abc.md", "ABC");
        assert_eq!(sync_note_name(v.path(), "메모/abc.md").unwrap(), "메모/ABC.md");
        assert_eq!(names_in(&v.path().join("메모")), vec!["ABC.md"]);
    }

    #[test]
    fn sync_note_name_nfd_hangul() {
        // Finder가 만든 NFD 이름도 " 2"를 거치지 않는다
        let v = vault();
        let nfd = "\u{1112}\u{1161}\u{11AB}"; // "한" 자모 분해
        write(v.path(), &format!("{nfd}.md"), "한");
        let to = sync_note_name(v.path(), &format!("{nfd}.md")).unwrap();
        assert!(to == "한.md" || to == format!("{nfd}.md"), "{to}");
        assert_eq!(names_in(v.path()).len(), 1);
    }

    // ── 폴더 ──

    #[test]
    fn create_folder_rules() {
        let v = vault();
        assert_eq!(create_folder(v.path(), "", "업무").unwrap(), "업무");
        assert_eq!(create_folder(v.path(), "", "업무").unwrap(), "업무 2");
        assert_eq!(create_folder(v.path(), "업무", "회의").unwrap(), "업무/회의");
        assert_eq!(create_folder(v.path(), "", "Stickies").unwrap(), "Stickies");
        assert!(create_folder(v.path(), "", "..").is_err());
        assert!(create_folder(v.path(), "", ".").is_err());
        assert!(create_folder(v.path(), "", "").is_err());
        assert!(create_folder(v.path(), "../밖", "x").is_err());
        // 최상위 attachments는 예약 이름
        assert_eq!(create_folder(v.path(), "", "attachments").unwrap(), "attachments 2");
        assert_eq!(create_folder(v.path(), "업무", "attachments").unwrap(), "업무/attachments");
    }

    #[test]
    fn rename_folder_updates_layout_and_case() {
        let v = vault();
        create_folder(v.path(), "", "업무").unwrap();
        create_folder(v.path(), "업무", "회의").unwrap();
        create_folder(v.path(), "", "개인").unwrap();
        let mut l = Layout::default();
        l.order.insert("".into(), vec!["개인".into(), "sep:a".into(), "업무".into()]);
        l.order.insert("업무".into(), vec!["회의".into()]);
        layout::save(v.path(), &l).unwrap();

        assert_eq!(rename_folder(v.path(), "업무", "일").unwrap(), "일");
        assert!(v.path().join("일/회의").is_dir());
        let l = layout::load(v.path());
        assert_eq!(l.order[""], vec!["개인", "sep:a", "일"]);
        assert_eq!(l.order["일"], vec!["회의"]);
        // 이미 있는 이름이면 번호
        assert_eq!(rename_folder(v.path(), "개인", "일").unwrap(), "일 2");
        // 대소문자만 다른 이름
        create_folder(v.path(), "", "Work").unwrap();
        assert_eq!(rename_folder(v.path(), "Work", "work").unwrap(), "work");
        assert!(names_in(v.path()).contains(&"work".to_string()));
        assert!(rename_folder(v.path(), "work", "..").is_err());
    }

    #[test]
    fn trash_folder_cleans_layout() {
        let v = vault();
        create_folder(v.path(), "", "업무").unwrap();
        create_folder(v.path(), "업무", "회의").unwrap();
        let mut l = Layout::default();
        l.order.insert("".into(), vec!["업무".into()]);
        l.order.insert("업무".into(), vec!["회의".into()]);
        l.order.insert("업무/회의".into(), vec![]);
        layout::save(v.path(), &l).unwrap();
        // 실제 휴지통 대신 layout 갱신만 확인한다
        layout::update(v.path(), |l| l.remove_dir("업무")).unwrap();
        let l = layout::load(v.path());
        assert!(l.order[""].is_empty());
        assert_eq!(l.order.len(), 1);
    }

    // ── 옮기기 ──

    #[test]
    fn move_rejects_into_self_or_descendant() {
        let v = vault();
        create_folder(v.path(), "", "a").unwrap();
        create_folder(v.path(), "a", "b").unwrap();
        assert!(move_entry(v.path(), "a", "a").is_err());
        assert!(move_entry(v.path(), "a", "a/b").is_err());
        assert!(move_entry(v.path(), "없음.md", "a").is_err());
        assert!(move_entry(v.path(), "a/b", "../x").is_err());
        // 이름 접두사만 같은 폴더로는 옮길 수 있다
        create_folder(v.path(), "", "ab").unwrap();
        assert_eq!(move_entry(v.path(), "a", "ab").unwrap().to, "ab/a");
    }

    #[test]
    fn move_note_rewrites_links_across_depth() {
        let v = vault();
        write(v.path(), "attachments/p 1.png", "img");
        write(v.path(), "attachments/q.png", "img");
        write(
            v.path(),
            "메모/a.md",
            "제목\n![](../attachments/p%201.png) 글 ![q](../attachments/q.png \"제목\")\n\
             [웹](https://example.com/a.png) [메일](mailto:x@y.z) [앵커](#h) [절대](/etc/x.png) \
             ![데이터](data:image/png;base64,AAA=)\n[밖](../../outside.png) [옆](b.md#sec)\n\
             ```\n![](../attachments/q.png)\n```\n",
        );
        write(v.path(), "메모/b.md", "옆 메모");
        fs::create_dir_all(v.path().join("업무/회의")).unwrap();
        let m = move_entry(v.path(), "메모/a.md", "업무/회의").unwrap();
        assert_eq!(m, Moved { from: "메모/a.md".into(), to: "업무/회의/a.md".into(), is_dir: false });
        let c = fs::read_to_string(v.path().join("업무/회의/a.md")).unwrap();
        assert!(c.contains("![](../../attachments/p%201.png) 글"), "{c}");
        assert!(c.contains("![q](../../attachments/q.png \"제목\")"), "{c}");
        assert!(c.contains("[웹](https://example.com/a.png)"));
        assert!(c.contains("[메일](mailto:x@y.z)"));
        assert!(c.contains("[앵커](#h)"));
        assert!(c.contains("[절대](/etc/x.png)"));
        assert!(c.contains("(data:image/png;base64,AAA=)"));
        // 저장 폴더 밖으로 풀리는 링크는 그대로
        assert!(c.contains("[밖](../../outside.png)"));
        // 같이 옮겨지지 않은 메모로의 링크는 새 위치 기준
        assert!(c.contains("[옆](../../메모/b.md#sec)"), "{c}");
        // 코드 블록 안은 건드리지 않는다
        assert!(c.contains("```\n![](../attachments/q.png)\n```"));
        // 최상위로 옮기기
        let m = move_entry(v.path(), "업무/회의/a.md", "").unwrap();
        assert_eq!(m.to, "a.md");
        let c = fs::read_to_string(v.path().join("a.md")).unwrap();
        assert!(c.contains("![](attachments/p%201.png)"), "{c}");
        assert!(c.contains("[옆](메모/b.md#sec)"), "{c}");
    }

    #[test]
    fn move_note_name_collision_and_angle_links() {
        let v = vault();
        write(v.path(), "x/a.md", "<옛>\n![](<../attachments/공백 있는 그림.png>)");
        write(v.path(), "y/z/a.md", "이미 있음");
        let m = move_entry(v.path(), "x/a.md", "y/z").unwrap();
        assert_eq!(m.to, "y/z/a 2.md");
        let c = fs::read_to_string(v.path().join("y/z/a 2.md")).unwrap();
        assert!(c.contains("![](../../attachments/공백%20있는%20그림.png)"), "{c}");
        assert_eq!(fs::read_to_string(v.path().join("y/z/a.md")).unwrap(), "이미 있음");
    }

    #[test]
    fn move_folder_keeps_internal_links() {
        let v = vault();
        write(v.path(), "attachments/i.png", "img");
        write(
            v.path(),
            "프로젝트/개요.md",
            "개요\n[상세](세부/상세.md) ![](../attachments/i.png) [밖](../메모/c.md) [자기](개요.md)",
        );
        write(
            v.path(),
            "프로젝트/세부/상세.md",
            "상세\n[위로](../개요.md) ![](../../attachments/i.png) ![a](../../attachments/i.png)",
        );
        write(v.path(), "메모/c.md", "c");
        create_folder(v.path(), "", "보관").unwrap();
        create_folder(v.path(), "보관", "2026").unwrap();
        let mut l = Layout::default();
        l.order.insert("".into(), vec!["프로젝트".into(), "보관".into()]);
        l.order.insert("프로젝트".into(), vec!["세부".into()]);
        layout::save(v.path(), &l).unwrap();

        let m = move_entry(v.path(), "프로젝트", "보관/2026").unwrap();
        assert_eq!(m, Moved { from: "프로젝트".into(), to: "보관/2026/프로젝트".into(), is_dir: true });
        let a = fs::read_to_string(v.path().join("보관/2026/프로젝트/개요.md")).unwrap();
        assert!(a.contains("[상세](세부/상세.md)"), "{a}");
        assert!(a.contains("![](../../../attachments/i.png)"), "{a}");
        assert!(a.contains("[밖](../../../메모/c.md)"), "{a}");
        assert!(a.contains("[자기](개요.md)"), "{a}");
        let b = fs::read_to_string(v.path().join("보관/2026/프로젝트/세부/상세.md")).unwrap();
        assert!(b.contains("[위로](../개요.md)"), "{b}");
        assert_eq!(b.matches("../../../../attachments/i.png").count(), 2, "{b}");
        let l = layout::load(v.path());
        assert_eq!(l.order[""], vec!["보관"]);
        assert_eq!(l.order["보관/2026/프로젝트"], vec!["세부"]);
        assert!(!l.order.contains_key("프로젝트"));
    }

    #[test]
    fn move_to_same_folder_is_noop() {
        let v = vault();
        write(v.path(), "메모/a.md", "a");
        let m = move_entry(v.path(), "메모/a.md", "메모").unwrap();
        assert_eq!(m.to, "메모/a.md");
    }

    #[test]
    fn rewrite_links_unit() {
        // 깊이가 같으면 바뀌지 않는다
        let s = "![](../attachments/a.png)";
        assert_eq!(rewrite_links(s, "x", "y", None), s);
        // 이미지 여러 개, 퍼센트 인코딩
        let s = "![](../attachments/a%20b.png)![](../attachments/c.png)";
        assert_eq!(
            rewrite_links(s, "x", "x/y", None),
            "![](../../attachments/a%20b.png)![](../../attachments/c.png)"
        );
        // 괄호가 든 대상
        assert_eq!(rewrite_links("[a](p(1).png)", "x", "", None), "[a](x/p%281%29.png)");
        // 앞 공백과 제목 유지
        assert_eq!(rewrite_links("[a]( b.png 'c')", "x", "", None), "[a]( x/b.png 'c')");
        // 빈 대상, 짝이 안 맞는 것
        assert_eq!(rewrite_links("[a]() [b](", "x", "", None), "[a]() [b](");
        assert_eq!(relative_path("a/b", "a/c/d.png"), "../c/d.png");
        assert_eq!(relative_path("", "attachments/x.png"), "attachments/x.png");
    }

    // ── 첨부 ──

    #[test]
    fn save_attachment_checks_and_link() {
        use base64::Engine;
        let v = vault();
        write(v.path(), "업무/회의/a.md", "a");
        write(v.path(), "top.md", "t");
        let data = base64::engine::general_purpose::STANDARD.encode([137u8, 80, 78, 71, 1, 2, 3]);
        let link = save_attachment(v.path(), "업무/회의/a.md", "스크린샷.PNG", &data).unwrap();
        assert!(link.starts_with("../../attachments/"), "{link}");
        assert!(link.ends_with(".png"));
        let name = link.rsplit('/').next().unwrap();
        // YYYYMMDD-HHMMSS-xxxx.png
        let stem = name.trim_end_matches(".png");
        let parts: Vec<&str> = stem.split('-').collect();
        assert_eq!(parts.len(), 3, "{name}");
        assert_eq!(parts[0].len(), 8);
        assert_eq!(parts[1].len(), 6);
        assert_eq!(parts[2].len(), 4);
        assert!(parts[2].chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(fs::read(v.path().join("attachments").join(name)).unwrap(), vec![137u8, 80, 78, 71, 1, 2, 3]);
        // 최상위 메모, data URL
        let link = save_attachment(v.path(), "top.md", "a.jpeg", &format!("data:image/jpeg;base64,{data}")).unwrap();
        assert!(link.starts_with("attachments/") && link.ends_with(".jpeg"), "{link}");
        // 확장자 검사
        assert!(save_attachment(v.path(), "top.md", "a.svg", &data).is_err());
        assert!(save_attachment(v.path(), "top.md", "a.exe", &data).is_err());
        assert!(save_attachment(v.path(), "top.md", "noext", &data).is_err());
        for ext in ATTACHMENT_EXTS {
            assert!(save_attachment(v.path(), "top.md", &format!("x.{ext}"), &data).is_ok(), "{ext}");
        }
        // 크기 검사
        let big = base64::engine::general_purpose::STANDARD.encode(vec![0u8; ATTACHMENT_MAX_BYTES + 1]);
        assert!(save_attachment(v.path(), "top.md", "big.png", &big).unwrap_err().contains("20MB"));
        let ok = base64::engine::general_purpose::STANDARD.encode(vec![0u8; ATTACHMENT_MAX_BYTES]);
        assert!(save_attachment(v.path(), "top.md", "max.png", &ok).is_ok());
        // 깨진 base64, 볼트 밖 메모
        assert!(save_attachment(v.path(), "top.md", "a.png", "@@@").is_err());
        assert!(save_attachment(v.path(), "../x.md", "a.png", &data).is_err());
        // 첨부 폴더는 목록에서 빠진다
        let t = list_tree(v.path()).unwrap();
        assert!(t.folders.iter().all(|f| f.name != ATTACHMENTS_DIR));
    }
}
