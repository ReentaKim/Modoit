# 운영 정책

| 항목 | 내용 |
|---|---|
| 문서 | 배포·업데이트·문의·결함 처리의 규칙과 출시 절차. **살아 있는 문서** |
| 담당 | PM (초안 AI → 확정 대표) |
| 최종 수정 | 2026-11-12 |
| 상태 | **초안** |

> **검토 요청(대표):** 3장 "출시 절차"의 순서, 4장 문의·결함 처리 방법.

사용자 매뉴얼은 따로 두지 않는다. 저장소 [README](../../README.md)(설치, 단축 입력, 단축키, 저장 구조)가 그 역할을 한다.

## 1. 배포
| 항목 | 규칙 | 근거 |
|---|---|---|
| 경로 | GitHub Releases의 dmg, Homebrew(`reentakim/tap/modoit`) | [D-11](../decisions.md) |
| 서명 | ad-hoc 서명만. Apple 공증과 Mac App Store는 하지 않는다 | D-11 (개발자 계정 비용) |
| 대상 | macOS 15 이상, Apple Silicon·Intel 겸용 빌드 | [D-09](../decisions.md) |
| 앱 ID | `io.github.reentakim.modoit`. v0.x와 같아서 설정과 저장 폴더를 이어 쓴다 | [D-23](../decisions.md) |

## 2. 업데이트
- 앱은 스스로 업데이트를 확인하지 않는다. 네트워크에 접속하지 않는다(Brief 3장). 업데이트 알림은 백로그 B-14다.
- Homebrew 사용자는 `brew upgrade --cask modoit`, 직접 받은 사용자는 새 dmg로 덮어 설치한다.
- 새 버전은 이전 버전이 쓴 메모와 설정을 그대로 읽어야 한다. 읽기만 해서는 파일을 바꾸지 않는다.

## 3. 출시 절차
| 순서 | 일 | 누가 |
|---|---|---|
| 1 | 자동 검사 통과: `swift test --package-path macos`, `macos/selftest.sh`, `npx vitest run`, `python3 scripts/check-docs.py` | AI |
| 2 | 수동 확인([manual-checks](../qa/manual-checks.md)) "대기"가 비었는지 확인 | 대표 |
| 3 | 릴리스 노트(`docs/releases/vX.Y.md`) 초안 → 대표 확정, 출시일 기입 | AI → 대표 |
| 4 | `macos/build-app.sh`의 `VERSION` 확인, `macos/make-dmg.sh`로 dmg 만들기. sha256을 적어 둔다 | AI |
| 5 | 대표가 dmg로 설치해 실제 저장 폴더에서 열어 본다(메모가 그대로인지, 스티키가 제자리에 뜨는지) | 대표 |
| 6 | `develop` → `main` 병합, 태그 `vX.Y.Z`, 푸시 | 대표 승인 뒤 AI |
| 7 | GitHub Release 만들기: dmg 첨부, 릴리스 노트의 "사용자에게 바뀐 점" 붙이기 | 대표 승인 뒤 AI |
| 8 | Homebrew cask의 `version`과 `sha256` 갱신 | 대표 승인 뒤 AI |

6~8은 되돌리기 어렵고 밖으로 나가는 일이라 매번 대표 승인을 받는다.

## 4. 문의와 결함
- 창구는 GitHub Issues 하나다.
- 결함은 심각도로 나눈다([D-08](../decisions.md)). **데이터 유실은 치명**이고, 다음 기능보다 먼저 고쳐 따로 출시한다(v0.4가 그 예, [D-02](../decisions.md)).
- 출시된 버전의 긴급 수정은 `main`에서 브랜치를 따서 출시한 뒤 `develop`에도 합친다([D-19](../decisions.md)).
- 결함에는 `BUG-xx` 번호를 붙이고, 고칠 때 그 번호를 테스트 이름에 넣는다.

## 5. 개인정보
앱은 계정, 서버, 사용 기록 수집이 없다. 메모는 사용자가 고른 폴더에만 저장한다. 문의에 메모 내용을 붙여 달라고 요구하지 않는다.
