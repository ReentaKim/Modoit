/**
 * QA 시뮬레이션 공통 도구: 실제 App / StickyApp / TipTap 편집기를 jsdom에서 띄우고 가짜 백엔드(fakeBackend)와 연결한다.
 * 각 테스트 파일은 먼저 vi.mock으로 @tauri-apps 모듈을 fakeBackend로 바꿔야 한다.
 */
import { act, createElement, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Editor } from "@tiptap/core";

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// ProseMirror가 커서 위치를 계산할 때 쓰는 DOM API (jsdom에 없음)
const rect = () => ({ x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, toJSON: () => ({}) });
Range.prototype.getBoundingClientRect = rect as unknown as () => DOMRect;
Range.prototype.getClientRects = (() => []) as unknown as () => DOMRectList;
document.elementFromPoint = () => null;
if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {};

let root: Root | null = null;
let host: HTMLDivElement | null = null;

export async function mount(el: ReactElement) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => root!.render(el));
  await sleep(100);
}

export async function unmount() {
  if (root) await act(async () => root!.unmount());
  host?.remove();
  root = null;
  host = null;
  document.body.innerHTML = "";
}

/** 실제 시간을 흘리면서 React 갱신을 반영한다 */
export async function sleep(ms: number) {
  for (let t = 0; t < ms; t += 20) await act(() => new Promise((r) => setTimeout(r, Math.min(20, ms - t))));
}

export const rows = () => [...document.querySelectorAll<HTMLElement>(".note-row")];
export const rowTitles = () => rows().map((r) => r.querySelector(".note-title .t")?.textContent ?? "");
export const row = (title: string) => {
  const r = rows().find((x) => x.querySelector(".note-title .t")?.textContent === title);
  if (!r) throw new Error(`목록에 "${title}" 없음. 지금 목록: ${rowTitles().join(", ")}`);
  return r;
};
export const activeTitle = () => document.querySelector(".note-row.active .note-title .t")?.textContent ?? null;

export async function click(el: Element) {
  await act(async () => (el as HTMLElement).click());
}

/** 화면에 있는 편집기(여럿이면 마지막) */
export function editor(): Editor {
  const els = document.querySelectorAll(".ProseMirror");
  const el = els[els.length - 1] as (Element & { editor?: Editor }) | undefined;
  if (!el?.editor) throw new Error("편집기가 없음");
  return el.editor;
}

export const editorText = () => {
  const els = document.querySelectorAll(".ProseMirror");
  return els.length ? (els[els.length - 1] as HTMLElement).textContent : null;
};

/** 사용자가 문서 끝에 글자를 친 것과 같은 트랜잭션 */
export async function typeAtEnd(text: string) {
  await act(async () => {
    const ed = editor();
    ed.commands.focus("end");
    ed.view.dispatch(ed.state.tr.insertText(text));
  });
}

/** 첫 문단(제목 줄) 끝에 친다 */
export async function typeInFirstLine(text: string) {
  await act(async () => {
    const ed = editor();
    const first = ed.state.doc.firstChild!;
    const pos = 1 + first.content.size;
    ed.view.dispatch(ed.state.tr.insertText(text, pos));
  });
}

/** 커서만 옮긴다(클릭·포커스와 같은 선택 변경) */
export async function touchEditor() {
  await act(async () => {
    const ed = editor();
    ed.commands.focus("start");
    ed.commands.setTextSelection(1);
    ed.commands.focus("end");
  });
}

export { createElement };
