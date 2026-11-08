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

const cache = new Map<string, string[]>();

export function unsupportedFeatures(md: string): string[] {
  const hit = cache.get(md);
  if (hit) return hit;
  let found = findUnsupported(md);
  if (found.length === 0 && md.trim()) {
    try {
      const a = open(md);
      if (open(a.md).json !== a.json) found = [ROUND_TRIP_LABEL];
    } catch {
      found = ["해석할 수 없는 Markdown"];
    }
  }
  if (cache.size > 50) cache.clear();
  cache.set(md, found);
  return found;
}
