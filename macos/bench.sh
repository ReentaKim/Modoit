#!/bin/bash
# v2 앱의 메모리와 실행 시간 측정 (NFR-17, NFR-18, F-08 P1).
#   ./bench.sh            개발판(debug) 빌드로 잰다
#   ./bench.sh release    배포판(release) 빌드로 잰다. 앱 ID는 측정용(.bench)으로 바꿔 정식판 설정을 건드리지 않는다
# 메모리: 스티키 0·5·10개(네이티브)와 표가 든 스티키 10개(TipTap)를 차례로 띄운다.
#   합계 = 앱 프로세스 + 실행 뒤 새로 생긴 WebKit 프로세스. 재는 동안 다른 앱이 웹 화면을 새로 띄우면 값이 커진다.
# 실행 시간: 네이티브 스티키 10개 + 메모 하나를 연 상태로 실행 → 준비 신호(--ready-file)까지. 1회 버리고 3회의 중앙값.
# 임시 저장 폴더와 임시 설정 폴더만 쓴다. 사용자의 저장 폴더와 설정은 건드리지 않는다.
set -uo pipefail
cd "$(dirname "$0")"
MODE=${1:-debug}
APP=build/ModoitBench-$MODE.app
OUT="$APP" ./build-app.sh "$MODE" >/dev/null 2>&1 || { echo "빌드 실패"; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.reentakim.modoit.bench" "$APP/Contents/Info.plist"
codesign --force -s - "$APP" 2>/dev/null
BIN="$APP/Contents/MacOS/Modoit"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "빌드: $MODE"

make_vault() { # make_vault <폴더> <스티키 수> <native|web>
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
root, n, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3]
os.makedirs(f"{root}/메모", exist_ok=True)
os.makedirs(f"{root}/업무", exist_ok=True)
plain = "# {t}\n\n- [ ] 할 일 하나\n- [x] 끝낸 일\n- 그냥 목록\n\n> 인용 문단 **굵게** `코드`\n"
table = plain + "\n| 항목 | 값 |\n|---|---|\n| 가 | 1 |\n"
for i in range(20):
    with open(f"{root}/{'메모' if i % 2 else '업무'}/메모 {i}.md", "w") as f:
        f.write(table.format(t=f"메모 {i}"))
for i in range(n):
    x, y = 60 + (i % 5) * 300, 80 + (i // 5) * 320
    with open(f"{root}/메모/스티키 {i}.md", "w") as f:
        f.write(f"---\nsticky: {{ color: yellow, x: {x}, y: {y}, w: 280, h: 280, onTop: false, open: true }}\n---\n"
                + (table if kind == "web" else plain).format(t=f"스티키 {i}"))
PY
}

webkit_pids() { pgrep -f 'com.apple.WebKit' | sort; }
footprint_mb() {
  [ $# -eq 0 ] && { echo 0; return; }
  footprint -f bytes --noCategories "$@" 2>/dev/null |
    awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") s += $(i + 1) } END { printf "%.1f", s / 1048576 }'
}

measure() { # measure <이름> <스티키 수> <native|web>
  local v="$WORK/vault-$3-$2" c="$WORK/conf-$3-$2"
  mkdir -p "$c"; make_vault "$v" "$2" "$3"
  local before; before=$(webkit_pids)
  "$BIN" --config-dir "$c" --vault "$v" >/dev/null 2>&1 &
  local app=$!
  sleep 10 # 자리 잡을 때까지
  local new; new=$(comm -13 <(echo "$before") <(webkit_pids) | tr '\n' ' ')
  local app_mb web_mb
  app_mb=$(footprint_mb "$app")
  # shellcheck disable=SC2086
  web_mb=$(footprint_mb $new)
  printf "%-26s 앱=%6s MB  WebKit(%s개)=%6s MB  합계=%6s MB\n" "$1" "$app_mb" "$(echo $new | wc -w | tr -d ' ')" "$web_mb" "$(echo "$app_mb + $web_mb" | bc)"
  kill "$app" 2>/dev/null; wait "$app" 2>/dev/null
  sleep 2
}

measure "스티키 0개" 0 native
measure "네이티브 스티키 5개" 5 native
measure "네이티브 스티키 10개" 10 native
measure "TipTap 스티키 10개(표)" 10 web

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
launch_time() {
  local v="$WORK/vault-launch" c="$WORK/conf-launch" times=()
  mkdir -p "$c"; make_vault "$v" 10 native
  for i in 0 1 2 3; do
    rm -f "$WORK/ready"
    local t0; t0=$(now)
    "$BIN" --config-dir "$c" --vault "$v" --note "메모/메모 1.md" --ready-file "$WORK/ready" >/dev/null 2>&1 &
    local app=$!
    for _ in $(seq 100); do [ -s "$WORK/ready" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
    local t1; t1=$(cat "$WORK/ready" 2>/dev/null || echo 0)
    kill "$app" 2>/dev/null; wait "$app" 2>/dev/null
    perl -e 'select(undef,undef,undef,1.5)'
    [ "$i" -gt 0 ] && times+=("$(echo "$t1 - $t0" | bc)")
  done
  printf "실행 시간(스티키 10개, 3회): %s  중앙값=%s 초\n" "${times[*]}" "$(printf '%s\n' "${times[@]}" | sort -n | sed -n 2p)"
}
launch_time
