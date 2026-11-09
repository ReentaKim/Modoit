# 개발 문서 — v2 아키텍처 (Swift 네이티브, 검토안)

| 항목 | 내용 |
|---|---|
| 작성 | 개발 |
| 최종 수정 | 2026-11-09 |
| 상태 | **착수 결정(2026-11-09).** [Brief](../product/brief.md)·기능 카드 확정 뒤 갱신한다 |
| 관련 문서 | [아키텍처 v0.2](architecture.md), [인터페이스 계약 v0.3](../archive/v0.x/dev/api-v0.3.md), [PRD v0.3](../archive/v0.x/pm/PRD-v0.3.md) |
| 스파이크 | [`spike/`](../../spike/README.md) |

> **대표 결정 (2026-11-09)**
> - v2를 진행한다. 먼저 v0.3의 BUG-35(종료 시 저장 누락)를 고친다(v0.4).
> - **iOS는 당분간 고려하지 않는다.** macOS만 대상으로 한다. 아래 iOS 관련 항목은 보류다.
> - 스티키는 추천안대로 한다. 많이 쓰는 서식은 네이티브로 그리고, 표·토글처럼 어려운 서식이 있는 메모만 앱 안의 TipTap 편집기로 연다. 경계는 [F-08](../product/features/F-08-sticky.md) 3.2(D-12).
> - 이후 결정은 [결정 기록](../decisions.md)에 있다.

## 1. 왜 바꾸는가
- 목표가 macOS 다음 **iOS**까지 넓어졌다. 지금의 Tauri + React 구조로는 iOS다운 화면과 iOS 기능(위젯, Shortcuts)을 만들기 어렵다.
- 스티키마다 WKWebView와 React, TipTap이 통째로 하나씩 뜬다. 스티키가 늘수록 메모리가 함께 는다.
- 웹 편집기의 한글 조합 처리 문제가 계속 나온다(BUG-13, BUG-20, G-14).
- `macOSPrivateApi: true` 때문에 Mac App Store에 올릴 수 없다.

## 2. 기술 스택

| 영역 | v0.3 | v2 |
|---|---|---|
| 앱 셸 | Tauri 2 | **SwiftUI** + 필요한 곳만 AppKit(NSPanel, 메뉴) / UIKit |
| 코어 로직 | Rust (`src-tauri/src`) | **Swift Package `ModoitCore`** (macOS·iOS 공용) |
| 편집기 | TipTap 3 (React) | v2.0: **같은 TipTap 번들을 WKWebView에** / v2.x: TextKit 2 네이티브 검토 |
| 스티키 | NSPanel(tauri-nspanel, private API) | NSPanel(공개 API) / iOS: WidgetKit 위젯 |
| 파일 감시 | notify(FSEvents) | macOS: FSEvents / iOS: NSFilePresenter·NSMetadataQuery |
| 최소 OS | macOS 13 | **macOS 15** (D-09). iOS는 보류(D-03) |
| 배포 | dmg + Homebrew cask(서명 없음) | 같은 방식. 공증·Mac App Store는 하지 않음(D-11, 비용) |

## 3. 구조

```
┌──────────── macOS 앱 (SwiftUI) ────────────┐   ┌──────── iOS 앱 (SwiftUI) ────────┐
│ NavigationSplitView: 폴더 · 메모 목록 · 편집 │   │ NavigationStack / SplitView        │
│ Settings 씬, 메뉴 명령                       │   │ WidgetKit(스티키 대신), AppIntents │
│ StickyPanel (NSPanel, non-activating)        │   │                                    │
└───────────────┬──────────────────────────────┘   └───────────────┬────────────────────┘
                │            EditorView (공용)                      │
                │   WKWebView ─ editor.html(TipTap) ─ JS 브리지      │
                ▼                                                   ▼
┌────────────────────────────── ModoitCore (Swift Package) ─────────────────────────────┐
│ Vault        경로 검증, 트리, 제목↔파일 이름, 원자적 쓰기, 첨부 저장, 이동+링크 재작성  │
│ Frontmatter  split/join, sticky 메타                                                     │
│ Layout       .modoit/layout.json                                                         │
│ NoteSession  0.5초 지연 저장, 3-way 병합, 재시도                                         │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## 4. 편집기 브리지 (v2.0)
- `src/editor/*`는 그대로 쓴다. Vite 진입점 `editor-host.html` 하나를 더 만들어 편집기만 번들한다.
- Tauri 의존 두 곳만 shim으로 바꾼다.
  - `convertFileSrc(path)` → `modoit-file://` 주소. Swift의 `WKURLSchemeHandler`가 저장 폴더 안 파일만 내준다(경로 검증은 `ModoitCore`).
  - `invoke("save_attachment", …)` → `window.webkit.messageHandlers.modoit`로 보내고 응답을 Promise로 돌려받는다.
- 메시지

| 방향 | 이름 | 내용 |
|---|---|---|
| Swift → JS | `load` | `{ markdown, notePath, vault, compact, readOnly, theme, accent }` |
| JS → Swift | `ready` | 편집기 준비 완료 |
| JS → Swift | `change` | `{ markdown }` (사용자 변경만, v0.3 규칙 그대로) |
| JS → Swift | `saveAttachment` | `{ id, notePath, fileName, dataBase64 }` → 응답 `{ id, result \| error }` |

## 5. 설계 결정 (ADR)

| # | 결정 | 이유 |
|---|---|---|
| ADR-10 | v2 앱 셸은 SwiftUI | macOS·iOS 화면 코드를 함께 쓰고, OS 새 디자인을 자동으로 따른다 |
| ADR-11 | 코어 로직은 Rust를 Swift로 옮긴다 (UniFFI 아님) | 1인 프로젝트에서 빌드 체인 하나가 유지하기 쉽다. cargo test 44개를 명세로 삼아 같은 결과를 확인한다 |
| ADR-12 | v2.0 편집기는 기존 TipTap을 WKWebView로 | 표·토글·슬래시 명령·원본 보존을 갖춘 네이티브 Markdown 편집기가 없다. 다시 만들면 수개월 |
| ADR-13 | 스티키 편집기부터 네이티브 전환을 검토 | 스티키는 기능이 적고, 여러 개 뜰 때 메모리 이득이 가장 크다 |
| ADR-14 | NSPanel은 공개 API만 쓴다 | `macOSPrivateApi`를 없애 Mac App Store 길을 연다 |
| ADR-15 | 저장 형식·폴더 구조·frontmatter·layout.json은 v0.3과 같다 | v0.3과 v2가 같은 저장 폴더를 함께 열 수 있어야 한다 |

## 6. 스파이크로 확인할 것
1. 스티키 N개(5·10)일 때 메모리: v0.3 vs v2 웹 스티키 vs v2 네이티브 스티키
2. 콜드 스타트 시간
3. TipTap이 WKWebView 브리지에서 v0.3과 같은 Markdown을 내는지(열기만 해서는 쓰지 않음 포함)
4. 한글 입력(G-14 시나리오): 웹 편집기 vs NSTextView

결과는 [`spike/README.md`](../../spike/README.md)에 적는다.

### 6.1 결과 요약 (2026-11-09)

| 스티키 10개 | v0.3 Tauri | v2 웹 스티키 | v2 네이티브 스티키 |
|---|---|---|---|
| 메모리 합계 | 1,391 MB | 906~1,134 MB | 152~202 MB |
| 스티키 1개당 | 약 120 MB | 약 75~100 MB | 약 5 MB |
| 준비 시간 | (측정 안 함) | 804 ms | 509 ms |

- 1: 확인함. **네이티브 스티키에서만 큰 이득이 난다.** 그래서 ADR-13을 v2.x 선택 사항이 아니라 **v2.0 범위로 올리는 것을 권한다.**
- 2: v2만 측정함(0.4~0.9초).
- 3: 일부 확인함. 표·체크리스트가 v0.3처럼 그려지고, 열기만 해서는 파일을 쓰지 않는다. **입력한 뒤 저장되는 Markdown이 v0.3과 같은지는 아직 확인하지 않았다.**
- 4: 수동 확인 필요(G-14).
