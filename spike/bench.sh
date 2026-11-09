#!/bin/bash
# v0.3(Tauri) vs v2 스파이크(웹 스티키 / 네이티브 스티키) 메모리 비교.
#   bench.sh [v0.3 Modoit.app 경로]
#   KINDS="web native" bench.sh  → 측정할 종류만 (기본: v03 web native)
# 스티키 0·5·10개가 열린 테스트 저장 폴더를 만들어 차례로 띄운다.
# v0.3은 설정 파일의 저장 폴더를 잠시 바꾸고 끝나면 되돌린다.
set -euo pipefail
cd "$(dirname "$0")"
V03_APP=${1:-../src-tauri/target/universal-apple-darwin/release/bundle/macos/Modoit.app}
SPIKE=build/ModoitSpike.app/Contents/MacOS/ModoitSpike
CONFIG="$HOME/Library/Application Support/io.github.reentakim.modoit/config.json"
WORK=$(mktemp -d)

make_vault() { # make_vault <폴더> <스티키 수>
  python3 - "$1" "$2" <<'PY'
import os, sys
root, n = sys.argv[1], int(sys.argv[2])
os.makedirs(f"{root}/메모", exist_ok=True)
os.makedirs(f"{root}/업무", exist_ok=True)
body = """# {t}

- [ ] 할 일 하나
- [x] 끝낸 일
- 그냥 목록

| 항목 | 값 |
|---|---|
| 가 | 1 |

> 인용 문단 **굵게** `코드`
"""
for i in range(20):
    with open(f"{root}/{'메모' if i % 2 else '업무'}/메모 {i}.md", "w") as f:
        f.write(body.format(t=f"메모 {i}"))
for i in range(n):
    x, y = 60 + (i % 5) * 300, 80 + (i // 5) * 320
    with open(f"{root}/메모/스티키 {i}.md", "w") as f:
        f.write(f"---\nsticky: {{color: yellow, x: {x}, y: {y}, w: 280, h: 280, onTop: false, open: true}}\n---\n" + body.format(t=f"스티키 {i}"))
PY
}

cp "$CONFIG" "$WORK/config.backup.json"
restore() { cp "$WORK/config.backup.json" "$CONFIG"; }
trap restore EXIT

for n in 0 5 10; do
  for kind in ${KINDS:-v03 web native}; do
    v="$WORK/vault-$kind-$n"
    make_vault "$v" "$n"
    case $kind in
      v03)
        python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["vault"]=sys.argv[2]; json.dump(c,open(p,"w"),ensure_ascii=False,indent=2)' "$CONFIG" "$v"
        ./measure.sh "v0.3 Tauri   스티키 $n" 12 "$V03_APP/Contents/MacOS/modoit"
        restore ;;
      *)
        ./measure.sh "v2 $kind$( [ $kind = web ] && echo '   ' || echo '') 스티키 $n" ready "$SPIKE" --vault "$v" --sticky-kind "$kind" ;;
    esac
  done
done
restore
trap - EXIT
rm -rf "$WORK"
