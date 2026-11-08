// @vitest-environment jsdom
/**
 * QA v0.3 재검증 — BUG-39~46 수정의 경계(개발 요청: BUG-42 숨김 대체 경로, BUG-40 다시 만들기·휴지통, maskCode).
 * 실제 App + StickyApp + TipTap + 가짜 백엔드(숨긴 창과 닫힌 창을 구분).
 * it.fails 는 v0.3 재검증에서 찾은 결함이다. 고치면 it 으로 바꾼다.
 */
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Editor, type JSONContent } from "@tiptap/core";
import { fake } from "./fakeBackend";
import { click, mount, row, sleep, typeAtEnd, unmount } from "./harness";
import { buildExtensions } from "../editor/extensions";
import { tidyMarkdown } from "../lib/markdownSafety";
import { maskCode, splitDetails } from "../lib/details";

vi.setConfig({ testTimeout: 30_000 });
const dialog = vi.hoisted(() => ({ open: vi.fn(async () => null as string | null), ask: vi.fn(async () => true) }));
const menuCapture = vi.hoisted(() => ({ last: [] as Array<{ label: string; action: () => void } | "-"> }));
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);
vi.mock("@tauri-apps/plugin-dialog", () => dialog);
vi.mock("@tauri-apps/api/window", async () => {
  const m = await import("./fakeBackend");
  return { getCurrentWindow: () => m.fakeWindow };
});
// 우클릭 메뉴(네이티브)는 항목만 받아 두고 테스트가 직접 누른다
vi.mock("../lib/menu", () => ({
  popupMenu: async (entries: Array<{ label: string; action: () => void } | "-">) => {
    menuCapture.last = entries;
  },
}));

const { App } = await import("../app/App");
const { StickyApp } = await import("../sticky/StickyApp");
const { unsavedCount } = await import("../lib/noteSession");
const { unsupportedFeatures } = await import("../editor/editability");

const STICKY_OPEN = "---\nsticky: {color: blue, x: 10, y: 20, w: 280, h: 280, onTop: false, open: true}\n---\n";
const content = (p: string) => fake.files.get(p)?.content;
const menu = (id: string) => act(async () => fake.emit("menu", id));
async function choose(label: string) {
  const e = menuCapture.last.find((x) => x !== "-" && x.label === label) as { action: () => void } | undefined;
  if (!e) throw new Error(`메뉴에 "${label}" 없음`);
  await act(async () => e.action());
}

let extra: Root | null = null;
const origEmit = fake.emit.bind(fake);
beforeEach(() => {
  fake.reset();
  fake.emit = origEmit;
  dialog.open.mockReset().mockResolvedValue(null);
  dialog.ask.mockReset().mockResolvedValue(true);
});
afterEach(async () => {
  fake.emit = origEmit;
  if (extra) await act(async () => extra!.unmount());
  extra = null;
  await unmount();
});

async function boot() {
  await mount(createElement(App));
  await sleep(300);
}

/** 같은 문서에 스티키 창을 하나 더 띄운다(실제로는 다른 창) */
async function mountSticky(path: string) {
  const host = document.createElement("div");
  host.className = "sticky-host";
  document.body.appendChild(host);
  extra = createRoot(host);
  await act(async () => extra!.render(createElement(StickyApp, { path })));
  await sleep(300);
  return host;
}

async function typeInSticky(host: HTMLElement, text: string) {
  const el = host.querySelector(".ProseMirror") as HTMLElement & { editor: Editor };
  await act(async () => {
    el.editor.commands.focus("end");
    el.editor.view.dispatch(el.editor.state.tr.insertText(text));
  });
}

/** 가려진 스티키: 이 창에 오는 sticky-put-back 이벤트가 ms 뒤에야 처리된다 */
function throttleStickyPutBack(ms: number) {
  fake.emit = (event: string, payload: unknown = null) => {
    if (event === "sticky-put-back") setTimeout(() => origEmit(event, payload), ms);
    else origEmit(event, payload);
  };
}

describe("BUG-42 수정 재검증: 응답 없는 스티키는 닫지 않고 숨긴다", () => {
  it("스티키가 바로 응답하면 스스로 저장하고 닫는다(숨김 경로를 타지 않음)", async () => {
    const p = "메모/장보기.md";
    fake.put(p, STICKY_OPEN + "장보기");
    fake.openStickies.add(p);
    await boot();
    const host = await mountSticky(p);
    await typeInSticky(host, " 우유");
    await click(row("장보기"));
    await sleep(200);
    await menu("pop-out");
    await sleep(1200);
    expect(fake.callsOf("hide_sticky_window")).toEqual([]);
    expect(fake.openStickies.size + fake.hiddenStickies.size).toBe(0);
    const [path] = [...fake.files.keys()];
    expect(content(path)).toContain("장보기 우유");
    expect(content(path)).toContain("open: false");
  });

  it("가려진 스티키: 0.5초 안에 응답이 없으면 숨기고, 나중에 깨어나 입력을 저장한 뒤 스스로 닫는다", async () => {
    const p = "메모/장보기.md";
    fake.put(p, STICKY_OPEN + "장보기");
    fake.openStickies.add(p);
    await boot();
    const host = await mountSticky(p);
    await typeInSticky(host, " 우유");
    await click(row("장보기"));
    await sleep(200);
    throttleStickyPutBack(1500);
    await menu("pop-out");
    await sleep(900);
    expect(fake.hiddenStickies.has(p) || [...fake.hiddenStickies].length === 1).toBe(true); // 닫지 않고 숨김
    await sleep(2000); // 깨어남
    expect(fake.openStickies.size + fake.hiddenStickies.size).toBe(0);
    const [path] = [...fake.files.keys()];
    expect(content(path)).toContain("장보기 우유");
    expect(content(path)).toContain("open: false");
  });

  it("거절: 저장 못 한 입력이 있으면 다시 나타나고 open:true로 되돌리며 메인 창에 알린다", async () => {
    const p = "메모/장보기.md";
    fake.put(p, STICKY_OPEN + "장보기");
    fake.openStickies.add(p);
    await boot();
    const host = await mountSticky(p);
    fake.failWrite = (x) => x === p;
    await typeInSticky(host, " 우유");
    await sleep(700);
    await click(row("장보기"));
    await sleep(200);
    throttleStickyPutBack(1200);
    await menu("pop-out");
    await sleep(2500);
    expect(fake.openStickies.has(p)).toBe(true); // 다시 보임
    expect(fake.hiddenStickies.has(p)).toBe(false);
    expect(document.querySelector(".toast")?.textContent).toContain("넣지 않았습니다");
    fake.failWrite = () => false;
    await sleep(3500);
    expect([...fake.files.values()].some((f) => f.content.includes("장보기 우유"))).toBe(true);
  });

  // BUG-48: 숨긴 뒤 사용자가 다시 꺼냈는데, 늦게 깨어난 스티키가 예전 '다시 넣기' 요청을 처리해
  // 방금 다시 꺼낸 창을 닫고 open:false로 되돌린다.
  it("BUG-48: 숨긴 스티키를 다시 꺼낸 뒤에 늦은 '다시 넣기' 요청이 처리되어도 스티키가 떠 있어야 한다", async () => {
    const p = "메모/장보기.md";
    fake.put(p, STICKY_OPEN + "장보기");
    fake.openStickies.add(p);
    await boot();
    await mountSticky(p);
    await click(row("장보기"));
    await sleep(200);
    throttleStickyPutBack(2000);
    await menu("pop-out"); // 다시 넣기 → 0.5초 뒤 숨김
    await sleep(900);
    expect(fake.openStickies.has(p)).toBe(false);
    await menu("pop-out"); // 사용자가 다시 꺼냄 → 숨긴 창이 다시 보인다
    await sleep(500);
    expect(fake.openStickies.has(p)).toBe(true);
    await sleep(2500); // 늦은 요청이 처리됨
    expect(fake.openStickies.has(p)).toBe(true);
    expect(content(p)).toContain("open: true");
  });
});

describe("BUG-48 수정 재검증: 늦은 요청의 경계", () => {
  async function setup() {
    const p = "메모/장보기.md";
    fake.put(p, STICKY_OPEN + "장보기");
    fake.openStickies.add(p);
    await boot();
    const host = await mountSticky(p);
    await typeInSticky(host, " 우유");
    await click(row("장보기"));
    await sleep(200);
    return p;
  }
  const finished = () => {
    const [path] = [...fake.files.keys()];
    return {
      gone: fake.openStickies.size + fake.hiddenStickies.size === 0,
      saved: (fake.files.get(path)?.content ?? "").includes("장보기 우유"),
      closedMeta: (fake.files.get(path)?.content ?? "").includes("open: false"),
    };
  };

  it("요청이 0.6초 뒤에 도착(이미 숨긴 뒤) → 저장하고 스스로 닫힌다", async () => {
    await setup();
    throttleStickyPutBack(600);
    await menu("pop-out");
    await sleep(2000);
    expect(finished()).toEqual({ gone: true, saved: true, closedMeta: true });
  });

  // BUG-49: 0.45~0.5초 사이에 도착하면 메인은 아직 숨기기 전이라 창이 보인다. 스티키는 '사용자가 다시 꺼냈다'고 보고
  // 요청을 버리는데, 받음 응답(ack)은 이미 보냈으므로 메인도 아무것도 하지 않는다 → 다시 넣기가 조용히 무시된다.
  it("BUG-49: 요청이 0.47초 뒤에 도착해도 다시 넣기가 처리되어야 한다", async () => {
    await setup();
    throttleStickyPutBack(470);
    await menu("pop-out");
    await sleep(2000);
    expect(finished()).toEqual({ gone: true, saved: true, closedMeta: true });
  });
});

describe("BUG-40 수정 재검증: 사라진 파일은 그 자리에 다시 만들고, 앱에서 지운 것은 되살리지 않는다", () => {
  it("Finder에서 옮겨진 메모에 친 입력은 원래 자리에 새 파일로 저장된다", async () => {
    fake.put("메모/a.md", "a");
    fake.put("메모/b.md", "b");
    await boot();
    await click(row("a"));
    await sleep(200);
    fake.files.delete("메모/a.md");
    await typeAtEnd(" 입력");
    await sleep(1200);
    expect([...fake.files.values()].some((f) => f.content === "a 입력")).toBe(true);
    expect(unsavedCount()).toBe(0);
    expect(document.querySelector(".banner.error")).toBeNull();
  });

  it("저장 실패 중(뒤에서 재시도 중)인 메모를 목록 우클릭으로 휴지통에 보내면 되살아나지 않는다", async () => {
    fake.put("메모/a.md", "a");
    fake.put("메모/b.md", "b");
    await boot();
    await click(row("a"));
    await sleep(200);
    fake.failWrite = (x) => x.startsWith("메모/a");
    await typeAtEnd(" 입력");
    await sleep(800);
    await click(row("b")); // a는 뒤에서 재시도
    await sleep(300);
    expect(unsavedCount()).toBe(1);
    await act(async () => {
      row("a").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true }));
    });
    await choose("휴지통으로 이동");
    await sleep(300);
    fake.failWrite = () => false;
    await sleep(3500);
    expect([...fake.files.keys()].some((k) => k.startsWith("메모/a"))).toBe(false);
    expect(unsavedCount()).toBe(0);
  });

  it("저장 못 한 입력이 있으면 저장 폴더 변경 때 묻고, 취소하면 바꾸지 않는다", async () => {
    fake.put("메모/a.md", "a");
    await boot();
    await click(row("a"));
    await sleep(200);
    fake.failWrite = () => true;
    await typeAtEnd(" 입력");
    await sleep(800);
    dialog.open.mockResolvedValue("/다른 폴더");
    dialog.ask.mockResolvedValue(false);
    await menu("change-vault");
    await sleep(300);
    const call = (dialog.ask.mock.calls as unknown[][])[0];
    expect(String(call?.[0])).toContain("입력은 사라집니다");
    expect((call?.[1] as { okLabel?: string })?.okLabel).toBe("버리고 바꾸기");
    expect(fake.callsOf("set_vault")).toEqual([]);
    expect(unsavedCount()).toBe(1);
  });
});

describe("maskCode 경계 (BUG-41 수정)", () => {
  const D = (s: string, inner: string) => `<details>\n<summary>${s}</summary>\n\n${inner}\n\n</details>`;
  it("코드 안 태그는 가리고 위치는 그대로", () => {
    const src = "a `</details>` b\n```\n</details>\n```\n";
    const m = maskCode(src);
    expect(m.length).toBe(src.length);
    expect(m).not.toContain("</details>");
  });

  it.each([
    ["닫히지 않은 펜스(토글 안) → 토글로 읽지 않음", D("a", "```\n코드")],
    ["백틱 4개로 열고 3개로 닫은 줄은 내용", D("a", "````\n</details>\n```\n````")],
    ["물결 펜스 안의 백틱 펜스 줄은 내용", D("a", "~~~\n</details>\n```\n~~~")],
  ])("%s: 읽기 전용이거나 보존", (_n, src) => {
    const editable = unsupportedFeatures(src).length === 0;
    const ed = new Editor({ element: document.createElement("div"), extensions: buildExtensions(), content: src, contentType: "markdown" });
    const saved = tidyMarkdown(ed.getMarkdown()).replace(/\n+$/, "");
    ed.destroy();
    expect(!editable || saved === src).toBe(true);
  });

  it("BUG-47 경계: 이스케이프한 역슬래시(\\\\) 뒤의 백틱은 코드를 연다", () => {
    const m = maskCode("a \\\\`</details>` b");
    expect(m).not.toContain("</details>");
  });

  it("BUG-47 경계: 코드 스팬 안의 역슬래시는 이스케이프가 아니다 (`C:\\` 뒤 토글 유지)", () => {
    const src = D("경로", "`C:\\` 드라이브") + "\n\n" + D("둘", "내용");
    expect(unsupportedFeatures(src)).toEqual([]);
    const ed = new Editor({ element: document.createElement("div"), extensions: buildExtensions(), content: src, contentType: "markdown" });
    const n = ed.state.doc.childCount;
    ed.destroy();
    expect(n).toBe(2);
  });

  it("BUG-47 경계: 한 문단 안에서 줄을 넘는 코드 스팬은 가린다", () => {
    expect(maskCode("`a\nb` c")).toBe("  \n   c");
  });

  it("인라인 코드는 같은 개수의 백틱으로만 닫힌다", () => {
    expect(splitDetails(D("a", "``a ` </details> b``"))).not.toBeNull();
  });

  // BUG-47: maskCode가 역슬래시로 이스케이프한 백틱(\`)과 문단 경계를 무시하고 서로 다른 블록의 백틱끼리 짝을 지어,
  // 그 사이의 </details>를 가린다. 앱이 저장한 토글도 글자 백틱이 두 개 이상이면 다시 열 때 'HTML' 읽기 전용이 되고,
  // '그래도 편집'으로 열면 토글 구조가 깨진 상태로 열린다.
  const t = (text: string) => ({ type: "text", text });
  const p = (text: string) => ({ type: "paragraph", content: [t(text)] });
  const toggle = (title: string, body: string): JSONContent => ({
    type: "details",
    content: [
      { type: "detailsSummary", content: [t(title)] },
      { type: "detailsContent", content: [p(body)] },
    ],
  });
  it.each([
    ["백틱 글자가 든 토글 두 개", [toggle("하나", "it`s"), toggle("둘", "that`s")]],
    ["백틱 글자가 든 토글 + 뒤 문단의 백틱", [toggle("하나", "가`나"), p("다`라")]],
    ["토글 제목과 내용에 백틱 글자 하나씩", [toggle("제목 `", "내용 `")]],
  ] as Array<[string, JSONContent[]]>)("BUG-47: 앱이 저장한 %s — 다시 열어도 편집 가능하고 같은 구조여야 한다", (_n, content) => {
    const a = new Editor({ element: document.createElement("div"), extensions: buildExtensions() });
    a.commands.setContent({ type: "doc", content });
    const j0 = JSON.stringify(a.getJSON());
    const saved = tidyMarkdown(a.getMarkdown());
    a.destroy();
    const b = new Editor({ element: document.createElement("div"), extensions: buildExtensions(), content: saved, contentType: "markdown" });
    const j1 = JSON.stringify(b.getJSON());
    b.destroy();
    expect(unsupportedFeatures(saved)).toEqual([]);
    expect(j1).toBe(j0);
  });
});
