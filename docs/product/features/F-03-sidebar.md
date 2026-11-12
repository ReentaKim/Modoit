# F-03 사이드바·폴더

| 항목 | 내용 |
|---|---|
| 담당 | 기획 (검토: 디자인, 개발, QA) |
| 상태 | **검토 중** (프로토타입 검토 때 화면과 함께 확정, D-22) |
| 대상 버전 | v2.0 |
| 화면 | [프로토타입](../../prototype/index.html) SCR-02-A |

## 1. 왜
폴더를 내 방식대로 정리한다(v0.2 목표). 폴더는 저장 폴더 안의 실제 디렉터리다(Brief 3.1-2).

## 2. 요구사항
| ID | 약속 | MoSCoW | 수용 기준 | 검증 |
|---|---|---|---|---|
| FR-26 | 폴더 계층 | Must | 하위 폴더 만들기, 펼치기·접기, 이름 변경, 휴지통 삭제(메모가 있으면 확인). 빈 이름·점으로만 된 이름·중복 거부 | A1 |
| FR-27 | 폴더 끌어 놓기 | Must | 폴더 **위** = 안으로 이동, **사이** = 순서 변경. 자기 자신·하위 폴더 안으로는 불가 | A2 |
| FR-28 | 사이드바 정렬 | Must | 직접 / 이름순 / 최신순. 직접 정렬 순서는 `.modoit/layout.json` | A3 |
| FR-29 | 구분선 | Must | 우클릭 "아래에 구분선 추가", 끌어서 옮김, 우클릭으로 삭제. 정렬은 구분선 구역 안에서만 | A3 |

## 3. 규칙
| # | 규칙 | 이유 |
|---|---|---|
| R-1 | 항목 순서: 모든 메모(전체 수) → 즐겨찾기(F-04 FR-54) → 폴더 트리(그 폴더 **바로 안**의 메모 수) → 스티키 메모(떠 있는 스티키만, F-08) → 저장 폴더 이름 | |
| R-2 | 폴더를 안으로만 옮기면 정렬 방식을 유지한다. 사이에 놓으면 직접 정렬로 바뀐다 | BUG-33, 45 |
| R-3 | `layout.json`이 없거나 깨졌으면 이름순으로 동작하고, 사용자가 순서를 바꿀 때 새로 쓴다. 바뀐 게 없으면 쓰지 않는다 | 이 파일이 없어도 앱은 정상 |
| R-4 | 폴더 이름 변경·이동 시 열린 세션과 스티키의 경로가 따라간다. 폴더 안 메모 사이의 링크는 유지한다 | |
| R-5 | 폴더 삭제 시 그 안의 모든 메모에 Brief 3.3-4를 적용한다 | |
| R-6 | 폴더 우클릭 "Finder에서 보기"로 그 폴더를 Finder에서 보인다. 저장 폴더 이름 우클릭도 같다 (D-24) | 메모가 파일이다 |

## 4. 동작
| 놓는 곳 | 결과 |
|---|---|
| 폴더 위 | 그 폴더 안으로 실제 이동 |
| 폴더 사이 | 직접 정렬 순서 변경 |
| 자기 자신·하위 폴더 | 놓을 수 없음 표시 |
| (목록의 메모를) 폴더 위 | 메모 이동(F-04) |

## 5. 검증
| ID | 무엇을 | 어디서 |
|---|---|---|
| A1 | 폴더 만들기·이름 규칙·이름 변경·삭제 | Rust `create_folder_rules`, `folder_name_rejects_dots_and_empty`, `rename_folder_updates_layout_and_case`, `trash_folder_cleans_layout` |
| A2 | 이동 규칙, 링크 유지 | Rust `move_rejects_into_self_or_descendant`, `move_folder_keeps_internal_links`, `move_to_same_folder_is_noop` |
| A3 | 정렬·구분선·layout.json | Rust `layout` 테스트(`rename_updates_keys_and_parent_order`, `move_to_other_parent_updates_both_lists`, `update_does_not_create_file_without_change` 등), `src/qa/logic.test.ts` "사이드바 순서", `src/qa/v03Logic.test.ts` BUG-33 |
| M1 | 끌어 놓기 표시와 감각 | 수동 (프로토타입 → 실제 앱) |
