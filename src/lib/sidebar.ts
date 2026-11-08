/** 사이드바 폴더 트리의 화면 순서 계산 (FR-26~29). 순수 함수라 단위 테스트한다. */
import type { FolderNode, Layout } from "./api";

export type Item = { kind: "folder"; node: FolderNode } | { kind: "sep"; id: string };

export type Row =
  | {
      kind: "folder";
      path: string;
      name: string;
      parent: string;
      depth: number;
      hasChildren: boolean;
      expanded: boolean;
    }
  | { kind: "sep"; id: string; parent: string; depth: number };

export const isSep = (s: string) => s.startsWith("sep:");

const byName = (a: FolderNode, b: FolderNode) => a.name.localeCompare(b.name, "ko", { numeric: true });

/** 직접 정렬 순서: layout.order 에 있는 것 먼저, 나머지는 이름순으로 뒤에 */
export function customSequence(parent: string, nodes: FolderNode[], layout: Layout): Item[] {
  const byNameMap = new Map(nodes.map((n) => [n.name, n]));
  const used = new Set<string>();
  const seq: Item[] = [];
  for (const key of layout.order[parent] ?? []) {
    if (isSep(key)) seq.push({ kind: "sep", id: key });
    else if (byNameMap.has(key) && !used.has(key)) {
      seq.push({ kind: "folder", node: byNameMap.get(key)! });
      used.add(key);
    }
  }
  for (const n of [...nodes].sort(byName)) if (!used.has(n.name)) seq.push({ kind: "folder", node: n });
  // 연달아 있거나 맨 앞·맨 뒤의 구분선은 의미가 없지만 사용자가 둔 것이므로 그대로 둔다
  return seq;
}

/** 화면 순서: 구분선으로 나뉜 구역 안에서만 정렬한다 */
export function displaySequence(parent: string, nodes: FolderNode[], layout: Layout): Item[] {
  const seq = customSequence(parent, nodes, layout);
  if (layout.sort === "custom") return seq;
  const out: Item[] = [];
  let section: FolderNode[] = [];
  const cmp =
    layout.sort === "name" ? byName : (a: FolderNode, b: FolderNode) => b.modified - a.modified || byName(a, b);
  const flush = () => {
    section.sort(cmp).forEach((node) => out.push({ kind: "folder", node }));
    section = [];
  };
  for (const it of seq) {
    if (it.kind === "sep") {
      flush();
      out.push(it);
    } else section.push(it.node);
  }
  flush();
  return out;
}

export function itemKey(it: Item) {
  return it.kind === "sep" ? it.id : it.node.name;
}

/** 펼친 상태를 반영해 한 줄씩 펼쳐 놓은 목록 */
export function flattenTree(folders: FolderNode[], layout: Layout, collapsed: Set<string>): Row[] {
  const rows: Row[] = [];
  const walk = (parent: string, nodes: FolderNode[], depth: number) => {
    for (const it of displaySequence(parent, nodes, layout)) {
      if (it.kind === "sep") {
        rows.push({ kind: "sep", id: it.id, parent, depth });
        continue;
      }
      const n = it.node;
      const expanded = !collapsed.has(n.path);
      rows.push({
        kind: "folder",
        path: n.path,
        name: n.name,
        parent,
        depth,
        hasChildren: n.children.length > 0,
        expanded,
      });
      if (expanded) walk(n.path, n.children, depth + 1);
    }
  };
  walk("", folders, 0);
  return rows;
}

export function findNode(folders: FolderNode[], path: string): FolderNode | null {
  for (const n of folders) {
    if (n.path === path) return n;
    if (path.startsWith(n.path + "/")) return findNode(n.children, path);
  }
  return null;
}

export function childrenOf(folders: FolderNode[], parent: string): FolderNode[] {
  if (parent === "") return folders;
  return findNode(folders, parent)?.children ?? [];
}

/**
 * parent 안의 순서에서 key 를 빼고 beforeKey 앞(null 이면 맨 뒤)에 넣은 새 layout.
 * 정렬 방식이 이름순·최신순이었다면, 사용자가 보던 화면 순서를 모든 부모에 고정한 뒤 직접 정렬로 바꾼다.
 */
export function reorder(
  folders: FolderNode[],
  layout: Layout,
  parent: string,
  key: string,
  beforeKey: string | null,
  /** 다른 폴더 위에 놓아 '안으로' 옮긴 경우 — 순서를 정한 것이 아니다 */
  into = false,
): Layout {
  // 이름순·최신순에서 안으로만 옮겼으면 정렬 방식을 그대로 둔다 (BUG-33).
  // 맨 뒤에 놓은 것(beforeKey null)은 순서를 정한 것이므로 아래로 진행한다 (BUG-45)
  if (into && layout.sort !== "custom") return layout;
  const order: Record<string, string[]> = { ...layout.order };
  if (layout.sort !== "custom") {
    const fix = (p: string, nodes: FolderNode[]) => {
      order[p] = displaySequence(p, nodes, layout).map(itemKey);
      for (const n of nodes) fix(n.path, n.children);
    };
    fix("", folders);
  }
  const base = layout.sort === "custom"
    ? customSequence(parent, childrenOf(folders, parent), { ...layout, order }).map(itemKey)
    : order[parent] ?? [];
  const list = base.filter((k) => k !== key);
  const at = beforeKey === null ? list.length : list.indexOf(beforeKey);
  list.splice(at < 0 ? list.length : at, 0, key);
  order[parent] = list;
  return { sort: "custom", order };
}

/** parent 안 afterKey 바로 뒤에 새 구분선 */
export function addSeparator(folders: FolderNode[], layout: Layout, parent: string, afterKey: string): Layout {
  const id = "sep:" + Math.random().toString(36).slice(2, 8);
  const seq = customSequence(parent, childrenOf(folders, parent), layout).map(itemKey);
  const at = seq.indexOf(afterKey);
  seq.splice(at < 0 ? seq.length : at + 1, 0, id);
  return { ...layout, order: { ...layout.order, [parent]: seq } };
}

export function removeKey(layout: Layout, parent: string, key: string): Layout {
  return {
    ...layout,
    order: { ...layout.order, [parent]: (layout.order[parent] ?? []).filter((k) => k !== key) },
  };
}
