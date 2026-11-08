/** 끌어 놓기 중인 항목 (dragover 중에는 dataTransfer 내용을 읽을 수 없어 따로 둔다) */
export type DragItem =
  | { kind: "folder"; path: string; parent: string; name: string }
  | { kind: "sep"; id: string; parent: string }
  | { kind: "note"; path: string };

let current: DragItem | null = null;

export const drag = {
  start(e: React.DragEvent, item: DragItem) {
    current = item;
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("application/x-modoit", JSON.stringify(item));
  },
  get: () => current,
  end() {
    current = null;
  },
};

/** 폴더 a를 b 안(또는 b 자신)으로 옮기려는지 — 금지 */
export const isSelfOrDescendant = (a: string, b: string) => b === a || b.startsWith(a + "/");
