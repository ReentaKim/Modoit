# 인터페이스 계약 — v0.3 변경분

기준: [api-v0.2.md](api-v0.2.md). 여기 적지 않은 항목은 v0.2 그대로다.

## 1. 자료형
| 자료형 | 변경 |
|---|---|
| `NoteMeta` | `created: number` 추가(파일 생성 시각 ms, 알 수 없으면 `modified`) — FR-47 |
| `Prefs` | `noteSort`에 `"created"` 추가. `theme: "system"\|"light"\|"dark"`(기본 system), `accent: "yellow"\|"orange"\|"red"\|"pink"\|"purple"\|"blue"\|"green"\|"graphite"`(기본 yellow). 범위 밖 값은 Rust가 기본값으로 바꾼다 |
| `StickyMeta` | 기본 크기 **280×280**(TS·Rust 동일). `open` 키가 없으면 **false**(넣어 둠) — BUG-37 |

## 2. 명령
| 명령 | 변경 |
|---|---|
| `open_sticky(path, geom, fresh?)` | `fresh: bool`(선택, 기본 false) 추가. true면 창에 `window.__MODOIT_STICKY_FRESH__ = true`를 넣는다. ⌘⇧N으로 방금 만든 메모만 ✕로 비우고 닫을 때 휴지통으로 보낸다 — BUG-23 |
| `has_sticky_window(path) → bool` | **신규.** 그 메모의 스티키 창이 실제로 떠 있는지 — BUG-36, BUG-38 |
| `set_prefs(prefs)` | 저장 뒤 `theme`을 앱 전체 macOS appearance로 적용한다(`AppHandle::set_theme`). 시작할 때도 적용한다 — FR-45 |
| `write_note` 외 모든 원자적 쓰기 | 임시 파일로 바꿔 끼울 때 원래 파일의 **생성 시각을 옮겨 준다**(macOS `setattrlist` crtime) — FR-47 |

## 3. 이벤트
| 이벤트 | 방향 | 내용 |
|---|---|---|
| `sticky-put-back` | 메인 창 → 스티키 창(프런트 emit) | `{ path, remove }`. 받은 스티키는 남은 입력을 저장하고 `open:false`(remove면 sticky 삭제)로 바꾼 뒤 스스로 닫는다. **0.5초 안에 창이 남아 있으면 메인 창이 `close_sticky_window`로 직접 닫고 파일을 고친다** — FR-44, BUG-37/38 |
| `prefs-changed` | Rust → 모든 창 | v0.2와 같다. 단, **메인 창은 듣지 않는다**(설정을 바꾸는 유일한 창이므로) — BUG-27 |

## 4. 저장 규칙 (프런트, `noteSession.ts`)
- 저장 직전 디스크 본문 ≠ 세션이 알던 본문이면 `mergeBodies(base, mine, theirs)`(node-diff3 줄 단위 3-way)로 병합해서 쓰고, 병합 결과를 화면에 다시 보여 준다 — BUG-26
- 화면에서 떠날 때 `release()`: 저장이 끝났으면 닫고, 아니면 닫지 않고 뒤에서 계속 다시 시도한다 — BUG-24
- 본문 쓰기와 이름 맞추기(`sync_note_name`)를 나눠 다시 시도한다 — BUG-25
- 저장 뒤 경로가 바뀔 수 있는 작업(꺼내기, 다시 넣기, 메모 이동)은 `flushAndResolve(path)`로 바뀐 경로를 받는다 — BUG-28

## 5. Markdown
- 토글: `<details>` / `<summary>…</summary>` / 빈 줄 / 내용 / 빈 줄 / `</details>`. 각 태그는 한 줄을 차지한다. 이 꼴만 지원 서식이다(NFR-14)
- 맨 앞 구분선은 `***`로 쓴다 — BUG-31
- 편집 가능 판정은 `unsupportedFeatures(md)`(`src/editor/editability.ts`)를 쓴다: `findUnsupported` + 실제 왕복 구조 비교 — BUG-29

## 6. v0.3 QA 반영
| 항목 | 내용 |
|---|---|
| `has_sticky_window(path)` | 창이 있고 **보이는** 경우만 true(숨긴 창은 false) |
| `hide_sticky_window(path)` | **신규.** 창을 닫지 않고 숨긴다 — BUG-42 |
| 이벤트 `sticky-put-back-ack` | 스티키 → 메인 `{path}`: 다시 넣기 요청을 받음. 0.5초 안에 없으면 메인이 `hide_sticky_window` |
| 이벤트 `sticky-put-back-refused` | 스티키 → 메인 `{path}`: 저장하지 못한 입력이 있어 넣지 않음. 스티키는 다시 보이고 `open:true`로 되돌린다 |
| 저장 중 파일 없음 | `read_note`가 `os error 2`면 `write_note`로 그 자리에 다시 만든다 — BUG-40 |
| `discardUnder(path)` | 휴지통으로 보낼 메모·폴더의 세션을 저장 없이 닫는다 |
| `reorder(..., into)` | 6번째 인자 `into`: 폴더 위에 놓아 안으로 옮긴 경우만 정렬 방식 유지 — BUG-45 |
| `src/lib/details.ts` | `maskCode`, `splitDetails`, `stripToggleTags`(편집기·안전성 검사 공용) — BUG-41, 46 |
