// @vitest-environment jsdom
/**
 * QA v0.4 — BUG-35: 종료 직전 저장.
 * Rust(quit.rs)가 종료 요청을 받으면 `app-will-quit`을 보내고, 창마다 남은 입력을 저장한 뒤
 * `quit_ready(unsaved)`로 답해야 종료를 허락한다. 여기서는 창(App·StickyApp) 쪽 약속을 검증한다.
 */
import { act, createElement } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fake } from "./fakeBackend";
import { click, mount, row, sleep, typeAtEnd, unmount } from "./harness";

vi.setConfig({ testTimeout: 20_000 });
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn(async () => null), ask: vi.fn(async () => true) }));
vi.mock("@tauri-apps/api/window", async () => {
  const m = await import("./fakeBackend");
  return { getCurrentWindow: () => m.fakeWindow };
});

const { App } = await import("../app/App");
const { StickyApp } = await import("../sticky/StickyApp");

const STICKY = "---\nsticky: {color: blue, x: 10, y: 20, w: 260, h: 260, onTop: false, open: true}\n---\n";
const quit = () => act(async () => fake.emit("app-will-quit"));
const readyCalls = () => fake.callsOf("quit_ready").map((c) => c.args.unsaved);
/** 메모 파일 하나의 내용 (제목에 따라 파일 이름이 바뀔 수 있으므로) */
const onlyNote = () => [...fake.files.values()].map((f) => f.content).join("\n---file---\n");

beforeEach(() => fake.reset());
afterEach(unmount);

describe("BUG-35: 종료 직전 저장 — 메인 창", () => {
  async function openNote() {
    fake.put("메모/장보기.md", "장보기\n\n- [ ] 우유");
    await mount(createElement(App));
    await sleep(300);
    await click(row("장보기"));
    await sleep(200);
  }

  it("입력하고 0.5초 저장 지연이 지나기 전에 종료해도 마지막 글자까지 저장한 뒤 quit_ready(0)을 보낸다", async () => {
    await openNote();
    await typeAtEnd(" 빵");
    await quit(); // 지연 저장 전
    await sleep(100);
    expect(onlyNote()).toContain("우유 빵");
    expect(readyCalls()).toEqual([0]);
    // 저장(write_note)이 끝난 뒤에 답한다
    const order = fake.calls.map((c) => c.cmd);
    expect(order.lastIndexOf("write_note")).toBeLessThan(order.indexOf("quit_ready"));
  });

  it("입력이 없으면 아무것도 쓰지 않고 바로 quit_ready(0)을 보낸다", async () => {
    await openNote();
    await quit();
    await sleep(100);
    expect(fake.writes()).toEqual([]);
    expect(readyCalls()).toEqual([0]);
  });

  it("저장에 실패하면 quit_ready로 그 수를 알리고, 종료가 멈추면 안내를 띄운다", async () => {
    await openNote();
    fake.failWrite = () => true;
    await typeAtEnd(" 빵");
    await quit();
    await sleep(100);
    expect(readyCalls()).toEqual([1]);
    await act(async () => fake.emit("quit-cancelled", 1));
    expect(document.querySelector(".toast")?.textContent).toContain("저장하지 못한 메모 1개가 있어 종료를 멈췄습니다");
  });
});

describe("BUG-35: 종료 직전 저장 — 스티키 창", () => {
  it("스티키에 입력하고 바로 종료해도 저장한 뒤 quit_ready(0)을 보낸다", async () => {
    fake.put("메모/메모.md", STICKY + "메모");
    fake.openStickies.add("메모/메모.md");
    await mount(createElement(StickyApp, { path: "메모/메모.md", fresh: false }));
    await sleep(200);
    await typeAtEnd(" 막 친 글");
    await quit();
    await sleep(100);
    expect(onlyNote()).toContain("메모 막 친 글");
    expect(onlyNote()).toContain("color: blue"); // frontmatter 보존
    expect(readyCalls()).toEqual([0]);
  });
});
