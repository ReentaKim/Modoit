# Modoit — AI 에이전트 작업 규칙

Modoit은 macOS 메모 앱이다. v0.x는 Tauri 2 + React + TipTap(`src/`, `src-tauri/`), v2는 Swift 네이티브로 전환 중이다(`spike/`, `docs/dev/architecture-v2.md`).

## 산출물
이 프로젝트는 [산출물 운영 모델](docs/operating-model.md)을 따른다. 작업 전에 읽는다. 요점:
- 필수 산출물: Brief(`docs/product/brief.md`), 결정 기록(`docs/decisions.md`), 기능 카드(`docs/product/features/`), 프로토타입(`docs/prototype/`), 검증(테스트 + `docs/qa/manual-checks.md`), 아키텍처(`docs/dev/`), 백로그, 릴리스 노트.
- **살아 있는 문서를 고친다.** `-v0.x`처럼 버전별로 복사하지 않는다. 버전은 git 태그와 `docs/releases/`가 맡는다.
- **한 사실은 한 곳.** 공통 정책은 Brief 3장, 기능 규칙은 그 기능 카드. 같은 규칙을 다른 문서에 다시 적지 말고 링크한다.
- **코드에 있는 사실을 문서에 옮겨 적지 않는다.** 문서에는 의도, 결정과 이유, 수용 기준, 규칙의 이유만 둔다. 문서와 코드가 다르면 코드를 확인하고 어느 쪽이 틀렸는지 밝힌다.
- 문서 맨 위에 상태(초안 / 검토 중 / 확정)와 "검토 요청"을 둔다. AI는 초안을 쓰고, 확정은 사람(대표)이 한다.
- 대표가 정한 것은 `docs/decisions.md`에 한 줄로 남긴다(날짜, 결정, 이유, 결정자).
- `docs/archive/`는 고치지 않는다.
- 문서를 고친 뒤에는 `python3 scripts/check-docs.py`를 돌려 오류 0건을 확인한다(링크, ID, 요구사항-검증 연결, Brief 목록).

## ID
`D-xx` 결정 → `FR-xx`·`NFR-xx` 요구사항 → `F-xx` 기능 카드 → `SCR-xx` 화면 → 테스트 이름 → `BUG-xx` 결함. 테스트 이름에 요구사항·결함 ID를 넣는다.

## 개발
- 테스트: `npx vitest run`, `cargo test --manifest-path src-tauri/Cargo.toml`, 타입 검사 `npx tsc --noEmit`. v2 코어: `swift test --package-path spike/macos`.
- 데이터 안전이 최우선이다: 열기만 해서는 파일을 쓰지 않는다, 입력을 잃지 않는다, 저장 폴더 밖을 건드리지 않는다(Brief 3장).
- 브랜치: `main`은 출시된 상태만 둔다(태그 `vX.Y.Z`). 작업은 `develop`에서 하고, 출시 때 `develop` → `main`으로 합친다. 큰 변경은 `develop`에서 브랜치를 따서 끝나면 `develop`에 합친다.
- 출시된 버전의 긴급 수정은 `main`에서 브랜치를 따서 출시한 뒤 `develop`에도 합친다.
- 커밋은 요청이 있을 때만 한다. `main`에 직접 커밋하지 않는다.

## 소통
- 사용자(대표)에게는 한국어로, 짧은 문장으로 쓴다. 결정이 필요하면 선택지와 추천, 이유를 함께 낸다.
- 확인하지 않은 것을 확인했다고 쓰지 않는다. 수동 확인이 필요한 것은 `docs/qa/manual-checks.md`에 모은다.
