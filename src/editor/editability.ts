/**
 * 이 Markdown을 Modoit 편집기로 편집해도 안전한지 (FR-43, BUG-29).
 * 1) 알려진 비지원 서식(findUnsupported)
 * 2) 실제 왕복: 열기 → 저장 → 다시 열기의 문서 구조가 처음과 같은가 — 형식만 바뀌는 것(* → -)은 통과
 */
import { Editor } from "@tiptap/core";
import { buildExtensions } from "./extensions";
import { findUnsupported, tidyMarkdown } from "../lib/markdownSafety";

export const ROUND_TRIP_LABEL = "편집하면 바뀌는 서식";

function open(md: string) {
  const ed = new Editor({
    element: document.createElement("div"),
    extensions: buildExtensions(),
    content: md,
    contentType: "markdown",
  });
  try {
    return { json: JSON.stringify(ed.getJSON()), md: tidyMarkdown(ed.getMarkdown()) };
  } finally {
    ed.destroy();
  }
}

/**
 * 기호만 쳐 두고 아직 글을 쓰지 않은 줄(`# `, `2. `, `> `)은 왕복하면 사라진다.
 * 잃는 것이 빈 줄 하나뿐이라 읽기 전용으로 막지 않는다. 스티키에서 제목을 치는 도중에
 * 메인 창이 읽기 전용으로 바뀌던 문제 (FR-43, F-08)
 */
const EMPTY_MARKER = /^[ \t]{0,3}(?:>[ \t]*)*(?:#{1,6}|\d{1,9}[.)]|>)[ \t]*$/gm;

const cache = new Map<string, string[]>();

export function unsupportedFeatures(md: string): string[] {
  const hit = cache.get(md);
  if (hit) return hit;
  let found = findUnsupported(md);
  if (found.length === 0 && md.trim()) {
    try {
      const a = open(md.replace(EMPTY_MARKER, ""));
      if (open(a.md).json !== a.json) found = [ROUND_TRIP_LABEL];
    } catch {
      found = ["해석할 수 없는 Markdown"];
    }
  }
  if (cache.size > 50) cache.clear();
  cache.set(md, found);
  return found;
}
