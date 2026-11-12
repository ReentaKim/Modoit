#!/bin/bash
# 앱 자체 검사: 검사용 앱을 빌드해 임시 저장 폴더에서 화면을 실제로 조작한다 (SelfTest.swift).
#   macos/selftest.sh        실패한 항목과 통과 수를 보여 준다. 실패가 있으면 0이 아닌 값으로 끝난다
# 임시 저장 폴더와 임시 설정 폴더만 쓴다. 검사하는 동안 창이 잠깐 떴다 사라진다.
set -uo pipefail
cd "$(dirname "$0")"
APP=build/ModoitTest.app
OUT="$APP" ./build-app.sh >/dev/null 2>&1 || { echo "빌드 실패"; exit 1; }
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/vault/메모" "$S/vault/업무/회의" "$S/conf"
printf -- '---\ntags: [a, b]  # 주석\n---\n# 장보기\n- [ ] 우유\n- [x] 빵\n' > "$S/vault/메모/장보기.md"
printf '각주가 있는 글[^1]\n\n[^1]: 내용\n' > "$S/vault/메모/각주.md"
printf '# 주간 회의\n안건\n' > "$S/vault/업무/회의/주간.md"
"$APP/Contents/MacOS/Modoit" --config-dir "$S/conf" --vault "$S/vault" --selftest 1 --log "$S/log" --snapshot "$S/shot.png" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 120); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill $PID 2>/dev/null
grep -E "실패|시간 초과" "$S/log"
PASS=$(grep -c "  통과  " "$S/log"); FAIL=$(grep -c "  실패  " "$S/log")
echo "자체 검사: 통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
