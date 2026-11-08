import { diff3Merge } from "node-diff3";

/**
 * 같은 메모를 두 창에서 고쳤을 때 줄 단위 3-way 병합 (BUG-26).
 * base: 내가 마지막으로 디스크와 같다고 알던 본문, mine: 내 편집, theirs: 지금 디스크 본문.
 * 같은 줄을 양쪽이 다르게 고쳤으면 어느 쪽도 버리지 않고 내 것 → 빈 줄 → 상대 것 순서로 둘 다 남긴다.
 */
export function mergeBodies(base: string, mine: string, theirs: string): string {
  if (theirs === base || mine === theirs) return mine;
  if (mine === base) return theirs;
  const out: string[] = [];
  const regions = diff3Merge(mine.split("\n"), base.split("\n"), theirs.split("\n"), { excludeFalseConflicts: true });
  for (const r of regions) {
    if (r.ok) out.push(...r.ok);
    else if (r.conflict) {
      const { a, b } = r.conflict;
      if (a.length && b.length) out.push(...a, "", ...b);
      else out.push(...a, ...b);
    }
  }
  return out.join("\n");
}
