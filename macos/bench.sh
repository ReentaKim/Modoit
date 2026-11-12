#!/bin/bash
# v2 앱의 메모리 측정 (NFR-17, F-08 P1). 스티키 0·5·10개(네이티브)와 표가 든 스티키 10개(TipTap)를 차례로 띄운다.
#   ./bench.sh [앱 경로]      기본: build/ModoitTest.app (없으면 만든다)
# 임시 저장 폴더와 임시 설정 폴더만 쓴다. 사용자의 저장 폴더와 설정은 건드리지 않는다.
# 합계 = 앱 프로세스 + 실행 뒤 새로 생긴 WebKit 프로세스. 재는 동안 다른 앱이 웹 화면을 새로 띄우면 값이 커진다.
set -uo pipefail
cd "$(dirname "$0")"
APP=${1:-build/ModoitTest.app}
[ -d "$APP" ] || OUT="$APP" ./build-app.sh >/dev/null 2>&1
BIN="$APP/Contents/MacOS/Modoit"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
