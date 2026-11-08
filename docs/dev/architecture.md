# 개발 문서 — 아키텍처 (v0.2)

| 항목 | 내용 |
|---|---|
| 작성 | 개발 |
| 최종 수정 | 2026-11-07 |
| 관련 문서 | [PRD v0.2](../pm/PRD-v0.2.md), [디자인 명세 v0.2](../design/design-spec-v0.2.md), [인터페이스 계약 v0.2](api-v0.2.md) |
| 이전 판 | v0.1 내용은 git 이력에서 볼 수 있다. v0.2부터 **macOS 전용**이다 |

## 1. 기술 스택

| 영역 | 선택 |
|---|---|
| 앱 셸 | Tauri 2 (`macos-private-api`, `protocol-asset`) |
| 백엔드 | Rust 1.99 (edition 2024) |
| 프런트엔드 | React 19 + TypeScript + Vite 8 |
| 편집기 | TipTap 3.33: StarterKit, TaskList·TaskItem, Image, TableKit, Placeholder, Suggestion, @tiptap/markdown |
| 아이콘 / 글꼴 | @phosphor-icons/react / Pretendard Variable(앱에 포함) |
| Rust 크레이트 | tauri-nspanel(스티키 NSPanel), tauri-plugin-dialog, notify, trash, window-vibrancy, serde_yaml_ng, base64 |
| JS 라이브러리 | yaml(frontmatter 보존 편집), marked(지원 서식 판정) |
| 테스트 | cargo test(44), vitest(32 이상), tsc |

## 2. 구조

```
┌─────────── 메인 창 (main) ───────────┐     ┌── 스티키 패널 (sticky-N, NSPanel) ──┐
│ App ─ Sidebar(폴더 트리·끌어 놓기)    │     │ StickyApp                            │
│     ─ NoteList(고정·정렬·끌기)        │     │   └ ModoitEditor (compact)           │
│     ─ EditorPane ─ ModoitEditor       │     │                                      │
│     ─ Settings                        │     │                                      │
│  lib: noteSession · frontmatter · sidebar · markdownSafety · paths · prefs · menu    │
└──────────────┬────────────────────────┘     └──────────────┬───────────────────────┘
               │ invoke (명령 20개)      ▲ 이벤트 6종           │
               ▼                         │                     ▼
┌──────────────────────────── Rust (src-tauri/src) ─────────────────────────────────┐
│ lib.rs     명령, 메뉴 막대, 메인 창 숨기기·Reopen, ⌘Q 저장 후 종료, 에셋 범위       │
│ vault.rs   경로 검증, 트리, 제목·파일 이름 규칙, frontmatter 판독, 이동+링크 재작성, │
│            첨부 저장, 원자적 쓰기                                                   │
│ layout.rs  .modoit/layout.json (사이드바 순서·구분선·정렬)                          │
│ sticky.rs  NSPanel 생성, path→label 표, 화면 밖 위치 보정                           │
│ watcher.rs 파일 감시 (.modoit·임시 파일 무시), config.rs 설정·Prefs                  │
└────────────────────────────────────┬──────────────────────────────────────────────┘
                                     ▼
          저장 폴더:  메모/…/*.md   attachments/*.png   .modoit/layout.json
```

## 3. 핵심 설계

### 3.1 메모 = 스티키 (FR-30)
- 스티키는 별도 문서가 아니다. **메모 파일 하나를 패널로 꺼낸 것**이다.
- 꺼낸 정보(색, 위치, 크기, 항상 위, 열림)는 그 메모의 frontmatter `sticky: {…}` 한 줄에 둔다.
- 메인 편집기와 스티키 패널은 같은 파일을 연다. 각 창이 가진 `NoteSession`(`src/lib/noteSession.ts`)이 **본문만** 저장한다.
  - frontmatter는 저장할 때마다 디스크 최신본을 그대로 쓴다(`updateNote` 읽기→수정→쓰기).
  - 그래서 스티키 위치를 옮겨도 메인 편집기 저장이 그 정보를 덮어쓰지 않는다.
- 다른 창이 저장하면 `vault-changed`를 받은 창은, 자기가 입력 중(pending)이 아닐 때만 다시 읽는다.

### 3.2 저장 세션 (BUG-02, 04, 05, 22 대응)
- 메모를 열 때마다 새 `NoteSession`을 만든다. 메모를 바꾸면 이전 세션은 **혼자 저장을 끝내고 닫힌다.** 새 선택에는 관여하지 않는다.
- 저장 순서
  1. 입력하면 0.5초 뒤 본문을 저장한다.
  2. 이어서 `sync_note_name`으로 파일 이름을 제목에 맞춘다(규칙은 Rust 한곳에만 있다).
  3. 이름이 바뀌면 Rust가 `entry-moved`를 보내고, 모든 창이 세션 경로와 선택을 갱신한다.
- 실패하면 안내 막대를 띄우고 3초마다 다시 시도한다.
- 이번 실행에서 앱이 만든 빈 메모만 떠날 때 휴지통으로 보낸다.
- **열기만 해서는 절대 쓰지 않는다**: 편집기 `onUpdate`는 사용자 트랜잭션(`transaction.docChanged`)이고 편집 가능할 때만 저장을 요청한다. TipTap이 스스로 덧붙이는 변경(끝 빈 문단 등)은 무시한다. 통합 중 발견해 고친 결함이다.

### 3.3 원본 Markdown 보호 (BUG-01, 03 / FR-43)
- `encodeMarkdownText`: 다시 읽을 때 문법이 되는 경우에만 이스케이프한다. TipTap 기본 구현을 교체했다.
  - 바꾸지 않는 예: `R&D`, `a < b`, `snake_case`, `[[위키]]`
- `findUnsupported`: marked 토큰을 검사한다. HTML, 참조 링크 정의, 밑줄식 제목, 링크·이미지 title이 있으면 **읽기 전용**으로 열고, 사용자가 "그래도 편집"을 눌러야만 편집할 수 있다.
- frontmatter 판정은 Rust `split_frontmatter`와 TS `splitNote`가 같은 규칙을 쓴다. `---` 사이가 YAML 매핑일 때만 frontmatter로 본다.
- `tidyMarkdown`: 표 변환기가 덧붙이는 빈 줄을 하나로 줄인다.

### 3.4 폴더 트리·순서·구분선 (FR-26~29)
- 폴더는 실제 디렉터리다. 순서와 구분선은 디렉터리로 표현할 수 없어서 `.modoit/layout.json`에 둔다.
  - `order[부모경로] = [폴더이름 | "sep:id"]`
- 화면 순서 계산은 프런트 `src/lib/sidebar.ts`의 순수 함수가 맡는다(단위 테스트 있음). 이름순·최신순은 구분선으로 나뉜 구역 안에서만 정렬한다.
- 정렬 모드에서 순서를 끌어 바꾸면, 지금 화면 순서를 모든 부모에 고정한 뒤 직접 정렬로 바꾼다.
- 폴더 이동·이름 변경·삭제 때 layout 키는 Rust가 함께 고친다.

### 3.5 이미지 (FR-32, 33)
- 붙여넣기, 드롭, `/이미지` → `save_attachment`(base64) → `attachments/날짜시각-임의.ext`
  - 메모에는 `![](../attachments/…)` 상대 링크가 들어간다.
- 화면 표시: `NoteImage` 노드는 `src` 속성에 상대 경로를 그대로 둔다. 렌더링할 때만 `convertFileSrc`로 `asset:` 주소를 만든다.
  - 편집기 안에서 복사·붙여넣기할 때는 `data-src`의 원래 경로를 쓴다.
- 이동 시 `move_entry`가 옮겨진 모든 .md의 상대 링크를 다시 계산한다.
  - 코드 블록과 `scheme:` 링크는 건드리지 않는다.
  - 공백, `%`, `()`, `<>`, `#`, `?`는 퍼센트 인코딩한다.
- 이동 직후 열린 편집기와 스티키는 고쳐진 링크를 받기 위해 디스크에서 다시 읽는다.

### 3.6 macOS 통합 (FR-40~42)
- 스티키 = NSPanel
  - non-activating, 모든 Spaces + 전체 화면 보조, key window 가능
  - onTop이면 Floating 레벨, 아니면 Normal 레벨
  - accept_first_mouse
- 메뉴 막대: 메뉴를 고르면 `menu` 이벤트(id)를 보낸다. accelerator를 쓰므로 한글 입력 상태에서도 단축키가 동작한다(BUG-13, 20).
- 메인 창 닫기는 숨기기다. Dock 아이콘(Reopen)이나 ⌘0으로 다시 보인다.
- ⌘Q
  - 직접 만든 quit 항목 → `app-will-quit` 이벤트 → 700ms 뒤 종료
  - 한계: Dock 우클릭 "종료"와 로그아웃은 이 경로를 거치지 않는다.

## 4. 보안
- 모든 파일 경로는 `vault::resolve`에서 검증한다. 절대 경로, `..`, 심볼릭 링크로 밖을 가리키는 경로를 차단한다.
- CSP: `default-src 'self'; img-src 'self' asset: http://asset.localhost data: blob:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; connect-src 'self' ipc: http://ipc.localhost`
- 에셋 프로토콜은 런타임에 저장 폴더만 허용한다. 쓰지 않는 opener 플러그인은 없앴다.
- 첨부: 이미지 확장자만 받고 20MB까지만 허용한다.

## 5. 설계 결정 (ADR)

| # | 결정 | 이유 |
|---|---|---|
| ADR-1 | Tauri 2, macOS 전용 | Windows 계획을 폐기했다. NSPanel과 메뉴 막대 같은 macOS 전용 기능을 마음껏 쓴다 |
| ADR-2 | 파일 입출력은 Rust 명령만 사용 | 경로 검증을 한곳에서 한다 |
| ADR-3 | 설정은 Rust가 config.json으로 관리 | 시작할 때 저장 폴더가 필요하다 |
| ADR-4 | 목록 밖 Tab = 전각 공백 | 공백·탭은 코드 블록이 된다 |
| ADR-5 | 스티키 하나 = 패널 하나 | 바탕화면 어디에나 따로 붙인다 |
| ADR-6 | 스티키 정보는 메모 frontmatter | 이름 변경과 이동에도 따라간다(사용자 결정) |
| ADR-7 | 사이드바 순서는 `.modoit/layout.json` | 디렉터리로는 순서와 구분선을 표현할 수 없다 |
| ADR-8 | 이미지는 상대 링크 + asset 프로토콜 표시 | 다른 Markdown 도구에서도 링크가 맞는다 |
| ADR-9 | 이동할 때 Rust가 링크를 다시 쓴다 | 폴더 정리가 이미지 깨짐으로 이어지지 않게 한다 |
| ADR-10 | 제목·파일 이름 규칙은 Rust 단일 구현 | TS와 Rust의 규칙 불일치(BUG-17, 18)를 원천 제거한다 |
| ADR-11 | 사용자 트랜잭션만 저장 | 열기만 해도 원본이 바뀌는 문제를 막는다 |

## 6. 실행 · 빌드 · 테스트

```bash
npm install
npm run tauri dev                 # 개발 실행
npm run tauri build               # .app / .dmg
npx vitest run && npx tsc --noEmit
cd src-tauri && cargo test --lib  # Rust 44개
```

## 7. 알려진 제약 (v0.2)
- 앱 아이콘은 아직 Tauri 기본 아이콘이다.
- Dock 우클릭 "종료"와 로그아웃 때는 마지막 0.5초 입력이 저장되지 않을 수 있다.
- 메인 편집기와 스티키에서 **같은 순간에 동시에** 입력하면 나중에 저장한 쪽이 이긴다.
- 쓰지 않게 된 이미지 파일은 자동으로 정리하지 않는다.
- 다음은 자동 GUI 테스트가 불가능해 수동 확인이 필요하다: NSPanel의 포커스 비활성 동작, Spaces와 전체 화면 위 표시, 끌어 놓기 실제 조작.

## v0.3 결정 (ADR-12 ~ ADR-15)
- **ADR-12 두 창 동시 편집은 저장 시점 3-way 병합.** 잠금이나 실시간 동기화 대신, 저장 직전 디스크 본문을 기준(base)과 비교해 node-diff3로 줄 단위 병합한다. 같은 줄 충돌은 버리지 않고 양쪽을 남긴다. 창을 떠날 때(blur) 바로 저장해 충돌 창을 줄인다. (BUG-26)
- **ADR-13 다크 모드 = 앱 appearance.** `AppHandle::set_theme`으로 NSApp appearance를 바꾸면 WKWebView의 `prefers-color-scheme`, 반투명 사이드바, 네이티브 메뉴가 함께 바뀐다. 색은 CSS 토큰 하나로 관리하고, JS에서 테마 상태를 따로 들고 있지 않는다. (FR-45)
- **ADR-14 생성일은 파일 시스템 crtime.** 원자적 쓰기가 새 inode를 만들어 crtime이 초기화되므로, 바꿔 끼우기 전에 원본 crtime을 임시 파일에 옮긴다(`FileTimesExt::set_created`). frontmatter에 날짜를 쓰지 않는다. 메모 파일을 깨끗하게 둔다는 원칙(NFR-09)에 따른 것이다. v0.2로 이미 저장한 메모는 마지막 저장 시각이 생성일로 남는다. (FR-47)
- **ADR-15 토글 = `<details>` HTML + 전용 토크나이저.** `@tiptap/extension-details`(MIT)의 기본 Markdown 형식(`:::details`)을 덮어쓴다. 다른 앱에서도 접혀 보이는 `<details>`로 읽고 쓴다. 안전성 검사(`findUnsupported`)는 이 꼴의 태그 줄만 걷어 내고 안쪽을 검사한다. (FR-48, NFR-14)
