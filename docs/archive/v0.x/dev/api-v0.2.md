# 개발 문서 — 프런트엔드 ↔ 백엔드 인터페이스 계약 (v0.2)

| 항목 | 내용 |
|---|---|
| 작성 | 개발 |
| 최종 수정 | 2026-11-07 |
| 관련 | [PRD v0.2](../pm/PRD-v0.2.md), [디자인 v0.2](../design/design-spec-v0.2.md) |

백엔드(Rust, `src-tauri/`)와 프런트엔드(`src/`)는 이 문서만 보고 서로 맞춘다. 바꿀 일이 생기면 이 문서부터 고친다.
- 모든 경로는 **저장 폴더 기준 상대 경로**이고 구분자는 `/`다.
- 명령 이름은 snake_case, 인자와 결과 필드는 camelCase(serde `rename_all = "camelCase"`)로 쓴다.

## 1. 자료형

```ts
type StickyColor = "yellow" | "pink" | "blue" | "green" | "purple";

interface StickyMeta {
  color: StickyColor;
  x: number | null; y: number | null;   // 논리 픽셀, null이면 OS 기본 위치
  w: number; h: number;
  onTop: boolean;
  open: boolean;                         // 지금 꺼내져 있는지
}

interface NoteMeta {
  path: string;            // "업무/회의/주간 회의.md"
  folder: string;          // "업무/회의", 최상위면 ""
  title: string;           // 제목 추출 규칙(5장)의 결과. 비면 ""
  preview: string;         // 두 번째 의미 있는 줄
  modified: number;        // ms
  pinned: boolean;         // frontmatter pinned: true
  sticky: StickyMeta | null; // frontmatter sticky가 있으면
  readable: boolean;       // UTF-8로 읽히면 true
}

interface FolderNode {
  path: string;            // "업무/회의"
  name: string;            // "회의"
  modified: number;        // 하위 트리 안 메모들의 최대 modified(없으면 폴더 mtime)
  children: FolderNode[];  // 이름순(로캘 무관 유니코드 순). 화면 정렬은 프런트가 한다
}

interface Layout {
  sort: "custom" | "name" | "recent";
  // 부모 폴더 경로("" = 최상위) → 직접 정렬 순서. 항목은 하위 폴더 '이름' 또는 구분선 id("sep:<임의>")
  order: Record<string, string[]>;
}

interface Tree { folders: FolderNode[]; notes: NoteMeta[]; layout: Layout; }

interface Prefs {
  fontFamily: "system" | "pretendard" | "serif" | "mono" | "custom";
  customFont: string;
  fontSize: number;          // 14~22, 기본 17
  sidebarCollapsed: boolean;
  noteSort: "modified" | "name";
}
```

## 2. 명령

| 명령 | 인자 | 결과 | 규칙 |
|---|---|---|---|
| `get_vault` | — | `string \| null` | 절대 경로 |
| `set_vault` | `path` | — | 열린 스티키 창을 모두 닫는다(BUG-09). 감시를 다시 시작하고 에셋 범위를 허용한다. config 저장 |
| `get_prefs` / `set_prefs` | — / `prefs` | `Prefs` / — | config.json에 저장한다. 저장 후 `prefs-changed` 이벤트를 모든 창에 보낸다 |
| `list_tree` | — | `Tree` | 숨김(`.`으로 시작)과 최상위 `attachments/`는 뺀다. 읽을 수 없는 폴더는 건너뛴다(BUG-07). notes는 modified 내림차순 |
| `read_note` | `path` | `string` | UTF-8이 아니면 오류 문자열 `"NOT_UTF8"` |
| `write_note` | `path, content` | — | 원자적 쓰기 |
| `create_note` | `folder` | 새 경로 | folder가 ""이면 `메모/`에 만들고, 그 폴더가 없으면 만든다(BUG-08) |
| `sync_note_name` | `path` | 새 경로 | 디스크 내용의 제목으로 파일 이름을 맞춘다. 이름이 바뀌면 `entry-moved` 이벤트를 보낸다. 대소문자만 다르면 임시 이름을 거친다(BUG-14) |
| `trash_note` | `path` | — | 휴지통(NSFileManager) |
| `create_folder` | `parent, name` | 새 경로 | 이름이 겹치면 " 2"를 붙인다. 점으로만 된 이름이나 빈 이름은 오류(BUG-16) |
| `rename_folder` | `path, name` | 새 경로 | layout의 키와 부모 order의 이름을 함께 고친다. `entry-moved`(isDir) |
| `trash_folder` | `path` | — | layout에서 그 폴더와 하위 키를 지운다 |
| `move_entry` | `from, toFolder` | 새 경로 | 파일이나 폴더를 옮긴다. 자기 자신이나 하위로는 못 옮긴다(오류). 이름이 겹치면 번호를 붙인다. **옮겨진 모든 .md의 상대 링크를 다시 계산한다**(6장). layout을 반영하고 `entry-moved`를 보낸다 |
| `set_layout` | `layout` | — | `.modoit/layout.json`에 원자적으로 쓴다 |
| `save_attachment` | `notePath, fileName, dataBase64` | 메모 기준 상대 링크 (`../attachments/20261107-162233-a1b2.png`) | `attachments/`에 저장한다. 확장자는 png, jpg, jpeg, gif, webp, heic, bmp, tiff만, 20MB 이하 |
| `open_sticky` | `path, geom: {x,y,w,h,onTop}` | — | NSPanel로 띄운다. 위치가 연결된 모니터 밖이면 OS 기본 위치(BUG-12). 이미 열려 있으면 앞으로 가져온다 |
| `close_sticky_window` | `path` | — | |
| `set_sticky_on_top` | `path, onTop` | — | 패널 레벨 변경 |
| `show_main` | `path?` | — | 메인 창을 보이고 앞으로 가져온다. path가 있으면 `open-note {path}` 이벤트를 보낸다 |

## 3. 이벤트 (Rust → 모든 창)

| 이벤트 | 내용 | 언제 |
|---|---|---|
| `vault-changed` | — | 파일 시스템 변경(250ms 묶음) |
| `entry-moved` | `{from, to, isDir}` | sync_note_name, rename_folder, move_entry. 열려 있는 편집기와 스티키 창은 경로를 갱신한다. isDir이면 `from/` 접두사를 `to/`로 바꾼다 |
| `prefs-changed` | `Prefs` | set_prefs |
| `menu` | `string` (메뉴 id) | 메뉴 막대 선택 |
| `open-note` | `{path}` | show_main(path) |
| `app-will-quit` | — | ⌘Q 등 종료 요청. 창들은 남은 입력을 즉시 저장한다. Rust는 700ms 뒤 종료한다(BUG-10) |

메뉴 id: `new-note`, `new-sticky-note`, `new-folder`, `pop-out`, `toggle-pin`, `change-vault`, `toggle-sidebar`, `find`, `settings`, `about`

## 4. 창
- 메인 창(`main`)
  - 닫기 버튼을 누르면 숨긴다. 독 아이콘을 누르면(Reopen) 다시 보인다(FR-42).
  - `dragDropEnabled: false`로 webview가 HTML5 끌어 놓기와 파일 드롭을 직접 처리한다.
- 스티키 창(`sticky-<n>`): Rust가 `path → label` 표를 관리하고 `entry-moved` 때 갱신한다.
  - 초기화 스크립트로 `window.__MODOIT_STICKY__ = "<path>"`를 넣는다.
  - 경로가 바뀌면 그 창에 `entry-moved`가 가므로 창은 스스로 경로를 갱신한다.
  - NSPanel 설정: non-activating, 모든 Spaces와 전체 화면 보조에 표시, 키 입력은 필요할 때만 받는다.

## 5. 제목 추출 규칙 (Rust 단일 구현, BUG-17/18)
1. 맨 앞 BOM과 frontmatter를 건너뛴다.
2. 비어 있지 않은 첫 줄을 고른다. `---`, ```` ``` ````, 이미지만 있는 줄은 건너뛴다.
3. 줄 앞의 목록·체크박스·제목·인용 기호(`- `, `* `, `+ `, `1. `, `[ ]`, `[x]`, `[X]`, `#…`, `>`)를 뗀다.
4. 인라인 강조 기호(`**`, `__`, `*`, `_`, `~~`, `` ` ``)를 뗀다. 링크 `[글](주소)`는 `글`만 남긴다.
5. HTML 엔티티(`&amp; &lt; &gt; &quot; &#39; &nbsp; &#…;`)를 풀고, 전각 공백과 NBSP를 일반 공백으로 바꾼 뒤 양끝을 다듬는다.

파일 이름 규칙: 위 제목에서 다음을 처리한다.
- `/ \ : * ? " < > |`와 제어문자(U+0000~001F, U+007F~009F, U+FEFF)를 공백으로 바꾸고, 연속 공백은 하나로 줄인다.
- 앞뒤의 점과 공백을 지운다.
- 60자(문자 기준)로 자른 뒤 끝의 점과 공백을 다시 지운다.
- 결과가 비면 `새 메모`로 한다.

## 6. 상대 링크 재작성 (FR-33)
- 대상: Markdown 링크와 이미지 `[..](target)`, `![..](target)`. 다음 target은 건드리지 않는다.
  - `http:`, `https:`, `mailto:`, `data:`, `#`, `/`로 시작하는 것
  - 이미 절대 경로인 것
- target(퍼센트 인코딩과 `<...>` 감싸기 허용)을 **옛 위치 기준**으로 풀어 저장 폴더 안의 경로를 얻는다. 그 경로를 **새 위치 기준** 상대 경로로 다시 쓴다.
  - 저장 폴더 밖으로 풀리는 링크는 그대로 둔다.
  - 공백이 있으면 `%20`으로 인코딩해 쓴다.
- 폴더를 통째로 옮기면 그 안의 .md마다 깊이 변화를 계산한다. 함께 옮겨진 파일끼리의 링크는 그대로 맞아야 한다.
