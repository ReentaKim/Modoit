# v2 아키텍처 (Swift 네이티브)

| 항목 | 내용 |
|---|---|
| 문서 | v2.0을 어떻게 만드나, 구조를 왜 그렇게 정했나. **살아 있는 문서** |
| 담당 | 개발 (초안 AI → 검토 개발 → 확정 대표) |
| 최종 수정 | 2026-11-10 |
| 상태 | **확정** (2026-11-10, D-23) |
| 함께 보는 문서 | [Brief](../product/brief.md)(무엇을·왜) · [기능 카드](../product/features/) · [결정 기록](../decisions.md) · [스파이크 결과](../../spike/README.md) · [v0.x 아키텍처](architecture.md) |

> **검토 요청:** 없음. 2026-11-10 대표 확정([D-23](../decisions.md)). V2-11의 2차 스파이크 결과가 나오면 3.3을 갱신한다.

## 1. 왜 바꾸는가
문제와 목표는 [Brief 1~2장](../product/brief.md)에 있다. 구조와 직접 관련된 것만 적는다.
- v0.x는 창(메인, 스티키)마다 웹 화면 하나와 편집기 전체가 뜬다. 스티키 1개당 약 120 MB다.
- 창들이 서로 다른 프로세스라, 같은 메모를 두 창에서 고칠 때 파일을 거쳐 병합해야 했다(BUG-26, 39, G-14).
- `macOSPrivateApi`(비공개 API)를 써야 스티키 패널을 만들 수 있었다.

## 2. 기술 스택
| 영역 | v0.x | v2.0 |
|---|---|---|
| 앱 셸 | Tauri 2 | SwiftUI + 필요한 곳만 AppKit(NSPanel, NSTextView, 종료 처리) |
| 코어 로직 | Rust `src-tauri/src` | Swift 패키지 `ModoitCore` (UI 없음, 플랫폼 중립) |
| 메인 편집기 | TipTap 3 (React) | **같은 TipTap 코드**(`src/editor`)를 WKWebView에 |
| 스티키 화면 | TipTap(창마다 하나) | 네이티브(NSTextView). 어려운 서식이 있는 메모만 TipTap([F-08](../product/features/F-08-sticky.md) 3.2). 보기 전용이고 체크만 한다(D-25) |
| 스티키 창 | NSPanel(비공개 API) | NSPanel(공개 API만, NFR-19) |
| 파일 감시 | notify(FSEvents) | FSEvents |
| 최소 OS | macOS 13 | macOS 15 (D-09) |
| 언어 | Rust, TypeScript | Swift 6(엄격한 동시성 검사), 편집기만 TypeScript |
| 배포 | dmg + Homebrew, 서명 없음 | 같음 (D-11) |

iOS는 고려하지 않는다(D-03). 다만 `ModoitCore`에는 AppKit을 넣지 않아 나중에 길을 막지 않는다.

## 3. 구조

```
┌──────────────────────────── Modoit.app (프로세스 하나) ────────────────────────────┐
│  화면 (SwiftUI / AppKit)                                                            │
│   MainWindow    NavigationSplitView: 사이드바 · 메모 목록 · 편집기                   │
│   StickyPanel   NSPanel × N  ─ NativeStickyEditor(NSTextView) 또는 WebEditor        │
│   Settings 씬 · 메뉴 명령 · 종료 처리(AppDelegate)                                   │
│        │ 읽기·명령                          ▲ 변경 알림(@Observable)                 │
│        ▼                                    │                                       │
│  앱 상태 (@MainActor)                                                                │
│   VaultStore     폴더 트리·메모 목록·즐겨찾기, 파일 감시 반영                         │
│   SessionStore   메모 경로 → NoteSession (메모 하나에 세션 하나, 창들이 함께 씀)       │
│   StickyManager  떠 있는 스티키, 편집기 방식 결정, 위치·색 저장                       │
│   Preferences    config.json (v0.x와 같은 파일)                                      │
│        │                                                                            │
│        ▼                                                                            │
│  ModoitCore (Swift 패키지, UI 없음)                                                  │
│   Paths · Title · Frontmatter · Vault · Layout · Merge · Classify · Config          │
│        │ 파일 입출력은 메인 스레드 밖(actor)                                          │
└────────┼────────────────────────────────────────────────────────────────────────────┘
         ▼
   저장 폴더 (.md, attachments/, .modoit/layout.json)        WKWebView ─ editor.html(TipTap)
```

### 3.1 ModoitCore — 어디서 옮기나
규칙을 한곳에서만 계산한다(Brief 3.1-7). 기존 테스트를 **같은 이름으로** 옮겨 명세로 삼는다.

| 모듈 | 하는 일 | 옮겨 오는 곳 | 옮길 테스트 |
|---|---|---|---|
| Paths | 저장 폴더 밖 접근 차단 | `vault.rs` resolve | cargo |
| Title | 제목 ↔ 파일 이름, 중복·대소문자·NFD | `vault.rs` | cargo |
| Frontmatter | `pinned`·`sticky` 읽기, 쓴 키만 고치기(BUG-34 서식 보존) | `frontmatter.ts`, `vault.rs` | vitest `logic.test.ts`, cargo |
| Vault | 트리·목록, 원자적 쓰기(생성일 유지), 휴지통, 이동 + 링크 재작성, 첨부 저장 | `vault.rs` | cargo |
| Layout | `.modoit/layout.json` | `layout.rs`, `sidebar.ts` | cargo, vitest |
| Merge | 줄 단위 3-way 병합, 충돌은 양쪽 보존 | `merge.ts`(node-diff3) | vitest `v03Session.test.ts` |
| Classify | 스티키 편집기 방식 판정(허용 목록). 읽기 전용 판정(FR-43)은 옮기지 않는다: TipTap이 실제로 열어 보고 정하므로 편집기 쪽(`markdownSafety.ts`, `editability.ts`)에 그대로 둔다 | 새로 작성 | 새로 작성 |
| StickyMarkup | 네이티브 스티키의 줄 해석, 체크박스 한 글자 바꾸기 | 새로 작성 | 새로 작성 |
| Config | `config.json` 읽기·쓰기, 범위 밖 값 보정 | `config.rs`, `prefs.ts` | cargo |

- 옮긴 수는 cargo 45개 + 순수 로직 vitest다. 스파이크에서 13개를 이미 옮겨 통과했다.
- 주의: Swift는 `\r\n`을 글자 하나로 세고, `==`는 한글의 NFC와 NFD를 같다고 본다. 그래서 코어의 글자 처리는 유니코드 스칼라와 UTF-8 바이트 단위로 한다(`Text.swift`).
- 주의: 파일 이름의 바이트를 보존한다 → V2-13.
- TipTap 편집기 자체의 테스트(`src/editor/editor.test.ts`, `src/qa/*Editor*`)는 옮기지 않는다. 편집기 코드가 그대로이므로 vitest로 계속 돌린다.

### 3.2 편집 세션 — 한 메모에 하나 (V2-09)
```
 MainWindow의 WebEditor ─┐
                         ├─▶ NoteSession(메모 A) ──0.5초 뒤──▶ 원자적 쓰기 ──▶ A.md
 StickyPanel의 편집기 ───┘        ▲
                                  └── 파일 감시: 다른 앱이 A.md를 바꿈 → 3-way 병합
```
- `NoteSession`(`ModoitKit`)은 본문(Markdown 문자열), 디스크와 같다고 알던 본문(base), 저장 상태를 가진다.
- 메인 창과 스티키가 같은 메모를 열면 **같은 세션**에 붙는다. 한쪽이 고치면 세션이 다른 쪽에 바로 알린다. 파일을 거치지 않는다.
- 3-way 병합은 이제 두 경우에만 쓴다: 다른 앱이 파일을 바꿨을 때, 그리고 TipTap이 보낸 본문에 그 사이 네이티브 쪽 입력이 빠져 있을 때.
- 한글 조합 중인 편집기에는 조합이 끝난 뒤 반영한다(NFR-20, F-07 R-4).
- 저장 규칙(0.5초, 즉시 저장 시점, 3초 재시도, 사라진 파일 다시 만들기)은 [Brief 3.2](../product/brief.md)와 [F-07](../product/features/F-07-save-sync.md) 그대로다.

### 3.3 네이티브 스티키 편집기 (V2-10)
> **2026-11-11 변경(D-25):** 스티키는 보기 전용이 됐다. 아래에서 입력에 관한 항목(단축 입력, 한글 조합, 편집 규칙)은 쓰지 않는다. "원문 그대로 + 화면만 꾸밈"과 체크박스 한 글자 바꾸기, 방식 판정은 그대로다. TipTap 스티키의 체크도 편집기가 문서를 다시 쓰지 않고 Swift가 원문의 그 줄만 바꾼다.

- 저장하는 글자 = 화면의 글자다. `NSTextView`의 내용이 곧 Markdown 원문이고, 서식 기호(`- [ ] `, `**`, `# `)는 **숨기거나 그림으로 바꿔 보이게만** 한다.
- 그래서 "고친 줄만 다시 쓴다"(F-08 R-9, NFR-21)가 구조에서 저절로 지켜진다. 고치지 않은 줄은 한 글자도 바뀌지 않는다.
- 체크박스는 누를 수 있는 그림으로 그리고, 누르면 원문의 `[ ]` ↔ `[x]` 한 글자만 바꾼다.
- 단축 입력(`- `, `[] `, `# ` 등)은 메인 편집기와 **같은 Markdown 결과**를 내야 한다(F-06 R-1). 비교 테스트를 만든다(F-08 A6).
- 한글 조합은 NSTextView가 처리한다. 꾸미기(스타일 갱신)는 조합 중인 범위를 건드리지 않는다.
- 편집기 방식 판정은 `ModoitCore.Classify`가 원문만 보고 한다. 웹 화면을 띄우지 않고 정한다. **허용 목록 방식**이다: 네이티브가 다룰 수 있다고 확인한 줄 모양만 통과시키고, 조금이라도 다르면 TipTap으로 연다.
- 줄 해석과 편집 규칙(Enter, 체크, 들여쓰기, 단축 입력)은 `ModoitCore.StickyMarkup`에 UI 없이 둔다. 화면 코드는 그 결과를 `NSTextView`에 입히기만 한다.
- **2차 스파이크로 확인했다(2026-11-10, [결과](../../spike/sticky-editor/README.md)).** 꾸밈, 편집 규칙, 바이트 보존, 한글 조합 재현이 되고, 메모리는 스티키 1개당 약 2.2 MB다. 구현 때 지킬 것 두 가지:
  - 꾸밈은 편집이 끝난 뒤에 입힌다(편집 처리 도중에 속성을 바꾸면 커서가 튄다).
  - 조합 중에는 본문을 바꾸지 않는다. 다른 쪽의 변경은 조합이 끝난 뒤 병합해 반영한다.
- 실제 한글 입력기로 치는 확인은 수동이다([manual-checks](../qa/manual-checks.md) SP-03).

### 3.4 TipTap 편집기 브리지
- `src/editor/*`는 고치지 않는다. Vite 진입점을 하나 더 두어 편집기만 번들한다(스파이크 `spike/editor-host`를 제품 코드로 옮긴다).
- Tauri에 기대던 두 곳만 바꿔 끼운다.
  - 이미지 주소 → `modoit-file://`. Swift의 `WKURLSchemeHandler`가 저장 폴더 안 파일만 내준다(검증은 `ModoitCore.Paths`).
  - 첨부 저장 → `window.webkit.messageHandlers.modoit`로 보내고 응답을 받는다.
- 외부 주소는 불러오지 않는다(Brief 3.5-3). 번들·글꼴·이미지 모두 앱 안에서 준다.

| 방향 | 이름 | 내용 |
|---|---|---|
| Swift → JS | `load` | `{ markdown, notePath, vault, compact, readOnly, theme, accent, font }` |
| Swift → JS | `update` | `{ markdown }` 세션 본문이 다른 쪽에서 바뀜. 조합 중이면 편집기가 미뤘다가 반영 |
| JS → Swift | `ready` | `{ unsupported: [서식 이름] }` 편집기 준비 완료(NFR-18 측정 기준). 지원하지 않는 서식이 있으면 읽기 전용 안내를 띄운다(FR-43) |
| JS → Swift | `change` | `{ markdown, base }` 사용자 변경만. `base`는 편집기가 마지막으로 받은 본문 |
| JS → Swift | `saveAttachment` | `{ id, notePath, fileName, dataBase64 }` → `{ id, result \| error }` |

### 3.5 그 밖의 흐름
| 흐름 | 방법 | 근거 |
|---|---|---|
| 종료 전 저장 | `applicationShouldTerminate`에서 모든 세션을 저장한 뒤 답한다. 저장 실패가 있으면 한 번 멈춘다. 한 프로세스라 창 사이 신호가 필요 없다 | F-12, v0.4 `quit.rs` |
| 마지막 선택·창 위치 | SwiftUI 장면 상태. 메모 파일에 쓰지 않는다 | F-02 FR-53, Brief 3.1-3 |
| 파일 감시 | FSEvents → `VaultStore` 갱신 → 열린 세션에 알림. 앱이 방금 쓴 변경은 본문이 같으면 무시 | F-07 4.2 |
| 스티키 복원 | 시작할 때 `sticky.open`인 메모를 띄운다. 화면 밖이면 기본 위치 | F-08 R-8 |
| 설정 | `config.json`을 v0.x와 같은 위치·형식으로 읽고 쓴다 | F-10 R-3 |
| 모양(라이트·다크·강조 색) | SwiftUI 환경값 + 편집기에는 `load`로 전달 | F-10 |

## 4. 저장소 구성 (V2-07)
```
macos/                     ← v2 제품 코드 (새로 만듦)
  Package.swift            ModoitCore + ModoitKit(라이브러리) + Modoit(앱) + 테스트
  Sources/ModoitCore/      파일·규칙. Foundation만 쓴다
  Sources/ModoitKit/       화면 없는 앱 로직: 편집 세션, 저장, 스티키 관리
  Sources/Modoit/          화면(SwiftUI·AppKit), 편집기 2종, Resources/editor(빌드 산출물)
  Tests/ModoitCoreTests/   옮긴 cargo·vitest 케이스
  Tests/ModoitKitTests/    세션·스티키 관리 테스트(임시 폴더에 실제 파일)
  editor-host/             TipTap 번들 진입점 (src/editor를 가져다 씀)
  build-app.sh             .app 만들기 (기본은 개발판 `io.github.reentakim.modoit.dev`, `release`를 주면 정식 앱 ID)
src/editor/                TipTap 편집기 (v0.x와 v2가 함께 씀)
src/, src-tauri/           v0.x 앱. v2.0 출시 때까지 유지, 출시 뒤 편집기만 남기고 정리
spike/                     스파이크. 측정 스크립트는 M8에서 다시 씀
```

## 5. 설계 결정 (ADR)
v0.x의 ADR 번호와 겹치지 않게 `V2-`를 붙인다.

### 5.1 정해진 것
| # | 결정 | 이유 |
|---|---|---|
| V2-01 | 앱 셸은 SwiftUI | macOS 기본 컨트롤과 새 디자인을 그대로 따른다(P-3) |
| V2-02 | 코어 로직은 Rust를 Swift로 옮긴다(Rust를 감싸 쓰지 않음) | 1인 프로젝트에서 빌드 체인 하나가 유지하기 쉽다. 기존 테스트가 명세다 |
| V2-03 | 메인 편집기는 기존 TipTap을 WKWebView로 | 표·토글·`/` 메뉴·원문 보존을 갖춘 네이티브 Markdown 편집기가 없다. 다시 만들면 수개월(백로그 B-01) |
| V2-04 | 스티키는 네이티브 편집기, 어려운 서식만 TipTap | 메모리 이득은 네이티브에서만 난다(스파이크: 1개당 5 MB vs 75~100 MB). D-04, D-12 |
| V2-05 | NSPanel은 공개 API만 | NFR-19 |
| V2-06 | 저장 형식·폴더 구조·frontmatter·layout.json·config.json은 v0.x와 같다 | Brief 3.6. 변환 없이 이어 쓰고, 되돌아갈 수도 있다 |
| V2-14 | 세션 저장은 메인 스레드에서 한 번에 끝낸다(동기). 폴더 전체 목록 읽기만 백그라운드로 보낸다 (2026-11-10) | 메모 파일은 작아 저장이 수 ms다. 저장 도중에 입력이 끼어드는 경합(v0.x BUG-39)이 구조적으로 생기지 않고, 종료 전 저장(F-12)도 기다림 없이 끝난다 |
| V2-13 | 코어는 경로를 `String`으로 다루고, 파일·폴더를 만들거나 이름을 바꿀 때는 POSIX 호출(`open`, `mkdir`, `rename`)을 쓴다. `URL`·`FileManager`의 만들기 API를 쓰지 않는다 (2026-11-10, M5에서 발견) | Foundation의 만들기 API는 한글 이름을 자모로 풀어(NFD) 디스크에 만든다. v0.x(Rust)는 받은 글자 그대로(NFC) 만들고 바이트로 비교한다. 섞이면 `layout.json`의 폴더 순서가 v0.x에서 맞지 않는다(NFR-16). 테스트 `created_names_keep_nfc_bytes` |

### 5.2 2026-11-10에 정한 것 (D-23)
| # | 결정 | 이유 | 다른 선택지와 버린 이유 |
|---|---|---|---|
| V2-07 | `macos/`에 Swift 패키지 하나. Xcode 프로젝트 파일 없이 `build-app.sh`로 .app을 만든다 | 스파이크가 이 방식으로 이미 빌드·측정까지 됐다. 프로젝트 파일은 사람이 읽기 어렵고 AI가 고치다 깨뜨리기 쉽다. 명령 한 줄로 빌드·테스트된다 | Xcode 프로젝트: 화면 미리보기와 디버거가 편하지만 지금은 필요가 작다. 나중에 필요하면 패키지를 Xcode로 그대로 열 수 있다 |
| V2-08 | 앱 ID `io.github.reentakim.modoit`를 그대로 쓴다. v2는 v0.x를 그 자리에서 대체한다 | `brew upgrade`만으로 넘어간다. 설정과 저장 폴더가 그대로 이어진다(US-6). 두 앱이 동시에 깔려 헷갈리는 일이 없다(Brief 3.6-4) | 새 앱 ID로 나란히 설치: 비교해 보기는 좋지만 설정을 옮겨야 하고 스티키가 두 벌 뜬다 |
| V2-09 | 한 프로세스. 메모마다 `NoteSession` 하나를 메인 창과 스티키가 함께 쓴다 | v0.x에서 가장 결함이 많았던 "두 창 사이 병합"이 대부분 사라진다. 한쪽 입력이 파일을 거치지 않고 바로 다른 쪽에 보인다(FR-30의 1초 기준을 여유 있게 지킴) | v0.x처럼 창마다 세션 + 파일로 병합: 이미 겪은 결함 종류를 그대로 가져온다 |
| V2-10 | 네이티브 스티키 편집기는 "원문 그대로 + 화면만 꾸밈"(NSTextView, TextKit 2) | 고치지 않은 줄이 바뀌지 않는 것이 구조로 보장된다(NFR-21). 변환기(Markdown ↔ 서식 문서)를 따로 만들지 않아 메인 편집기와 결과가 어긋날 곳이 적다 | 서식 문서로 바꿔 편집한 뒤 Markdown으로 되쓰기: 일반 워드프로세서 방식. 되쓸 때 원문 표기가 바뀌어 NFR-21을 지키기 어렵다 |
| V2-11 | M5(코어 이전)와 함께 **네이티브 스티키 편집기 2차 스파이크**를 한다. 그 결과까지 보고 전체 일정을 추정한다 | 3.3은 아직 시험하지 않은 가장 큰 위험이다. 늦게(M7) 알면 일정 전체가 흔들린다. 안 되면 범위를 줄이는 선택(예: 스티키는 체크리스트·문단만 꾸밈)을 일찍 할 수 있다 | M7에서 바로 구현: 추정(D-14)의 근거가 없고, 실패하면 되돌릴 시간이 없다 |
| V2-12 | 외부 Swift 라이브러리는 YAML 읽기용 [Yams](https://github.com/jpsim/Yams)(MIT) 하나만. Markdown 판정과 3-way 병합은 직접 작성 | frontmatter는 사용자가 쓴 YAML이라 제대로 된 파서가 필요하다(스파이크는 근사로 처리했다). 쓰기는 파서를 거치지 않고 우리 키가 있는 줄만 고쳐 서식을 보존한다(BUG-34). 판정은 줄 단위 검사로 충분하고, 병합은 20줄짜리 규칙이다 | Markdown 파서 라이브러리 추가: TipTap과 해석이 달라질 수 있어 판정 기준이 둘이 된다 |

## 6. 검증 방법
| 대상 | 방법 |
|---|---|
| 코어 규칙 | `swift test --package-path macos` — cargo·vitest에서 옮긴 케이스. 이름에 요구사항·결함 ID 유지. 병합은 v0.x 코드가 낸 결과 400건과 대조(`Fixtures/merge-v0x.json`) |
| 세션·스티키 관리 | 화면 없이 `ModoitTests`에서(가짜 파일 시스템이 아니라 임시 폴더) |
| TipTap 편집기 | 기존 vitest 그대로 |
| 두 편집기의 결과 일치 | 같은 입력 → 네이티브와 TipTap의 Markdown 비교(F-08 A6), 번갈아 고친 뒤 바이트 비교(NFR-21) |
| v0.x 호환 | v0.3 QA 데이터 폴더를 v2로 열고 저장한 뒤 v0.4로 다시 열기(NFR-16) |
| 메모리·실행 시간 | 메모리는 `macos/bench.sh`(임시 저장 폴더 사용), 결과는 8장. 실행 시간은 아직 재지 않았다 |
| 앱 전체(화면 → 편집기 → 파일) | `macos/build-app.sh` 뒤 `open -n -W macos/build/Modoit.app --args --config-dir <임시> --vault <임시 폴더> --selftest 1 --log <파일>`. 실제 앱에서 메모를 고르고 편집기에 글자를 넣어 파일에 저장되는지 본다. 개발판은 앱 ID가 `.dev`라 정식판의 설정을 건드리지 않는다 |
| 화면·한글 입력·종료 | 수동 확인([manual-checks](../qa/manual-checks.md)) |

## 7. 스파이크 결과 요약 (2026-11-09)
| 스티키 10개 | v0.3 | v2 웹 스티키 | v2 네이티브 스티키 |
|---|---|---|---|
| 메모리 합계 | 1,391 MB | 906~1,134 MB | 152~202 MB |
| 스티키 1개당 | 약 120 MB | 약 75~100 MB | 약 5 MB |
| 준비 시간 | 재지 못함 | 804 ms | 509 ms |

- 확인한 것: 메모리 이득은 네이티브 스티키에서만 난다. TipTap이 WKWebView에서 v0.3처럼 그려지고, 열기만 해서는 파일을 쓰지 않는다. 코어 테스트 13개가 Swift에서 통과한다.
- 확인하지 못한 것: 입력 뒤 저장되는 Markdown이 v0.3과 같은지(수동 확인 SP-01), 한글 입력(SP-02).
- 꾸밈이 있는 네이티브 편집기는 2차 스파이크로 확인했다(3.3).

## 8. 실제 앱 메모리 측정 (2026-11-12, NFR-17)
`macos/bench.sh`로 개발판(debug 빌드)을 쟀다. 합계는 앱 프로세스와 실행 뒤 새로 생긴 WebKit 프로세스의 합이다.

| 상태 | 앱 | WebKit | 합계 | 목표(NFR-17) | 판정 |
|---|---|---|---|---|---|
| 메인 창만(스티키 0개) | 51.6 MB | 87.2 MB | 138.8 MB | 176 MB 이하 | 충족 |
| 네이티브 스티키 5개 | 61.6 MB | 86.7 MB | 148.3 MB | | |
| 네이티브 스티키 10개 | 70.9 MB | 81.6 MB | 152.5 MB | 300 MB 이하 | 충족 |
| TipTap 스티키 10개(표가 든 메모) | 64.2 MB | 896.0 MB | 960.2 MB | 대상 아님 | Brief R-6 |

- 네이티브 스티키 1개당 약 1.4~2 MB다(목표 20 MB 이하).
- TipTap 스티키는 1개당 약 82 MB다. 표·토글·코드 블록·이미지가 든 메모를 많이 꺼내면 목표를 넘는다(Brief R-6, H-2로 실제 비율을 확인한다).
- 남은 것: 배포판(release) 빌드로 다시 재기, 실행 시간(NFR-18) 측정.

