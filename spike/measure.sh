#!/bin/bash
# 앱 하나를 띄워 메모리(phys footprint)를 잰다.
#   measure.sh <이름> <대기 방식: ready|초> <실행 명령…>
# 앱 프로세스 + 실행 뒤 새로 생긴 WebKit 프로세스(WebContent·Networking·GPU)의 합을 낸다.
set -uo pipefail
label=$1; wait_mode=$2; shift 2

webkit_pids() { pgrep -f 'com.apple.WebKit' | sort; }
footprint_mb() {
  [ $# -eq 0 ] && { echo 0; return; }
  footprint -f bytes --noCategories "$@" 2>/dev/null |
    awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") s += $(i + 1) } END { printf "%.1f", s / 1048576 }'
}

before=$(webkit_pids)
log=$(mktemp)
"$@" >"$log" 2>&1 &
app=$!

ready="-"
if [ "$wait_mode" = ready ]; then
  for _ in $(seq 1 300); do
    grep -q SPIKE_READY "$log" && break
    sleep 0.1
  done
  ready=$(grep -o 'ms=[0-9]*' "$log" | head -1 | cut -d= -f2)
  sleep 4 # 자리 잡을 때까지
else
  sleep "$wait_mode"
fi

new=$(comm -13 <(echo "$before") <(webkit_pids) | tr '\n' ' ')
app_mb=$(footprint_mb "$app")
# shellcheck disable=SC2086
web_mb=$(footprint_mb $new)
nproc=$(echo $new | wc -w | tr -d ' ')
total=$(echo "$app_mb + $web_mb" | bc)
printf "%-22s app=%6s MB  webkit(%2s개)=%6s MB  합계=%6s MB  준비=%s ms\n" "$label" "$app_mb" "$nproc" "$web_mb" "$total" "$ready"

kill "$app" 2>/dev/null
wait "$app" 2>/dev/null
rm -f "$log"
sleep 2
