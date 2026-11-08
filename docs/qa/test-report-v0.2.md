# QA 테스트 결과 보고 — Modoit v0.2

| 항목 | 내용 |
|---|---|
| 문서 | 테스트 결과 보고서 (Test Report) |
| 버전 | v0.2 |
| 작성 | QA |
| 실행일 | 2026-11-07 |
| 계획서 | [test-plan-v0.2.md](test-plan-v0.2.md) |
| 검증 대상 | `Modoit/` 작업 트리. 앱 소스 최종 수정 17:26:51(이후 변경 없음 확인) |

## 1. 요약

| 구분 | 결과 |
|---|---|
| 기존 자동 테스트 | vitest 33/33, cargo 44/44 통과, tsc 오류 0 |
| QA 회귀 테스트(`src/qa/`, 이번에 추가) | 93개 = 통과 70 + 예상 실패 23(재현된 결함) |
| 전체 `npx vitest run` | 파일 7개, 126개 = 통과 103 + 예상 실패 23. 실패 0 |
| Rust 하네스(`scratchpad/qa-v02/rs`) | QA 테스트 6개 + `vault.rs`·`layout.rs` 자체 테스트 37개, 모두 실행 |
| 테스트 케이스 | 68건 = 통과 41 / 실패 14 / 수동 확인 필요 13 |
| v0.1 결함 22건 | 고침 18 / 부분 4(BUG-01, 04, 10, 22) / 안 고침 0 |
| 새 결함 | 15건(BUG-23~37) = 치명 0 / 높음 0 / 보통 8 / 낮음 7. 이 중 1건(BUG-35)은 "의심" |

**"열기만 해도 파일이 다시 쓰이는 문제"**: 요청받은 여섯 경우 모두 쓰기 명령이 **0건**이었습니다. 실제 TipTap 편집기에서 끝 빈 문단이 붙는 경로를 지나는 것까지 확인했습니다(5장). 이 수정은 충분하다고 판단합니다.

**한 줄 판단**: v0.1의 높음 2건(BUG-01, BUG-02)은 원래 재현 시나리오로는 더 이상 재현되지 않습니다. 높음 이상의 새 결함은 없습니다. 다만 "보통" 중 4건은 조용한 데이터 손실·훼손입니다(BUG-24, 26, 29, 23). 또 1건은 자주 쓰는 흐름(⌘N → 제목 → ⌘⇧S)을 막습니다(BUG-28).
- 제작자 본인의 내부 사용: 가능
- 외부 공개: 이 5건을 고친 뒤를 권고(11장)

## 2. 실행 환경
- macOS 26.6.2 (25G83), APFS(대소문자 구분 없음)
- Node v24.18.0, vitest 5.1.0 + jsdom 31.0.0, rustc 1.99.1
- Tauri 2.12.5, tao 0.37.2, TipTap 3.33.0, React 19
- 다음은 건드리지 않았습니다
  - 실행 중인 dev 앱, `config.json`, `scratchpad/test-vault`
  - 앱 소스(`src/` 중 `qa/` 밖, `src-tauri/`), 설정 파일, `package.json`
- 파일 시스템 테스트는 매번 새 임시 폴더에서 했습니다.

## 3. 검증 방법
1. **기존 자동 테스트**(A): 세 명령을 실행하고 결과를 원문 그대로 기록했습니다.
2. **시뮬레이션**(S, `src/qa/`)
   - 실제 `App`, `EditorPane`, `StickyApp`, `ModoitEditor`(TipTap 3)를 jsdom에서 띄웁니다.
   - `@tauri-apps/api`를 `vi.mock`으로 가짜 백엔드(`src/qa/fakeBackend.ts`)에 붙였습니다.
   - 가짜 백엔드가 흉내 내는 것: IPC 2ms, 감시기 250ms 묶음, `entry-moved`, `set_prefs` 정규화, 실패 주입
   - v0.1과 달리 **편집기를 가짜로 바꾸지 않았습니다**. 열기만으로 쓰는지는 실제 편집기 트랜잭션으로만 검증할 수 있기 때문입니다.
3. **Rust 하네스**(R)
   - `#[path]`로 `vault.rs`, `layout.rs`를 수정 없이 불러옵니다.
   - 실제 임시 폴더에서 이름 바꾸기, 이동, 링크 재작성, 첨부, layout을 돌렸습니다.
4. **교차 검증**(X)
   - 같은 입력을 Rust와 TS에 넣어 비교했습니다.
     - frontmatter 판정: 60개 입력
     - Rust가 재작성한 링크: TS `assetUrl`로 풀어 **실제 파일이 있는지** 확인
   - Markdown 왕복: 말뭉치 120여 개를 실제 편집기로 왕복하고, 다시 읽은 문서 구조(JSON)를 비교했습니다.
5. **정적 추적**(T): 명령·인자·이벤트 계약, 메뉴, 창 이벤트, 종료 처리를 코드로 따라갔습니다.

> 재현된 결함은 `it.fails`로 두었습니다. 지금은 "예상 실패"로 통과하고, 고치면 실패로 바뀌어 알려 줍니다. 그때 `it`으로 바꾸면 회귀 테스트가 됩니다. 예상 실패 23건은 모두 의도한 단언에서 실패하는지 하나씩 따로 확인했습니다(다른 예외로 실패하는 것이 아님).

## 4. 자동 테스트 결과 (원문)

### 4.1 `npx vitest run` (프로젝트 루트, QA 테스트 포함)
```
 RUN  v5.1.0 ~/hyunyoung/Modoit


 Test Files  7 passed (7)
      Tests  103 passed | 23 expected fail (126)
   Start at  18:31:32
   Duration  39.18s (tests 90%, import 8%, environment 2%)
```
QA 테스트를 넣기 전 기준선(17:46)
```
 Test Files  2 passed (2)
      Tests  33 passed (33)
   Start at  17:46:50
   Duration  1.42s (import 69%, environment 19%, tests 10%, transform 1%)
```

### 4.2 `npx tsc --noEmit`
출력 없음, 종료 코드 0. QA 테스트 파일도 `src/` 안에 있으므로 함께 검사됩니다.

### 4.3 `source ~/.cargo/env && cargo test --lib` (src-tauri)
```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.34s
     Running unittests src/lib.rs (target/debug/deps/modoit_lib-a954005e7b6c91b2)

running 44 tests
test sticky::tests::offscreen_positions_are_rejected ... ok
test config::tests::partial_prefs_from_frontend ... ok
test config::tests::v01_config_keeps_vault ... ok
test layout::tests::rename_updates_keys_and_parent_order ... ok
test vault::tests::file_name_truncates_then_trims ... ok
test vault::tests::file_name_rules ... ok
test sticky::tests::entry_moved_updates_paths ... ok
test config::tests::defaults ... ok
test config::tests::broken_prefs_do_not_lose_vault ... ok
test layout::tests::remove_drops_keys_and_name ... ok
test vault::tests::folder_name_rejects_dots_and_empty ... ok
test layout::tests::move_to_other_parent_updates_both_lists ... ok
test layout::tests::update_does_not_create_file_without_change ... ok
test layout::tests::save_and_load_roundtrip ... ok
test vault::tests::rejects_escaping_paths ... ok
test vault::tests::atomic_write_replaces_and_leaves_no_tmp ... ok
test vault::tests::rewrite_links_unit ... ok
test vault::tests::move_to_same_folder_is_noop ... ok
test vault::tests::create_folder_rules ... ok
test vault::tests::title_basic_markdown ... ok
test vault::tests::rejects_symlink_escape ... ok
test layout::tests::missing_or_broken_file_gives_default ... ok
test vault::tests::create_note_makes_default_folder ... ok
test vault::tests::title_bom_and_frontmatter ... ok
test vault::tests::title_checkboxes ... ok
test vault::tests::move_rejects_into_self_or_descendant ... ok
test vault::tests::title_emphasis_and_links ... ok
test vault::tests::title_entities ... ok
test vault::tests::title_skips_fences_and_images ... ok
test vault::tests::title_starting_with_thematic_break ... ok
test vault::tests::sync_note_name_nfd_hangul ... ok
test watcher::tests::internal_paths ... ok
test vault::tests::move_note_name_collision_and_angle_links ... ok
test vault::tests::tree_non_utf8_is_listed_unreadable ... ok
test vault::tests::sync_note_name_case_only_change ... ok
test vault::tests::trash_folder_cleans_layout ... ok
test vault::tests::tree_skips_unreadable_folder ... ok
test vault::tests::sync_note_name_follows_title ... ok
test vault::tests::move_note_rewrites_links_across_depth ... ok
test vault::tests::tree_parses_pinned_and_sticky ... ok
test vault::tests::rename_folder_updates_layout_and_case ... ok
test vault::tests::move_folder_keeps_internal_links ... ok
test vault::tests::tree_nested_and_excludes_attachments_and_hidden ... ok
test vault::tests::save_attachment_checks_and_link ... ok

test result: ok. 44 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.32s
```

### 4.4 QA 회귀 테스트 구성 (`src/qa/`)

| 파일 | 내용 | 통과 | 예상 실패(결함) |
|---|---|---|---|
| `openNoWrite.test.tsx` | 열기·전환·체크박스·외부 변경·이미지 메모에서 쓰기 없음 | 7 | 0 |
| `sticky.test.tsx` | 스티키 열기, BUG-05, FR-44, 빈 메모 정리 | 6 | 2 (BUG-23) |
| `appRace.test.tsx` | BUG-02/04/19, NFR-13, FR-30 동시 편집, 고정·꺼내기, FR-24 | 9 | 5 (BUG-24~28) |
| `logic.test.ts` | frontmatter TS↔Rust, NFR-09, FR-43 왕복, 끝 `&nbsp;` 제거, assetUrl, 사이드바 | 40 | 16 (BUG-29~34) |
| `editorFeatures.test.tsx` | `/` 메뉴(실제 플러그인 경로), 붙여넣기 이미지 | 8 | 0 |
| `fakeBackend.ts`, `harness.tsx` | 가짜 백엔드, 마운트·입력 도구 | — | — |

- 실제 시간 지연을 쓰는 시뮬레이션이라 전체 실행이 약 40초 걸립니다.
- 같은 파일을 두 번 연달아 실행해 결과가 같은 것(안정성)을 확인했습니다.

### 4.5 Rust 하네스 관찰 결과 (QA-R)

| ID | 관찰 | 관련 |
|---|---|---|
| QA-R1 | frontmatter 판정을 TS와 비교: 60개 중 53개 일치, 7개 불일치 | BUG-32 |
| QA-R2 | 메모 이동 3방향 + 폴더 이동 2종 뒤 이미지 60개를 TS `assetUrl`로 풀어 파일 존재 확인. 45개 OK, 15개 실패. 실패는 모두 `#`·`?`가 든 경로였음. 공백·한글·`%`·`(`·`./`·꺾쇠 링크는 모두 정상 | FR-33, BUG-30 |
| QA-R3 | `R&D 회의.md`(엔티티 없음) / `Abc`→`abc.md` / 권한 000 폴더 건너뜀 / `create_note("")`→`메모/새 메모.md` / 트리 정상 / `Stickies`는 일반 폴더, `..`·`.`·공백 거부, 최상위 `attachments`→`attachments 2` / 60자 자른 끝 공백·점 제거 / 제목 추출 9종 계약대로 / 비 UTF-8 `readable=false`, `NOT_UTF8` / v0.1 스티키 형식은 `sticky=None` | BUG-03, 07, 08, 14~19, NFR-08 |
| QA-R4 | 이모지 60자 제목(243바이트 이름)과 " 2" 중복 이름 모두 저장 성공(v0.1 QA-R2 우려 해소) | FR-08 |
| QA-R5 | `사진.PNG` 허용, 확장자 없는 `image`·`a.svg` 거부, 정확히 20MB 허용·20MB+1 거부, 같은 초 300장 이름 겹침 0 | FR-32, NFR-10 |
| QA-R6 | 이름 변경·이동·이름 겹침(" 2")·삭제 때 layout 키와 부모 목록이 맞게 갱신됨. 자기 하위로 이동은 오류 | FR-26~28 |

## 5. 집중 검증: "열기만 해도 파일이 다시 쓰이는가"

**결론: 쓰기 경로 없음(6/6)**

| 경우 | 결과 | 근거 |
|---|---|---|
| 메모 열기 | ✅ 쓰기 0 | 9종(끝 제목, 표, 이미지, 체크박스, HTML, frontmatter, 코드, 인용, CRLF)을 열고 편집기를 누름 |
| 다른 메모로 전환 | ✅ 쓰기 0 | 위 9개 사이를 9회 전환, 저장 지연(0.5초)보다 길게 대기. 파일 내용 스냅숏 동일 |
| 체크박스(읽기 전용) | ✅ 쓰기 0 | TipTap TaskItem이 편집 불가일 때 체크를 되돌리고 트랜잭션을 만들지 않음(`task-item.ts:240`) |
| 체크박스(편집 가능) | ✅ 그 변경만 저장 | 대조군. 쓰기 1회 |
| 스티키 열기 | ✅ 쓰기 0 | 열기 + 편집기 누르기 + 외부 변경 다시 읽기 |
| 외부 변경 후 다시 읽기 | ✅ 쓰기 0 | 메인·스티키 모두 |
| 이미지 메모 열기 | ✅ 쓰기 0 | 화면 주소 `/v/attachments/a.png`, `data-src`는 상대 경로 그대로 |

수정이 충분한 이유
1. TipTap 3.33의 `dispatchTransaction`은 `update` 이벤트에 **원래(root) 트랜잭션**을 넘깁니다(`@tiptap/core/src/Editor.ts` dispatchTransaction).
   - TrailingNode의 끝 문단은 appendTransaction으로 붙습니다. 그래서 선택만 바뀐 root 트랜잭션은 `docChanged=false`이고 저장으로 이어지지 않습니다.
   - 테스트에서 끝 빈 문단이 실제로 붙은 상태(`lastChild = paragraph`)를 확인해, 그 경로를 지났음을 보였습니다.
2. 다음 동작은 문서를 바꾸지 않거나 빈 트랜잭션만 내보내므로 저장되지 않습니다.
   - `setEditable`(읽기 전용 ↔ 그래도 편집)
   - `focus("end")`(autofocus)
   - 이미지 노드 렌더링(resize 꺼짐)
   - 표 확장
3. 세션 쪽 `NoteSession.edit`도 본문이 같고 대기 중인 입력이 없으면 무시합니다.

남는 쓰기(결함 아님)
- 스티키를 옮기거나 크기를 바꾸면 frontmatter에 위치를 씁니다(FR-31 의도).
- 사용자가 실제로 고치면 첫 저장 때 형식이 정규화됩니다(9장 OBS-1, OBS-2).

### 5.1 개발 완료 알림 항목 재검증 (코드 고정 기준)
개발의 "코드 고정" 알림을 받은 뒤 확인했습니다.
- 앱 소스의 최종 수정 시각은 17:26:51입니다. 이 보고서의 모든 자동 테스트와 판정은 이 고정 코드로 실행했습니다.
- 앞서 본 `requestPutBack` 누락은 저장 도중의 중간 상태였고, 고정 코드에는 `src/lib/api.ts`에 있습니다.

| 항목 | 결과 | 근거 |
|---|---|---|
| FR-44 메인 → 스티키 다시 넣기(`sticky-put-back`) | ✅ | S: `sticky.test.tsx`. 입력 중 내용을 먼저 저장한 뒤 `open: false`로 바꾸고 창을 닫음 |
| FR-44 꺼내 둔 메모에서 빼기(remove) | ✅ | S: sticky 키만 지우고 `pinned`는 남김 |
| FR-44 스티키가 없을 때 빼기 | ✅ | T: `open: false`면 메인이 직접 `patchMeta`. 다만 `open: true`인데 창이 없으면 아무 일도 없음 → BUG-36 |
| 빈 메모 정리는 ✕로 닫을 때만 | ✅ | S: 메인 창에서 넣을 때는 정리하지 않음. ✕일 때 정리 범위가 넓은 문제는 BUG-23 |
| (a) 체크박스 `li`에 `data-type="taskItem"` | ✅ | 실제 노드 뷰 출력 `<li data-type="taskItem" data-checked="false">…`, `editor.css:103-131` 선택자와 일치, A: editor.test |
| (b) 문서 끝 빈 문단의 `&nbsp;` 제거 | ✅ | S: `logic.test.ts`. 끝의 빈 문단 3개 → `a`. 중간 빈 줄용 `&nbsp;`는 유지. 사용자가 친 글자 `&nbsp;`(저장 시 `&amp;nbsp;`)는 지우지 않음 |

## 6. v0.1 결함 22건 재검증

| 결함 | v0.1 내용 | 판정 | 근거 |
|---|---|---|---|
| BUG-01 (높음) | 외부 Markdown 훼손 | **부분** | 원래 재현 문서(frontmatter·표·이미지·div)는 frontmatter 분리 보존, 표·이미지 지원, HTML은 읽기 전용(S: logic). 그러나 읽기 전용 판정이 왕복 비교가 아니라서, 꺾쇠 링크·링크 걸린 이미지·``` 를 담은 코드 블록·이름 엔티티는 편집 가능으로 열리고 첫 편집 때 깨짐 → BUG-29 |
| BUG-02 (높음) | 전환 시 선택 되돌아감 | **고침** | S: appRace > BUG-02 A·B. 20~1500ms 모든 시점에 선택·편집기 일치, ⌘N 새 메모 유지 |
| BUG-03 | `&` → `&amp;` | **고침** | 편집기 테스트 + R: `R&D 회의.md`, 제목 `R&D 회의` |
| BUG-04 | 외부 빈 파일 삭제 | **부분** | 메인 창은 고침(이번에 만든 메모만 정리). 스티키 ✕는 여전히 빈 메모를 무조건 휴지통으로 → BUG-23 |
| BUG-05 | 스티키 입력 유실 | **고침** | S: sticky > BUG-05 |
| BUG-06 | 선택 후 Tab 삭제 | **고침** | A: editor.test(문단마다 들여쓰기, Shift+Tab 원위치), 코드 블록 공백 2칸 Shift+Tab 처리 |
| BUG-07 | 읽을 수 없는 폴더 | **고침** | R: 권한 000 폴더만 건너뜀 |
| BUG-08 | "메모" 폴더 없음 | **고침** | R: `create_note("")` → `메모/새 메모.md` |
| BUG-09 | 저장 폴더 변경 시 스티키 잔존 | **고침** | T: `set_vault`가 `sticky::close_all` 호출(`lib.rs:99`). 다만 닫히는 스티키의 0.5초 안 입력은 저장 안 됨(OBS-7). GUI 확인 필요 |
| BUG-10 | ⌘Q 직전 입력 유실 | **부분** | ⌘Q·메뉴 종료는 `ExitRequested`를 막고 `app-will-quit` 뒤 700ms에 종료(`lib.rs:366-385`). Dock "종료"·로그아웃·시스템 종료는 이 경로를 거치지 않음 → BUG-35(의심) |
| BUG-11 | 메인 창 재열기 불가 | **고침** | T: 닫기 = 숨기기, `RunEvent::Reopen`, 창 메뉴 "메인 창 ⌘0". GUI 확인 필요 |
| BUG-12 | 화면 밖 스티키 | **고침** | A: `offscreen_positions_are_rejected`, T: `bar_visible`. GUI 확인 필요 |
| BUG-13 | 한글 입력 소스 단축키 | **고침** | T: 네이티브 메뉴 가속키로 바뀜, 앱의 keydown 단축키 없음. GUI 확인 필요 |
| BUG-14 | 대소문자만 다른 이름 | **고침** | R: `Abc.md` → `abc.md`(" 2" 없음) |
| BUG-15 | 폴더 정렬 | **고침** | R: 트리 구조로 `회의`가 `업무` 아래 |
| BUG-16 | Stickies·`..` 폴더 | **고침** | R: `Stickies` 일반 폴더, `..`·`.`·공백 거부 |
| BUG-17 | 규칙 불일치 | **고침** | TS 쪽 규칙 제거, Rust 한곳. 60자 자른 끝 공백·점 제거 |
| BUG-18 | 제목 추출 불일치 | **고침** | R: 9종 모두 계약대로 |
| BUG-19 | UTF-8 아닌 파일 | **고침** | R + S: 목록 "지원하지 않는 인코딩", 열면 안내. 목록 제목은 깨진 글자(OBS-8) |
| BUG-20 | Ctrl+N/F 가로챔 | **고침** | T: keydown 단축키 처리 없음(설정 창 Esc만) |
| BUG-21 | CSP·opener | **고침** | T: CSP 설정, opener 플러그인·권한 없음 |
| BUG-22 | 저장 실패 무시 | **부분** | 알림과 3초 재시도는 동작(S: NFR-13). 실패 중 다른 메모로 넘어가면 입력이 조용히 사라짐(BUG-24). 이름 맞추기만 실패하면 알림이 안 지워짐(BUG-25) |

## 7. 케이스별 결과

✅ 통과 · ❌ 실패 · ⏸ 수동 확인 필요(8장)

| TC | 요구 | 결과 | 비고 |
|---|---|---|---|
| TC-101 | FR-23 | ⏸ | CSS 값은 일치(본문 17, 첫 줄 17+9, 목록 15/14, 스티키 −1). 화면 확인 필요 |
| TC-102 | FR-24 | ⏸ | |
| TC-103 | FR-24 | ❌ | BUG-27 |
| TC-104 | FR-24 | ✅ | `config.rs` normalized, A |
| TC-105 | FR-24 | ⏸ | T: 스티키도 `prefs-changed`로 적용 |
| TC-106 | FR-25 | ⏸ | |
| TC-107 | FR-26 | ✅ | QA-R3 |
| TC-108 | FR-26 | ✅ | QA-R3 |
| TC-109 | FR-27 | ✅ | QA-R6, S. 끌기 동작 자체는 ⏸ |
| TC-110 | FR-27, 28 | ✅ | QA-R6 |
| TC-111 | FR-28 | ✅ | S: logic |
| TC-112 | FR-28 | ❌ | BUG-33 |
| TC-113 | FR-29 | ✅ | S, A |
| TC-114 | FR-30 | ⏸ | |
| TC-115 | FR-30 | ✅ | S: 1초 안 반영 |
| TC-116 | FR-30 | ❌ | BUG-26 |
| TC-117 | FR-30, 44 | ❌ | BUG-28 |
| TC-118 | FR-31 | ✅ | S: open:false 저장. 위치 복원은 ⏸ |
| TC-119 | FR-31 | ❌ | BUG-23 |
| TC-120 | FR-32 | ✅ | 붙여넣기 S. 끌어 놓기·`/이미지` 파일 선택은 ⏸ |
| TC-121 | FR-32, NFR-10 | ✅ | S, QA-R5 |
| TC-122 | NFR-10 | ✅ | QA-R5 |
| TC-123 | FR-33 | ✅ | QA-R2: 일반 경로 45/45 |
| TC-124 | FR-33 | ❌ | BUG-30 |
| TC-125 | FR-34 | ✅ | S: 11개, 한글 거르기, ↓/Enter, Esc, 공백 뒤만, 코드 블록 금지 |
| TC-126 | FR-35 | ✅ | S: 입력 직후 고정해도 본문 보존 |
| TC-127 | FR-36 | ✅ | QA-R2. 끌기는 ⏸ |
| TC-128 | FR-37 | ⏸ | |
| TC-129 | FR-38 | ⏸ | T: 지금 폴더(모든 메모면 `메모/`)에 생성 후 열기 |
| TC-130 | FR-39 | ⏸ | T: 고정 그룹 맨 위 |
| TC-131 | FR-40 | ⏸ | T: non-activating, all spaces, full screen auxiliary |
| TC-132 | FR-41 | ⏸ | T: 메뉴 구성이 디자인 9장과 일치 |
| TC-133 | FR-42 | ⏸ | T |
| TC-134 | FR-43 | ✅ | S: 배너, 체크박스 무반응, 그래도 편집 |
| TC-135 | FR-43 | ❌ | BUG-29 |
| TC-136 | FR-44 | ✅ | S: 입력 먼저 저장 후 open:false, 빼기 시 sticky 키만 삭제 |
| TC-137 | FR-44 | ❌ | BUG-36 |
| TC-138 | NFR-08 | ✅ | QA-R3, A |
| TC-139 | NFR-09 | ✅ | S, A |
| TC-140 | NFR-09 | ❌ | BUG-34 |
| TC-141 | NFR-09 | ❌ | BUG-32(60개 중 7개 불일치) |
| TC-142 | NFR-09 | ❌ | BUG-31 |
| TC-143 | NFR-11 | ✅ | T: 설정 "정보"와 `THIRD_PARTY_NOTICES.md` |
| TC-144 | NFR-12 | ✅ | T: `cfg(windows)`·Windows 글꼴 없음 |
| TC-145 | NFR-13 | ✅ | S |
| TC-146 | NFR-13 | ❌ | BUG-24 |
| TC-147 | NFR-13 | ❌ | BUG-25 |
| TC-148 | NFR-13 | ⏸ | T: ⌘Q 경로 구현됨 |
| TC-149 | NFR-13 | ⏸ | BUG-35(의심) 확인용 |
| TC-150 ~ 155 | 통합 중 수정 | ✅ ×6 | 5장 |
| TC-156 | 계약 | ✅ | 명령 20개·인자·결과·이벤트 일치. 문서 누락은 BUG-37 |
| TC-157 | 계약 | ❌ | BUG-37 |
| TC-158 | BUG-02 | ✅ | |
| TC-159 | BUG-03 | ✅ | |
| TC-160 | BUG-14/17/18 | ✅ | |
| TC-161 | BUG-12 | ✅ | 단위 테스트. 실제 모니터 분리는 ⏸ |
| TC-162 | BUG-04 | ✅ | 메인 창. 스티키는 TC-119 |
| TC-163 | BUG-05 | ✅ | |
| TC-164 | BUG-06 | ✅ | |
| TC-165 | BUG-08 | ✅ | |
| TC-166 | BUG-19 | ✅ | |
| TC-167 | BUG-09 | ✅ | 정적. GUI 확인 권장 |
| TC-168 | BUG-21 | ✅ | |

- 집계: 68건 = ✅ 41 / ❌ 14 / ⏸ 13
- "✅ + 일부 ⏸"인 항목은 ✅로 셌습니다.

## 8. 새 결함 목록

### 8.1 요약

| ID | 심각도 | 확신 | 관련 | 한 줄 요약 | 위치 |
|---|---|---|---|---|---|
| BUG-23 | 보통 | 확인됨 | FR-31, BUG-04 | 스티키 ✕는 내용이 비었으면 원래 있던 메모도 휴지통으로 보낸다 | `src/sticky/StickyApp.tsx:130-132` |
| BUG-24 | 보통 | 확인됨 | NFR-13, BUG-22 | 저장 실패 중 다른 메모로 넘어가면 재시도가 멈추고 입력이 조용히 사라진다 | `src/app/EditorPane.tsx:71-77`, `src/lib/noteSession.ts:90-93` |
| BUG-25 | 낮음 | 확인됨 | NFR-13 | 본문은 저장됐는데 이름 맞추기만 실패하면 "저장하지 못했습니다" 알림이 계속 남는다 | `src/lib/noteSession.ts:60-76` |
| BUG-26 | 보통 | 확인됨 | FR-30 | 스티키에서 쓰고 1초 안에 메인 창에서 쓰면 스티키의 마지막 입력이 사라진다(반대도 같음) | `src/lib/noteSession.ts:60-66`, `src/app/EditorPane.tsx:95-101` |
| BUG-27 | 보통 | 확인됨 | FR-24 | 직접 입력 글꼴 칸에서 공백이 지워져 "Nanum Gothic"을 칠 수 없다 | `src-tauri/src/config.rs:51`, `src/app/App.tsx:39-42` |
| BUG-28 | 보통 | 확인됨 | FR-30, FR-44, FR-36 | 제목을 고친 뒤 0.5초 안에 ⌘⇧S·꺼내기를 누르면 "No such file" 알림만 뜨고 꺼내지지 않는다 | `src/app/App.tsx:104-111`, `:335-339` |
| BUG-29 | 보통 | 확인됨 | FR-43, BUG-01 | 읽기 전용 판정이 왕복 비교가 아니라서, 편집하면 링크·이미지·코드가 깨지는 문서를 편집 가능으로 연다 | `src/lib/markdownSafety.ts:77-108` |
| BUG-30 | 낮음 | 확인됨 | FR-33 | 경로에 `#`·`?`가 든 이미지(`%23`, `%3F`)가 보이지 않는다 | `src/lib/paths.ts:19-22`, `src-tauri/src/vault.rs:861-862` |
| BUG-31 | 낮음 | 확인됨 | NFR-09 | 편집기에서 쓴 "구분선 / 키: 값 / 구분선"이 다시 열면 frontmatter로 읽혀 본문에서 사라진다 | `src/lib/frontmatter.ts:36-52`, `src-tauri/src/vault.rs:269-302` |
| BUG-32 | 낮음 | 확인됨 | NFR-09, 계약 | frontmatter 판정이 Rust와 7가지 경우에 다르다 | `src/lib/frontmatter.ts:36,46-49` ↔ `vault.rs:275,282,287` |
| BUG-33 | 낮음 | 확인됨 | FR-27, FR-28 | 이름순·최신순에서 폴더를 다른 폴더 안으로 옮기면 정렬 방식이 직접 정렬로 바뀐다 | `src/app/App.tsx:310-320`, `src/lib/sidebar.ts:117-131` |
| BUG-34 | 낮음 | 확인됨 | NFR-09 | 고정·꺼내기 때 사용자가 쓴 YAML 서식이 바뀐다(`[a, b]`→`[ a, b ]`, `0x1F`→`0x1f`) | `src/lib/frontmatter.ts:113-147` |
| BUG-35 | 보통 | 의심 | NFR-13, BUG-10 | Dock "종료"·로그아웃·시스템 종료 때는 남은 입력을 저장하지 않고 끝난다 | `src-tauri/src/lib.rs:265,366-385` |
| BUG-36 | 낮음 | 확인됨(코드) | FR-44 | frontmatter는 open:true인데 스티키 창이 없으면 "다시 넣기"·"빼기"가 아무 일도 하지 않는다 | `src/app/App.tsx:121-137` |
| BUG-37 | 낮음 | 확인됨 | 계약 | 계약서에 `sticky-put-back` 이벤트가 없고, sticky 기본값이 TS(280, open:true)와 Rust(260, open:false)에서 다르다 | `docs/dev/api-v0.2.md` 3장, `src/lib/frontmatter.ts:20-28,74`, `vault.rs:25,318-321` |

### 8.2 상세

#### BUG-23 스티키 ✕가 원래 있던 빈 메모를 휴지통으로 보낸다
- **심각도**: 보통 · **확신**: 확인됨(S: `sticky.test.tsx` BUG-23 ×2) · **관련**: FR-31, PRD 8장 BUG-04 처리 방침("이번 실행에서 앱이 만든 새 메모만 자동 정리")
- **재현 절차 A**
  1. 터미널에서 `touch 메모/할일.md`
  2. 목록 우클릭 → 스티키로 꺼내기
  3. 스티키의 ✕를 누른다
- **재현 절차 B**
  1. 내용이 있는 메모를 스티키로 꺼낸다
  2. 내용을 모두 지운다
  3. ✕를 누른다
- **기대 결과**: 파일이 남고 `open: false`만 기록된다. ⌘⇧N으로 이번에 만든 빈 스티키만 정리한다(메인 창과 같은 규칙)
- **실제 결과**: 두 경우 모두 파일이 휴지통으로 간다. 메인 창의 BUG-04 수정이 스티키에는 적용되지 않았다
- **원인**: `close(byUser)`가 `createdNew`를 보지 않고 `!body.trim()`만 본다. 스티키 세션은 늘 `createdNew=false`로 만든다(`StickyApp.tsx:58`)

#### BUG-24 저장 실패 중 다른 메모로 넘어가면 입력이 사라진다
- **심각도**: 보통 · **확신**: 확인됨(S: `appRace.test.tsx` BUG-24) · **관련**: NFR-13, BUG-22
- **재현 절차**
  1. 메모를 연 채 그 폴더를 `chmod 555`로 바꾼다
  2. 글을 친다. "저장하지 못했습니다" 알림이 뜬다
  3. 다른 메모를 누른다
  4. 권한을 되돌린다
- **기대 결과**: 3초 재시도가 이어져 입력이 저장된다. 적어도 버려진다는 경고가 있다
- **실제 결과**
  - `leave()`가 `await s.flush()`(실패, 재시도 예약) 뒤 곧바로 `s.close()`를 부른다.
  - `close()`가 재시도 타이머를 지우고 레지스트리에서 뺀다.
  - 알림은 새 메모 세션으로 바뀌며 사라지고, 입력은 영영 저장되지 않는다.
  - 같은 구조가 스티키 ✕(`StickyApp.tsx:128-138`)와 저장 폴더 변경에도 있다.
- **근거 코드**: `EditorPane.tsx:71-77`, `noteSession.ts:72-75`(재시도 예약), `noteSession.ts:90-93`(close가 타이머 삭제)

#### BUG-25 이름 맞추기만 실패하면 알림이 지워지지 않는다
- **심각도**: 낮음 · **확신**: 확인됨(S: BUG-25) · **관련**: NFR-13
- **재현 절차**: 본문 쓰기는 되고 이름 바꾸기만 실패하는 상황에서 입력한다
  - 예: 저장 직후 다른 프로그램이 파일을 옮기거나, 이름 변경 권한만 없는 경우
- **기대 결과**: 다음 재시도에서 이름 맞추기가 성공하면 알림이 사라진다
- **실제 결과**
  - 본문 저장이 끝나 `pending=null`이 된 뒤 `syncNoteName`이 실패해 catch로 가면 `failing=true`가 되고 재시도가 예약된다.
  - 재시도는 `pending===null`이라 바로 돌아가므로(`:62`) 이름을 다시 맞추지도, 알림을 지우지도 않는다.
  - 다음 입력이 있을 때까지 "저장하지 못했습니다"가 계속 보인다. 실제로는 저장된 상태라 사용자를 오도한다.
- **근거 코드**: `noteSession.ts:60-76`. 쓰기와 이름 맞추기를 한 try에 묶었다

#### BUG-26 두 창을 번갈아 편집하면 앞 창의 마지막 입력이 사라진다
- **심각도**: 보통 · **확신**: 확인됨(S: BUG-26, 메커니즘 재현) · **관련**: FR-30("같은 파일을 편집", "1초 안에 반영")
- **재현 절차**
  1. 메모를 메인 창과 스티키에 함께 연다
  2. 스티키에서 한 줄을 친다
  3. 1초가 지나기 전에 메인 창을 눌러 글을 친다
- **기대 결과**: 두 입력이 모두 남는다. 적어도 충돌을 알린다
- **실제 결과**
  - 스티키가 0.5초 뒤 저장한다. 메인 창은 감시기 이벤트(+0.25초)를 받기 전에 입력을 시작해 `dirty` 상태가 된다.
  - 메인 창은 다시 읽기를 건너뛰고(`EditorPane.tsx:95-96`), 자기 편집기 본문 전체로 파일을 덮어쓴다.
  - 스티키 입력은 파일과 양쪽 화면에서 모두 사라진다. 스티키도 다시 읽으며 메인 내용을 보여 준다.
  - 알림은 없다. 반대 방향(메인 → 스티키)도 같다.
- **원인**: 저장이 "내가 마지막으로 본 본문(`saved`)과 디스크가 같은지"를 확인하지 않고 본문 전체를 쓴다(`noteSession.ts:60-66`, `api.ts updateNote`)
- **비고**
  - v0.1의 "입력 중에는 내 내용 우선" 정책을 따른 결과입니다. 그러나 v0.2는 같은 메모를 두 창에 띄우는 것이 핵심 기능(FR-30)이라 일상 흐름에서 생깁니다.
  - 최소 조치 제안: 저장 직전 디스크 본문이 `saved`와 다르면 충돌로 보고 3-way 병합하거나 알린다. 또는 창을 바꿀 때(blur) 즉시 flush한다.

#### BUG-27 직접 입력 글꼴에 공백을 칠 수 없다
- **심각도**: 보통 · **확신**: 확인됨(S: BUG-27, 결과 `NanumGothic`) · **관련**: FR-24
- **재현 절차**: ⌘, → 직접 입력 → "Nanum Gothic"을 한 글자씩 친다
- **기대 결과**: 입력 칸에 "Nanum Gothic"
- **실제 결과**
  - 글자마다 `set_prefs`를 부르고, Rust가 `custom_font`를 trim해 `prefs-changed`로 돌려준다.
  - App이 그 값으로 `prefs`를 덮어써(`App.tsx:39-42`), 방금 친 끝 공백이 수 ms 안에 지워진다.
  - 결과는 "NanumGothic"이고 글꼴이 적용되지 않는다. 자리표시자의 예시("Nanum Gothic")조차 칠 수 없다.
  - 붙여넣기로는 입력할 수 있다.
- **근거 코드**: `src-tauri/src/config.rs:51`, `src/app/App.tsx:39-42`, `src/app/Settings.tsx` 직접 입력 칸

#### BUG-28 제목 입력 직후 꺼내기가 실패한다
- **심각도**: 보통 · **확신**: 확인됨(S: BUG-28, 알림 원문 `Error: No such file or directory (os error 2)`) · **관련**: FR-30, FR-44, FR-36
- **재현 절차**
  1. ⌘N
  2. "장보기"를 친다
  3. 0.5초 안에 ⌘⇧S(또는 툴바 꺼내기 버튼)를 누른다
- **기대 결과**: 입력이 저장되고 `장보기.md`가 스티키로 뜬다
- **실제 결과**
  - `popOut(path)`가 `flushAll()`을 기다리는 동안 저장 → 이름 맞추기로 파일이 `장보기.md`로 바뀐다.
  - 그 뒤 옛 경로 `새 메모.md`로 `stickyOf`를 읽다가 실패해 오류 알림만 뜬다.
  - 스티키가 열리지 않고 frontmatter도 붙지 않는다. 사용자는 다시 눌러야 한다.
  - 대조군(0.5초 기다린 뒤)은 정상이다.
- **같은 구조**: `moveNote`(`App.tsx:335-339`)도 `flushAll()` 뒤 옛 경로로 `move_entry`를 부른다. 제목을 고치자마자 메모를 끌어 옮기면 "찾을 수 없습니다"가 뜬다(정적 확인)
- **조치 제안**: flush 뒤 세션의 현재 경로를 다시 얻어 쓴다(`flushAll` 결과로 경로 대응표를 돌려주거나, `applyMove` 뒤 경로를 다시 계산)

#### BUG-29 FR-43 판정이 왕복 비교가 아니라 손상 문서를 편집 가능으로 연다
- **심각도**: 보통 · **확신**: 확인됨(X: 말뭉치 왕복, S: `logic.test.ts` BUG-29 ×5) · **관련**: FR-43("왕복 결과가 원본과 다르면 읽기 전용"), BUG-01
- **재현 절차**: 다른 앱에서 아래 내용의 .md를 만들고 Modoit에서 열어 아무 곳에 한 글자를 친다
- **기대 결과**: 읽기 전용으로 열리거나, 편집해도 의미가 보존된다
- **실제 결과**: 읽기 전용이 아니며, 첫 저장 뒤 다음처럼 바뀐다

  | 원본 | 저장 결과 | 다시 열면 |
  |---|---|---|
  | `![](<my pic.png>)` | `![](my pic.png)` | 이미지가 글자 `![](my pic.png)`로 보임 |
  | `[파일](<my file.md>)` | `[파일](my file.md)` | 링크가 글자로 보임 |
  | `[![](a.png)](https://x.com)` | `![](a.png)` | 링크 주소 사라짐 |
  | ```` ```` ```` 안에 ```` ``` ```` 를 담은 코드 블록 | 코드 블록 경계가 어긋남 | 빈 코드 블록 둘로 깨짐 |
  | `a&nbsp;b &copy; 2026` | `a&amp;nbsp;b &amp;copy; 2026` | 다른 앱에서도 `&nbsp;` 글자로 보임(편집기는 처음부터 글자로 보여 줌) |

- **원인**: `findUnsupported`는 marked 토큰 종류가 허용 목록에 있는지만 본다. 실제 Markdown → 편집기 → Markdown 왕복 결과를 원본과 비교하지 않는다
- **비고**
  - 의미는 같고 **형식만** 바뀌는 경우는 손상으로 세지 않았습니다(OBS-1). 예: `*`→`-`, `__`→`**`, 표 칸 맞춤, CRLF→LF, 끝 줄바꿈 제거.
  - 이것도 FR-43 문구("원본과 다르면")에는 걸리므로, PM이 "의미 보존"을 기준으로 삼을지 정해 주세요.
  - 기준이 "의미 보존"이면, 열 때 왕복 결과를 다시 파싱해 구조(JSON)를 비교하는 방식으로 위 5종을 모두 잡을 수 있습니다(QA 테스트 `roundTripSame` 참고).

#### BUG-30 `#`·`?`가 든 이미지 경로가 보이지 않는다
- **심각도**: 낮음 · **확신**: 확인됨(QA-R2 15/60 실패, S: BUG-30) · **관련**: FR-33, FR-32
- **재현 절차**
  1. 폴더 `C# 공부`에 `z.png`를 두고, 다른 폴더 메모에 `![](../C%23%20공부/z.png)`를 쓴다
     - 메모를 옮기면 Rust가 이 형식으로 링크를 다시 쓴다
  2. 메모를 연다
- **기대 결과**: 이미지가 보인다
- **실제 결과**
  - `assetUrl`의 `decodeURI`는 `%23`(#)과 `%3F`(?)를 풀지 않는다.
  - 그래서 `…/C%23 공부/z.png`라는 없는 파일을 요청해 이미지가 깨진다.
  - 앱이 붙여넣은 이미지(`attachments/날짜-임의값.png`)는 해당 없음
- **근거 코드**: `src/lib/paths.ts:19-22`(`decodeURI`), `src-tauri/src/vault.rs:861-862`(`#`→`%23`, `?`→`%3F`로 씀). `decodeURIComponent`를 경로 조각마다 쓰면 맞는다

#### BUG-31 편집기가 쓴 구분선·"키: 값"·구분선이 frontmatter로 읽힌다
- **심각도**: 낮음 · **확신**: 확인됨(S: BUG-31) · **관련**: NFR-09
- **재현 절차**
  1. 새 메모 첫 줄에서 `---` Enter
  2. "장소: 회의실" 입력
  3. 다시 `---` Enter
  4. "본문" 입력 → 다른 메모로 갔다가 돌아온다
- **기대 결과**: 구분선 두 개와 "장소: 회의실"이 그대로 보인다
- **실제 결과**
  - 저장된 파일은 `---\n\n장소: 회의실\n\n---\n\n본문`이다.
  - 첫 줄이 `---`이고 안쪽이 YAML 매핑이라, TS·Rust 모두 frontmatter로 판정한다.
  - 다시 열면 세 줄이 편집기에서 사라진다(파일에는 남음). 목록 제목도 "본문"이 된다.
  - 이 상태에서 고정을 켜면 사용자가 쓴 줄이 YAML 키로 굳는다.
- **근거 코드**: `frontmatter.ts:36-52`, `vault.rs:269-302`
- **조치 제안**: 직렬화할 때 문서 첫 블록이 구분선이면 `***`로 쓰거나, 빈 줄로 시작하는 `---` 블록은 frontmatter로 보지 않는다

#### BUG-32 frontmatter 판정이 Rust와 다른 경우
- **심각도**: 낮음 · **확신**: 확인됨(QA-R1, X, S: BUG-32 ×6) · **관련**: NFR-09, 계약(`frontmatter.ts` 주석 "Rust와 같은 판정")
- **내용**: 60개 입력 중 7개가 다르다

  | 입력 | Rust | TS |
  |---|---|---|
  | 여는 줄 끝 공백·탭 `--- ` | frontmatter | 본문 |
  | `...`로 닫음 | frontmatter | 본문(구분선 + 문단으로 보여 편집 가능) |
  | `...` 뒤에 `---` | `...`에서 끝 | `---`에서 끝 |
  | 탭 들여쓴 키 `\t탭: 1` | frontmatter(키로 봄) | 본문 |
  | 안쪽이 `null`·`~` | 빈 frontmatter | 본문 |

- **영향**: 목록 제목(Rust)과 편집기 내용(TS)이 다르다. 이 메모를 고정하면 TS가 frontmatter를 하나 더 붙여 이중 frontmatter가 된다
- **근거 코드**: `frontmatter.ts:36`(여는 줄 `---\r?\n` 고정, 닫는 줄 `---`만), `:46-49`(contents가 null일 때만 허용) ↔ `vault.rs:275`(trim_end), `:282`(`...` 허용), `:287`(Null 허용)

#### BUG-33 폴더를 다른 폴더 안으로 옮기면 정렬 방식이 바뀐다
- **심각도**: 낮음 · **확신**: 확인됨(S: BUG-33) · **관련**: FR-27, FR-28
- **재현 절차**: 사이드바 정렬 "이름순" → 폴더 하나를 다른 폴더 **위**에 놓는다
- **기대 결과**: 그 안으로 옮겨지고 정렬은 이름순 그대로
- **실제 결과**
  - `moveFolder`가 이동 뒤 항상 `reorder()`를 부른다.
  - `reorder`는 정렬 모드가 직접 정렬이 아니면 모든 부모의 화면 순서를 고정하고 `sort: "custom"`으로 바꾼다.
  - 정렬 메뉴 체크가 "직접 정렬"로 옮겨지고, 이후 새 폴더는 이름순 자리에 들어가지 않는다.
  - 폴더 **사이**에 놓아 순서를 바꾸는 경우는 의도된 동작이라 결함으로 보지 않았다.
- **근거 코드**: `App.tsx:310-320`, `sidebar.ts:117-131`

#### BUG-34 고정·꺼내기 때 사용자 YAML 서식이 바뀐다
- **심각도**: 낮음 · **확신**: 확인됨(S: BUG-34 ×2) · **관련**: NFR-09("다른 frontmatter 키는 지우거나 바꾸지 않는다")
- **재현 절차**: frontmatter가 `tags: [a, b]`, `num: 0x1F`인 메모를 고정했다가 해제한다
- **기대 결과**: 원래 글자 그대로
- **실제 결과**: `tags: [ a, b ]`, `num: 0x1f`로 바뀐다. 값의 의미는 같다. 주석, 블록 문자열, 따옴표, 날짜, 들여쓴 목록은 보존됐다
- **근거 코드**: `frontmatter.ts:147`(`doc.toString`으로 YAML 전체를 다시 직렬화)

#### BUG-35 Dock "종료"·로그아웃 때 남은 입력을 저장하지 않는다
- **심각도**: 보통 · **확신**: 의심(GUI 확인 필요, 8장 M-13) · **관련**: NFR-13, BUG-10
- **재현 절차**: 메모에 입력하고 0.3초 안에 Dock 아이콘 우클릭 → 종료 → 다시 실행
- **기대 결과**: 마지막 글자까지 남는다
- **의심 근거**
  - 개발 주석(`lib.rs:265`)대로 기본 `terminate:`는 `ExitRequested`를 거치지 않는다. 그래서 앱 메뉴의 종료만 직접 항목으로 바꿨다.
  - Dock "종료"·로그아웃·재시동은 NSApp `terminate:`로 들어온다.
  - tao 0.37.2는 `applicationShouldTerminate:`를 구현하지 않고 `applicationWillTerminate:`만 받는다(`tao/src/platform_impl/macos/app_delegate.rs:62,130`). 따라서 `app-will-quit`이 발생하지 않을 가능성이 높다.
  - 700ms 대기도 고정값이라, 느린 디스크에서는 응답 확인 없이 종료한다.

#### BUG-36 창이 없는 open:true 스티키는 다시 넣거나 뺄 수 없다
- **심각도**: 낮음 · **확신**: 확인됨(코드) · **관련**: FR-44
- **재현 절차**: frontmatter가 `open: true`인데 스티키 창이 떠 있지 않은 메모를 만든다. 우클릭 "다시 넣기" 또는 "꺼내 둔 메모에서 빼기"를 누른다
  - 예: 다른 Mac에서 동기화된 메모, `open_sticky` 실패, 외부 편집
- **기대 결과**: open:false로 바뀌거나 sticky 키가 지워진다
- **실제 결과**
  - `putBack`은 `cur.open`이면 스티키 창에 `sticky-put-back` 이벤트만 보내고 끝난다.
  - 받을 창이 없어 아무 일도 없다. 툴바 토글도 계속 "다시 넣기"를 고른다.
  - 사이드바 행 클릭(꺼내기)으로만 빠져나올 수 있다.
- **근거 코드**: `App.tsx:121-137`

#### BUG-37 계약서 누락·기본값 불일치
- **심각도**: 낮음 · **확신**: 확인됨 · **관련**: API 계약
- **내용**
  1. FR-44 구현에 쓰는 `sticky-put-back` 이벤트(창 → 창, `{path, remove}`)가 `api-v0.2.md` 3장에 없다.
  2. sticky 기본 크기: TS `DEFAULT_STICKY`는 280×280, Rust `STICKY_DEFAULT_SIZE`와 PRD 예시는 260.
  3. `open` 키가 없을 때 TS는 true(`frontmatter.ts:74`), Rust는 false(`vault.rs:321`).
     - 목록 점은 "넣어 둠"으로 보이는데, 툴바·⌘⇧S는 "다시 넣기"로 동작한다(BUG-36과 같은 막힘).
- **근거**: `src/lib/frontmatter.ts:20-28,74`, `src-tauri/src/vault.rs:25,318-321`, 실측(QA-R3 "계약 sticky 기본값")

## 9. 결함이 아닌 관찰
- **OBS-1 첫 편집 때 형식 정규화**
  - 외부 메모는 사용자가 한 글자라도 고치면 전체가 TipTap 형식으로 다시 쓰인다(의미는 보존).
  - 예: `*`→`-`, `1)`→`1.`, `__`→`**`, `~~~`→```` ``` ````, 들여쓴 코드→펜스, 표 칸 맞춤, CRLF→LF, 끝 줄바꿈 제거, `<url>`→`[url](url)`
  - FR-43 문구와의 관계는 BUG-29 비고 참고
- **OBS-2 끝 빈 줄**: 목록·제목·표·코드·이미지로 끝나는 메모는 첫 편집 때 끝에 빈 줄 두 개(`\n\n`)가 붙는다. 한 번만 붙고 쌓이지 않는다(S: 대조군 테스트에 명시)
- **OBS-3 링크 재작성 범위**
  - 인라인 코드 안의 `` `![](…)` ``도 고친다. 펜스 코드는 건너뛴다(`vault.rs:959-987`).
  - 옮겨진 메모를 **가리키는** 다른 메모의 링크는 고치지 않는다(계약 범위 밖, 이미지는 `attachments/`라 영향 없음).
- **OBS-4 외부 이미지**: CSP `img-src`에 https가 없어 `![](https://…)` 이미지는 보이지 않는다. 의도라면 문서화 필요
- **OBS-5 이전 저장 폴더 범위**: `set_vault` 뒤에도 이전 폴더의 에셋 프로토콜 허용 범위가 남는다(`allow_directory`만 하고 해제 없음)
- **OBS-6 스티키 포커스와 메뉴**: 스티키에 입력 중 ⌘⇧S·⌘⇧P를 누르면 그 스티키가 아니라 메인 창에서 선택된 메모에 적용된다(`lib.rs:243-244`, `App.tsx:365-370`). 기대 동작을 디자인에서 정해 주세요
- **OBS-7 저장 폴더 변경**: 닫히는 스티키의 0.5초 안 입력은 저장되지 않는다. `flushAll`은 메인 창 세션만 저장한다(`App.tsx:49`, `lib.rs:99`)
- **OBS-8 비 UTF-8 제목**: 목록 제목이 손실 변환된 깨진 글자(예: `�ȳ�`)로 보인다. 미리보기는 "지원하지 않는 인코딩"
- **OBS-9 외부 메모 이름**: 외부 메모(예: Obsidian `2026-11-07.md`)는 첫 편집 때 파일 이름이 첫 줄 제목으로 바뀐다(v0.1 FR-08 동작). 다른 앱의 위키 링크가 깨질 수 있어 PM 확인을 권한다
- **해소된 우려**: 이모지 60자 제목도 임시 파일 이름까지 포함해 저장된다(QA-R4). `/` 메뉴 Esc는 제안 상태까지 정상 종료된다(TipTap suggestion `props.ts:51`)

## 10. GUI 수동 확인 체크리스트

`npm run tauri dev` 또는 빌드한 앱으로 **새 빈 폴더**를 저장 폴더로 골라 진행해 주세요. 결과는 이 표의 "결과" 칸에 적어 주시면 됩니다.

| # | TC | 절차 | 기대 결과 | 결과 |
|---|---|---|---|---|
| M-1 | TC-101 | 기본 설정에서 본문·첫 줄·목록·사이드바·스티키 글자 크기 확인 | 17 / 26 / 15·14 / 15 / 16px로 v0.1보다 크다 | |
| M-2 | TC-102, 105 | ⌘, → 5가지 글꼴을 차례로 → 스티키 하나 띄운 채 확인 → 앱 재실행 | 메인·스티키에 바로 적용, 재실행 후 유지 | |
| M-3 | TC-103 | 직접 입력에 "Nanum Gothic"을 한 글자씩 | (BUG-27 확인) 공백이 사라지는지 | |
| M-4 | TC-106 | 툴바 버튼과 ⌥⌘S로 사이드바 접기 → 재실행 | 접힌 상태 유지 | |
| M-5 | TC-107~113 | 하위 폴더 만들기, 이름 변경(더블클릭), 폴더를 다른 폴더 위·사이에 끌기, 자기 하위로 끌기, 구분선 추가·끌기·삭제, 정렬 3종 → 재실행 | 동작과 순서가 재실행 후 유지. 하위로는 놓을 수 없음. 안에 메모가 있는 폴더 삭제 시 확인 대화상자 | |
| M-6 | TC-114, 118 | 툴바 버튼·목록 우클릭·⌘⇧S로 꺼내기 → 색 바꾸고 옮기고 크기 조절 → ✕ → 다시 꺼내기 | 같은 자리·크기·색 | |
| M-7 | TC-115, 116 | 스티키에서 입력 → 메인 창에 1초 안 반영. 스티키에 치고 곧바로 메인에서 치기 | (BUG-26 확인) 스티키 입력이 사라지는지 | |
| M-8 | TC-117 | ⌘N → "장보기" → 즉시 ⌘⇧S | (BUG-28 확인) 오류 알림이 뜨는지 | |
| M-9 | TC-131 | Safari를 앞에 두고 스티키를 클릭 → 입력 → 다른 데스크톱·전체 화면 앱으로 이동 | 클릭만으로 Safari가 비활성화되지 않음, 입력은 됨, 모든 Spaces·전체 화면 위에 보임. 스티키에서 ⌘C·⌘V·⌘Z 동작 | |
| M-10 | TC-120 | 스크린샷 ⌘V, Finder에서 png 끌어 놓기, `/이미지`로 파일 선택 | 메모와 스티키 양쪽에 보이고 `attachments/`에 파일 생성 | |
| M-11 | TC-123, 127 | 이미지가 든 메모를 목록에서 다른 폴더로 끌기, 그 폴더를 다른 폴더 안으로 끌기 | 이미지가 계속 보임 | |
| M-12 | TC-132 | 입력 소스를 "한국어 두벌식"으로 두고 한글을 친 직후 ⌘N, ⌘F, ⌘⇧N, ⌘⇧S, ⌥⌘S, ⌘,. 편집기에서 Ctrl+F·Ctrl+N | 메뉴 단축키 모두 동작. Ctrl 조합은 커서 이동 | |
| M-13 | TC-148, 149 | (a) 입력 후 0.2초 안에 ⌘Q (b) 입력 후 Dock 우클릭 → 종료 (c) 스티키에 입력 후 ⌘Q | 재실행 시 마지막 글자까지 남음. (b)는 BUG-35 확인 | |
| M-14 | TC-133 | 스티키를 띄운 채 메인 창 빨간 버튼 → Dock 아이콘 클릭 → ⌘0 | 스티키 유지, 메인 창 다시 보임 | |
| M-15 | TC-161 | 보조 모니터로 스티키를 옮기고 종료 → 모니터 분리 → 재실행 | 보이는 화면 안에 뜸 | |
| M-16 | TC-167 | 스티키를 띄운 채 저장 폴더 변경 | 스티키가 모두 닫히고 새 폴더에 엉뚱한 파일이 생기지 않음 | |
| M-17 | TC-134 | `<div>`가 든 .md를 넣고 열기 → "그래도 편집" | 안내 막대, 읽기 전용, 버튼 후 편집 가능 | |
| M-18 | TC-128, 130, 143 | 아이콘 크기, 목록 이름순·수정일순, 설정 "정보"의 라이선스 | 디자인 2장·5장, NFR-11 | |
| M-19 | TC-136 | 목록 우클릭 "스티키 다시 넣기"·"꺼내 둔 메모에서 빼기", 사이드바 행 마우스 올림 버튼 | 스티키가 닫히고(빼기는 색 점도 사라짐) 입력 중이던 글 보존 | |

## 11. 출시 판단 의견

**권고**
- 제작자 본인의 내부 사용: 가능
- 외부 공개: 아래 5건을 조치한 뒤를 권고

근거
1. 완료 기준(치명·높음 0건)은 충족했습니다.
   - v0.1의 높음 2건은 원래 재현 시나리오로 더 이상 재현되지 않습니다.
   - BUG-01은 frontmatter 보존·표·이미지·읽기 전용으로 대부분 막혔습니다.
   - BUG-02는 시뮬레이션의 모든 시점에서 선택이 유지됩니다.
2. 개발이 통합 중 고친 "열기만 해도 파일이 다시 쓰임"은 여섯 경우 모두 재발하지 않았고, 회귀 테스트(`src/qa/openNoWrite.test.tsx`)로 고정했습니다.
3. 그러나 "보통" 중 다음 4건은 **사용자 모르게** 글이나 파일을 잃거나 바꾸고, 1건은 기본 흐름을 막습니다. 외부 사용자에게는 이 쪽이 체감 위험이 큽니다.
   - BUG-26: v0.2의 핵심인 "같은 메모를 두 창에서" 쓰는 흐름에서 입력이 사라짐
   - BUG-24: 저장 실패 중 전환하면 입력 유실(NFR-13 취지와 반대)
   - BUG-29: 다른 앱 메모의 링크·이미지가 첫 편집 때 깨짐(BUG-01의 남은 부분)
   - BUG-23: 원래 있던 메모가 스티키 ✕로 휴지통행(휴지통에서 복구는 가능)
   - BUG-28: ⌘N → 제목 → ⌘⇧S가 오류(데이터 손실은 없음, 자주 쓰는 흐름)
4. 필수 FR 중 NSPanel·메뉴 막대·끌어 놓기 등 13건은 GUI로만 확인할 수 있어 아직 미실행입니다(10장). 특히 M-9(FR-40), M-12(FR-41), M-13(NFR-13)은 필수 항목입니다.

출시 전 최소 조치(제안)
- BUG-28: flush 뒤 세션의 최신 경로를 쓴다. 고치는 범위가 작다
- BUG-24: 실패한 세션은 닫지 말고 성공할 때까지 재시도를 유지하거나, 넘어가기 전에 경고한다
- BUG-23: 스티키 세션도 "이번에 만든 메모"인지 알게 한다(⌘⇧N 경로에서 표시)
- BUG-26: 저장 직전 디스크 본문이 `saved`와 다르면 병합하거나 알린다. 최소한 창이 포커스를 잃을 때 즉시 저장해 창 사이 지연을 줄인다
- BUG-29: 열 때 왕복 구조 비교를 추가하거나, 최소한 위 5종을 읽기 전용 목록에 넣는다
- 조치 후 `npx vitest run`에서 해당 `it.fails`가 "실패"로 바뀌는지 확인하고 `it`으로 바꾼다. 이어서 10장 체크리스트를 실행한다

낮음 7건(BUG-25, 30~34, 36, 37)과 BUG-27은 PM이 v0.2 수정 범위와 v0.3 백로그로 나눠 주세요. BUG-27은 FR-24 "직접 입력"을 사실상 막으므로 v0.2 포함을 권합니다.

## 12. 부록: QA 코드 위치

| 위치 | 내용 | 남김 |
|---|---|---|
| `src/qa/fakeBackend.ts`, `src/qa/harness.tsx` | 가짜 백엔드, 마운트·입력 도구 | 저장소(회귀 테스트) |
| `src/qa/*.test.ts(x)` 5개 | 4.4 표 | 저장소 |
| `scratchpad/qa-v02/rs/` | Rust 하네스(`qa.rs`: qa_r1~r6) | 세션 scratchpad |
| `scratchpad/qa-v02/vt/` | 교차 검증(rt, rt2, fm, links) | 세션 scratchpad |
| `scratchpad/qa-v02/out/` | 말뭉치·결과 JSON, `linkvault/`, 최종 실행 원문 | 세션 scratchpad |

scratchpad 절대 경로: `(세션 임시 폴더)`. 세션이 끝나면 지워질 수 있습니다.
