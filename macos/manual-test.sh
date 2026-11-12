#!/bin/bash
# 수동 확인용 실행 (docs/qa/manual-checks.md). 개발판을 빌드하고 연습용 저장 폴더로 연다.
#   macos/manual-test.sh           연습용 폴더를 그대로 두고 다시 연다(껐다 켜기 확인용)
#   macos/manual-test.sh --reset   연습용 폴더와 설정을 처음 상태로 되돌리고 연다
# 연습용 폴더(build/manual-vault)와 연습용 설정(build/manual-config)만 쓴다. 사용자의 저장 폴더와 설정은 건드리지 않는다.
set -euo pipefail
cd "$(dirname "$0")"
VAULT="$PWD/build/manual-vault"
CONF="$PWD/build/manual-config"
./build-app.sh
pkill -f "build/Modoit.app/Contents/MacOS/Modoit" 2>/dev/null && sleep 1 || true
if [ "${1:-}" = "--reset" ] || [ ! -d "$VAULT" ]; then
  rm -rf "$VAULT" "$CONF"
  mkdir -p "$CONF" "$VAULT/업무" "$VAULT/개인/여행" "$VAULT/보관"
  cat > "$VAULT/업무/할 일.md" <<'MD'
# 이번 주 할 일

## 오늘
- [ ] 보고서 초안 쓰기
- [x] 회의실 예약
- [ ] **중요** 견적서 보내기

## 나중에
- 그냥 목록 하나
- 그냥 목록 둘

> 인용 문단입니다. `코드`와 *기울임*이 있습니다.

1. 첫째
2. 둘째
MD
  cat > "$VAULT/업무/회의록.md" <<'MD'
# 회의록

- [ ] 표가 있는 메모의 체크박스
- [x] 끝낸 일

| 항목 | 담당 |
|---|---|
| 디자인 | 가 |
| 개발 | 나 |

```
코드 블록 한 줄
```
MD
  { echo "# 긴 메모"; echo; for i in $(seq 1 60); do echo "- [ ] 항목 $i"; done; } > "$VAULT/개인/긴 메모.md"
  printf '# 제주 여행\n\n- [ ] 항공권\n- [ ] 숙소\n' > "$VAULT/개인/여행/제주.md"
  printf '# 장보기\n\n- [ ] 우유\n- [ ] 달걀\n' > "$VAULT/개인/장보기.md"
  printf '# 옛 메모\n\n보관해 둔 글.\n' > "$VAULT/보관/옛 메모.md"
  echo "연습용 폴더를 새로 만들었습니다: $VAULT"
fi
open -n build/Modoit.app --args --config-dir "$CONF" --vault "$VAULT"
