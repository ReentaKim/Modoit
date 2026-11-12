// 만들기: node macos/Tests/ModoitCoreTests/Fixtures/gen-merge.mjs > macos/Tests/ModoitCoreTests/Fixtures/merge-v0x.json
// v0.x src/lib/merge.ts 와 같은 로직(node-diff3)으로 병합 기대값을 만든다
import { diff3Merge } from "../../../../node_modules/node-diff3/dist/diff3.mjs"; // 저장소 루트에서 npm install 한 뒤 실행
function mergeBodies(base, mine, theirs) {
  if (theirs === base || mine === theirs) return mine;
  if (mine === base) return theirs;
  const out = [];
  for (const r of diff3Merge(mine.split("\n"), base.split("\n"), theirs.split("\n"), { excludeFalseConflicts: true })) {
    if (r.ok) out.push(...r.ok);
    else if (r.conflict) { const { a, b } = r.conflict; if (a.length && b.length) out.push(...a, "", ...b); else out.push(...a, ...b); }
  }
  return out.join("\n");
}
let seed = 20261110;
const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
const pool = ["", "가", "나", "- [ ] 할 일", "- [x] 할 일", "x", "# 제목", "가", "x"];
const cases = [];
for (let k = 0; k < 400; k++) {
  const base = Array.from({ length: rnd(9) }, () => pool[rnd(pool.length)]);
  const edit = (tag) => {
    const l = [...base];
    for (let e = 0, n = rnd(4); e < n; e++) {
      const op = rnd(3);
      if (op === 0) l.splice(rnd(l.length + 1), 0, rnd(2) ? `${tag}${e}` : pool[rnd(pool.length)]);
      else if (op === 1 && l.length) l[rnd(l.length)] = rnd(2) ? `${tag}고침${e}` : pool[rnd(pool.length)];
      else if (l.length) l.splice(rnd(l.length), 1);
    }
    return l;
  };
  const b = base.join("\n"), m = edit("내").join("\n"), t = edit("남").join("\n");
  cases.push([b, m, t, mergeBodies(b, m, t)]);
}
process.stdout.write(JSON.stringify(cases));
