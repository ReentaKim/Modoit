// @vitest-environment jsdom
/**
 * QA v0.2 — 스티키 창(StickyApp) 시뮬레이션. 실제 StickyApp + TipTap 편집기 + 가짜 백엔드.
 * it.fails 로 표시한 케이스는 v0.2 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fake } from "./fakeBackend";
import { click, createElement, editorText, mount, sleep, touchEditor, typeAtEnd, unmount } from "./harness";

vi.setConfig({ testTimeout: 20_000 });
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);
vi.mock("@tauri-apps/api/window", async () => {
  const m = await import("./fakeBackend");
  return { getCurrentWindow: () => m.fakeWindow };
});

const { StickyApp } = await import("../sticky/StickyApp");
const STICKY = "---\nsticky: {color: blue, x: 10, y: 20, w: 260, h: 260, onTop: false, open: true}\n---\n";

beforeEach(() => fake.reset());
afterEach(unmount);

async function openSticky(path: string, fresh = false) {
  fake.openStickies.add(path);
  await mount(createElement(StickyApp, { path, fresh }));
  await sleep(200);
}

/** 메모가 하나뿐일 때 그 내용 (제목에 따라 파일 이름이 바뀌므로) */
const only = () => {
  const all = [...fake.files.values()];
  expect(all).toHaveLength(1);
  return all[0].content;
};

const closeButton = () => document.querySelector<HTMLButtonElement>('.sticky-bar button[title^="다시 넣기"]')!;

describe("스티키: 열기만으로는 쓰지 않는다", () => {
  it("스티키를 열고, 편집기를 누르고, 외부 변경을 다시 읽어도 쓰기 명령이 없다", async () => {
    fake.put("메모/장보기.md", STICKY + "장보기\n\n- [ ] 우유\n\n![](../attachments/a.png)");
    await openSticky("메모/장보기.md");
    await touchEditor();
    await sleep(800);
    fake.externalWrite("메모/장보기.md", STICKY + "장보기\n\n- [ ] 우유\n- [ ] 빵");
    await sleep(600);
    expect(editorText()).toContain("빵");
    await sleep(800);
    expect(fake.writes()).toEqual([]);
  });

  it("지원하지 않는 서식이 있으면 읽기 전용이고, 체크박스를 눌러도 쓰지 않는다", async () => {
    fake.put("메모/외부.md", STICKY + "외부\n\n<div>x</div>\n\n- [ ] 항목");
    await openSticky("메모/외부.md");
    expect(document.querySelector(".bar-ro")).not.toBeNull();
    const cb = document.querySelector<HTMLInputElement>(".ProseMirror input[type=checkbox]")!;
    await click(cb);
    await sleep(800);
    expect(cb.checked).toBe(false);
    expect(fake.writes()).toEqual([]);
  });
});

describe("스티키: 입력 보존", () => {
  it("BUG-05 재검증: 입력 직후 외부 변경이 와도 방금 친 내용이 남는다", async () => {
    fake.put("메모/메모.md", STICKY + "메모");
    await openSticky("메모/메모.md");
    await typeAtEnd(" 입력");
    await sleep(100);
    fake.externalWrite("메모/메모.md", STICKY + "메모 외부 수정");
    await sleep(1200);
    expect(only()).toContain("메모 입력");
    expect(fake.files.has("메모/메모 입력.md")).toBe(true);
    expect(editorText()).toContain("메모 입력");
  });

  it("FR-44: 메인 창의 다시 넣기 요청이 오면 입력 중이던 내용을 먼저 저장하고 open:false로 바꾼다", async () => {
    fake.put("메모/메모.md", STICKY + "메모");
    await openSticky("메모/메모.md");
    await typeAtEnd(" 막 친 글");
    await sleep(50);
    fake.emit("sticky-put-back", { path: "메모/메모.md", remove: false });
    await sleep(300);
    const c = only();
    expect(c).toContain("메모 막 친 글");
    expect(c).toContain("open: false");
    expect(fake.openStickies.size).toBe(0);
  });

  it("FR-44: 꺼내 둔 메모에서 빼기 → sticky 키만 지우고 다른 키는 남긴다", async () => {
    fake.put("메모/메모.md", "---\npinned: true\nsticky: {color: blue, x: 1, y: 2, w: 260, h: 260, onTop: false, open: true}\n---\n메모");
    await openSticky("메모/메모.md");
    fake.emit("sticky-put-back", { path: "메모/메모.md", remove: true });
    await sleep(300);
    expect(fake.files.get("메모/메모.md")!.content).toBe("---\npinned: true\n---\n메모");
  });

  it("⌘⇧N으로 만든 빈 스티키를 ✕로 닫으면 휴지통으로 간다 (의도된 정리)", async () => {
    fake.put("메모/새 메모.md", STICKY);
    await openSticky("메모/새 메모.md", true); // ⌘⇧N 경로는 fresh로 띄운다 (BUG-23 수정)
    await click(closeButton());
    await sleep(300);
    expect(fake.files.has("메모/새 메모.md")).toBe(false);
  });

  // BUG-23: 이번 실행에서 만든 메모인지 보지 않고, 내용이 비었으면 무조건 휴지통으로 보낸다 (BUG-04가 스티키 쪽에 남음)
  it("BUG-23: 원래 있던 빈 메모를 스티키로 꺼냈다가 ✕로 넣으면 파일이 남아야 한다", async () => {
    fake.put("메모/할일.md", ""); // 다른 앱에서 touch로 만든 빈 파일
    fake.put("메모/할일.md", STICKY); // 꺼내기(popOut)가 frontmatter를 붙인 상태
    await openSticky("메모/할일.md");
    await click(closeButton());
    await sleep(300);
    expect(fake.files.has("메모/할일.md")).toBe(true);
  });

  it("BUG-23: 원래 내용이 있던 메모를 스티키에서 모두 지우고 ✕로 넣어도 파일이 남아야 한다", async () => {
    fake.put("메모/긴 메모.md", STICKY + "긴 메모");
    await openSticky("메모/긴 메모.md");
    const { editor } = await import("./harness");
    editor().commands.clearContent(true);
    await sleep(700);
    await click(closeButton());
    await sleep(300);
    expect(fake.files.has("메모/긴 메모.md") || [...fake.files.keys()].some((k) => k.startsWith("메모/"))).toBe(true);
  });
});
