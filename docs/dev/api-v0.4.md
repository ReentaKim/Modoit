# 인터페이스 계약 — v0.4 변경분

기준: [api-v0.3.md](../archive/v0.x/dev/api-v0.3.md). 여기 적지 않은 항목은 v0.3 그대로다.

## 1. 명령
| 명령 | 변경 |
|---|---|
| `quit_ready(unsaved: u32)` | **신규.** `app-will-quit`을 받은 창이 남은 입력 저장을 끝낸 뒤 부른다. `unsaved` = 저장하지 못한 메모 수(`unsavedCount()`). 호출한 창의 label로 응답을 구분한다 — BUG-35 |

## 2. 이벤트
| 이벤트 | 방향 | 내용 |
|---|---|---|
| `app-will-quit` | Rust → 모든 창 | 의미가 바뀌었다. v0.3: ⌘Q 뒤 700ms 동안 저장할 시간을 줌. **v0.4: 모든 창이 `quit_ready`로 답할 때까지(최대 4초) 종료를 미룬다.** ⌘Q뿐 아니라 Dock "종료", 로그아웃·재시동, AppleScript `quit`에서도 온다 |
| `quit-cancelled` | Rust → 모든 창 | **신규.** payload: 저장하지 못한 메모 수(number). 저장 실패로 종료를 멈췄다. 메인 창이 보이고 안내를 띄운다. 다음 종료 요청은 저장 결과와 관계없이 끝낸다 |

## 3. 프런트 규칙 (`noteSession.ts`)
- `flushForQuit()`: 이 창의 모든 세션을 저장한다(하나가 실패해도 나머지는 끝까지). 그 뒤 `quit_ready(unsavedCount())`를 부른다. 메인 창과 스티키 창 모두 `app-will-quit`에서 이것을 부른다.
