// @vitest-environment jsdom
/**
 * QA v0.3 — 메인 창 시뮬레이션: BUG-38(다시 넣기), BUG-36, BUG-23(fresh), FR-45/46(모양·강조 색), FR-47(생성일),
 * 그리고 release된 세션이 저장 폴더 변경을 막는지. 실제 App(+필요하면 StickyApp) + TipTap + 가짜 백엔드.
 * it.fails 는 v0.3 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fake } from "./fakeBackend";
import { activeTitle, click, mount, row, rowTitles, sleep, typeAtEnd, unmount } from "./harness";

vi.setConfig({ testTimeout: 30_000 });
const dialog = vi.hoisted(() => ({ open: vi.fn(async () => null as string | null), ask: vi.fn(async () => true) }));
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);
vi.mock("@tauri-apps/plugin-dialog", () => dialog);
vi.mock("@tauri-apps/api/window", async () => {
  const m = await import("./fakeBackend");
  return { getCurrentWindow: () => m.fakeWindow };
});

const { App } = await import("../app/App");
const { StickyApp } = await import("../sticky/StickyApp");
const { unsavedCount } = await import("../lib/noteSession");

const STICKY_OPEN = "---\nsticky: {color: blue, x: 10, y: 20, w: 280, h: 280, onTop: false, open: true}\n---\n";
const content = (p: string) => fake.files.get(p)?.content;
const menu = (id: string) => act(async () => fake.emit("menu", id));

let extra: Root | null = null;
beforeEach(() => {
  fake.reset();
  dialog.open.mockReset().mockResolvedValue(null);
  dialog.ask.mockReset().mockResolvedValue(true);
});
afterEach(async () => {
  if (extra) await act(async () => extra!.unmount());
  extra = null;
  await unmount();
});

async function boot() {
  await mount(createElement(App));
  await sleep(300);
}

describe("BUG-38 / FR-44: 메인 창에서 다시 넣기", () => {
  it("스티키 창이 응답하지 않아도(가려져 스크립트가 늦음) 0.5초 뒤 메인이 닫고 open:false로 고친다", async () => {
    fake.put("메모/장보기.md", STICKY_OPEN + "장보기");
    fake.openStickies.add("메모/장보기.md"); // 창은 떠 있지만 sticky-put-back을 받을 스크립트가 없다
    await boot();
    await click(row("장보기"));
    await sleep(200);
    await menu("pop-out"); // ⌘⇧S = 토글
    await sleep(1200);
    expect(fake.openStickies.has("메모/장보기.md")).toBe(false);
    expect(content("메모/장보기.md")).toContain("open: false");
    expect(content("메모/장보기.md")).toContain("color: blue"); // 색·위치는 기억
  });

  it("BUG-36: 파일은 open:true인데 창이 없으면 사이드바 '다시 넣기'가 파일만 고친다", async () => {
    fake.put("메모/장보기.md", "장보기");
    await boot();
    // 앱이 떠 있는 동안 다른 Mac에서 동기화되어 open:true가 됨 → 창은 없다
    fake.externalWrite("메모/장보기.md", STICKY_OPEN + "장보기");
    await sleep(600);
    expect(fake.openStickies.size).toBe(0);
    const btn = document.querySelector<HTMLButtonElement>(".sticky-row .row-action")!;
    expect(btn.title).toBe("다시 넣기");
    await click(btn);
    await sleep(800);
    expect(content("메모/장보기.md")).toContain("open: false");
    expect(fake.callsOf("close_sticky_window")).toEqual([]);
  });

  // BUG-42: 스티키는 저장하지 못한 입력이 있으면 스스로 닫지 않는데(BUG-24 수정), 메인 창의 0.5초 대체 경로가
  // 그 사정을 모르고 창을 닫아 버린다. 실제 앱에서는 창이 사라지며 입력도 사라진다.
  it("BUG-42: 스티키에 저장 못 한 입력이 있으면 메인 창의 다시 넣기가 창을 강제로 닫지 않아야 한다", async () => {
    const p = "메모/장보기.md";
    fake.put(p, STICKY_OPEN + "장보기");
    fake.openStickies.add(p);
    await boot();
    // 같은 문서에 스티키 창을 하나 더 띄운다(실제로는 다른 창)
    const host = document.createElement("div");
    document.body.appendChild(host);
    extra = createRoot(host);
    await act(async () => extra!.render(createElement(StickyApp, { path: p })));
    await sleep(300);
    fake.failWrite = () => true; // 디스크 쓰기 실패 중
    const sticky = host.querySelector<HTMLElement>(".ProseMirror") as HTMLElement & { editor: import("@tiptap/core").Editor };
    await act(async () => {
      sticky.editor.commands.focus("end");
      sticky.editor.view.dispatch(sticky.editor.state.tr.insertText(" 스티키 입력"));
    });
    await sleep(700); // 저장 시도 → 실패
    await click(row("장보기"));
    await sleep(200);
    await menu("pop-out"); // 다시 넣기
    await sleep(1500);
    expect(fake.openStickies.has(p)).toBe(true); // 저장되지 않았으니 창이 남아 있어야 한다
  });
});

describe("BUG-23 수정: ⌘⇧N만 fresh", () => {
  it("⌘⇧N은 open_sticky(fresh=true), 목록에서 꺼내기는 fresh 없음", async () => {
    fake.put("메모/기존.md", "기존");
    await boot();
    await menu("new-sticky-note");
    await sleep(300);
    expect(fake.callsOf("open_sticky")[0].args.fresh).toBe(true);
    await click(row("기존"));
    await sleep(200);
    await menu("pop-out");
    await sleep(500);
    const calls = fake.callsOf("open_sticky");
    expect(calls[calls.length - 1].args.fresh).toBe(false);
  });
});

describe("FR-47 생성일·수정일", () => {
  it("만든 날짜순 정렬과 날짜 줄", async () => {
    const day = 86_400_000;
    const now = Date.now();
    fake.put("메모/오래전에 만든.md", "오래전에 만든", { created: now - 30 * day });
    fake.put("메모/어제 만든.md", "어제 만든", { created: now - day });
    fake.put("메모/방금 만든.md", "방금 만든", { created: now - 1000 });
    // 수정 순서는 만든 순서와 반대로
    fake.files.get("메모/방금 만든.md")!.mtime = now - 3 * day;
    fake.files.get("메모/어제 만든.md")!.mtime = now - 2 * day;
    fake.files.get("메모/오래전에 만든.md")!.mtime = now;
    fake.prefs.noteSort = "created";
    await boot();
    expect(rowTitles()).toEqual(["방금 만든", "어제 만든", "오래전에 만든"]);
    await click(row("오래전에 만든"));
    await sleep(200);
    const line = document.querySelector(".editor-date")?.textContent ?? "";
    expect(line).toMatch(/^만든 날 .+\s+·\s+고친 날 .+$/);
  });

  it("저장해도 생성 시각은 바뀌지 않는다(목록 순서 유지)", async () => {
    const now = Date.now();
    fake.put("메모/a.md", "a", { created: now - 5000 });
    fake.put("메모/b.md", "b", { created: now - 1000 });
    fake.prefs.noteSort = "created";
    await boot();
    expect(rowTitles()).toEqual(["b", "a"]);
    await click(row("a"));
    await sleep(200);
    await typeAtEnd("a");
    await sleep(1200);
    expect(rowTitles()).toEqual(["b", "aa"]);
  });
});

describe("FR-45 / FR-46 모양·강조 색, BUG-27", () => {
  it("설정에서 다크·강조 색을 고르면 set_prefs에 theme·accent가 가고 data-accent가 바로 바뀐다", async () => {
    await boot();
    await menu("settings");
    await sleep(100);
    const seg = [...document.querySelectorAll<HTMLButtonElement>(".sheet .segmented button")];
    await click(seg.find((b) => b.textContent === "다크")!);
    await click(document.querySelector<HTMLButtonElement>('.accent-dot[aria-label="파랑"], .accent-dot[title="파랑"]')!);
    await sleep(100);
    const last = fake.callsOf("set_prefs").slice(-1)[0].args.prefs as { theme: string; accent: string };
    expect(last.theme).toBe("dark");
    expect(last.accent).toBe("blue");
    expect(document.documentElement.dataset.accent).toBe("blue");
  });
});

describe("FR-31 개정(고정 뒤 반영분): 꺼내 둔 메모 목록, 보기 > 모양 메뉴", () => {
  it("넣어 둔 메모(open:false)는 '꺼내 둔 메모'와 목록 색 점에 보이지 않고, 떠 있는 것만 보인다", async () => {
    fake.put("메모/넣어 둠.md", STICKY_OPEN.replace("open: true", "open: false") + "넣어 둠");
    fake.put("메모/떠 있음.md", STICKY_OPEN + "떠 있음");
    await boot();
    const labels = [...document.querySelectorAll(".sticky-row .label")].map((e) => e.textContent);
    expect(labels).toEqual(["떠 있음"]);
    expect(row("넣어 둠").querySelector(".sticky-dot")).toBeNull();
    expect(row("떠 있음").querySelector(".sticky-dot")).not.toBeNull();
  });

  it("디자인 7장: 사이드바 맨 아래 톱니 버튼이 설정 시트를 연다", async () => {
    await boot();
    const gear = document.querySelector<HTMLButtonElement>(".side-footer .icon-btn")!;
    expect(gear.title).toBe("설정 — 모양(다크 모드)·강조 색·글꼴 (⌘,)");
    expect(document.querySelector(".sheet")).toBeNull();
    await click(gear);
    expect(document.querySelector(".sheet")).not.toBeNull();
    expect([...document.querySelectorAll(".sheet .segmented button")].map((b) => b.textContent).slice(0, 3)).toEqual(["시스템", "라이트", "다크"]);
  });

  it("메뉴 막대 '보기 > 모양 > 다크'는 설정 창 없이 theme만 바꿔 저장한다", async () => {
    await boot();
    await menu("theme-dark");
    await sleep(100);
    const last = fake.callsOf("set_prefs").slice(-1)[0].args.prefs as { theme: string; fontSize: number };
    expect(last.theme).toBe("dark");
    expect(last.fontSize).toBe(17);
  });
});

describe("release된 세션과 저장 폴더 변경 (BUG-24 수정의 부작용)", () => {
  // BUG-40의 App 쪽 영향: 사라진 파일의 입력은 저장될 길이 없는데 unsavedCount()가 줄지 않아 폴더 변경이 계속 막힌다
  it("BUG-40: Finder에서 옮겨진 메모에 친 입력 때문에 저장 폴더 변경이 영영 막히지 않아야 한다", async () => {
    fake.put("메모/a.md", "a");
    fake.put("메모/b.md", "b");
    await boot();
    await click(row("a"));
    await sleep(200);
    fake.files.delete("메모/a.md"); // Finder에서 다른 곳으로 옮김
    await typeAtEnd(" 입력");
    await sleep(800);
    await click(row("b"));
    await sleep(6500); // 재시도 두 번
    expect(activeTitle()).toBe("b"); // v0.3 수정: 폴더를 바꾸면 화면이 새로 그려지므로 선택 확인은 바꾸기 전에 한다
    dialog.open.mockResolvedValue("/다른 폴더");
    await menu("change-vault");
    await sleep(300);
    const blocked = (dialog.ask.mock.calls as unknown[][]).some((c) => String(c[0]).includes("저장하지 못한 메모"));
    const n = unsavedCount();
    expect(blocked).toBe(false);
    expect(n).toBe(0);
  });
});
