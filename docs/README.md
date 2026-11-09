# Modoit 문서

이 프로젝트는 [**산출물 운영 모델**](operating-model.md)을 따른다. AI가 초안을 쓰고, 담당자가 검토하고, 대표가 확정한다. 문서는 하나를 계속 고치고(살아 있는 문서), 버전은 git이 남긴다.

## 어디에 무엇이 있나
| 알고 싶은 것 | 문서 | 담당 |
|---|---|---|
| 왜, 누구를 위해, 무엇을, 어디까지 (문제 정의, 기회·임팩트, **서비스 정책**, 요구사항 목록, 리스크·법령, FAQ, 마일스톤) | [`product/brief.md`](product/brief.md) | PM |
| 무엇을 언제 누가 왜 정했나 | [`decisions.md`](decisions.md) | PM |
| 기능 하나의 약속·규칙·동작·검증 | [`product/features/`](product/features/) F-01~F-12 | 기획 |
| 화면 (IA, 와이어프레임, 화면설계서) | [`prototype/index.html`](prototype/index.html) — 브라우저로 연다 | 기획·디자인 |
| 다음에 무엇부터 (RICE) | [`product/backlog.md`](product/backlog.md) | PM |
| 사람이 직접 확인할 것 | [`qa/manual-checks.md`](qa/manual-checks.md) | QA → 대표 |
| 어떻게 만드나 | [`dev/architecture.md`](dev/architecture.md)(v0.x Tauri) · [`dev/architecture-v2.md`](dev/architecture-v2.md)(v2 Swift) · [`dev/api-v0.4.md`](dev/api-v0.4.md) | 개발 |
| 긴 논의 기록 | [`meetings/`](meetings/) | PM |
| 이전 문서 | [`archive/v0.x/`](archive/v0.x/) | (보관) |

### 전통 산출물 이름으로 찾기
| 찾는 것 | 있는 곳 |
|---|---|
| Spec · PRD · 제품 사양서 | Brief |
| 요구사항 정의서 | Brief 4장(목록·비기능) + 기능 카드 2장 |
| 정책서 | Brief 3장(공통) + 기능 카드 3장(기능별) |
| 기능 정의서 · 순서도 | 기능 카드 4장 |
| IA · 와이어프레임 · 화면설계서 | 프로토타입 |
| 회의록 | 결정 기록 + `meetings/` |
| 테스트 계획 | 자동 테스트(`src/qa/`, Rust 테스트) + 수동 확인 목록 |

## 버전 현황

| 버전 | 상태 | 비고 |
|---|---|---|
| v0.1 | QA 완료 — 출시 보류(결함 22건) | 첫 MVP: 3단 메모, 스티키, Notion식 단축키, 저장 폴더 지정 |
| v0.2 | QA 완료(치명·높음 0) · 결함 수정 완료 | 폴더 계층·구분선, 메모=스티키(NSPanel), 이미지, 표, / 메뉴, 고정, 글꼴 설정, 메뉴 막대, macOS 전용 전환, v0.1 결함 수정. QA 결함 13건 수정, 2건 v0.4로 미룸(PRD v0.2 9장) |
| v0.3 | QA 완료(외부 공개 가능, 화면 확인 항목 남음) | 다크 모드, 강조 색 8가지, 생성일·수정일, `>` 토글, `\|` 인용, `->` 화살표, 꺼내 둔 메모 다시 넣기 수정(BUG-38). v0.2 결함 재검증 포함 |
| v0.4 | 개발 중 | BUG-35(Dock 종료·로그아웃 때 저장 누락) 수정. 대표 수동 확인 대기 |
| v2.0 | 기획 (Brief·기능 카드 초안) | Swift 네이티브 전환. iOS 제외 |

> v0.x 문서(PRD, 디자인 명세, 테스트 계획·보고서, 인터페이스 계약 v0.2·v0.3, 비즈니스 검토)는 [`archive/v0.x/`](archive/v0.x/)에 그대로 보관한다. 고치지 않는다.
