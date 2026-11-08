// @vitest-environment jsdom
/**
 * QA v0.2 — 메인 창 경쟁 상태와 v0.1 결함 재검증. 실제 App + EditorPane + TipTap + 가짜 백엔드.
 * it.fails 로 표시한 케이스는 v0.2 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fake } from "./fakeBackend";
import {
  activeTitle,
  click,
  createElement,
  editorText,
  mount,
  row,
  rowTitles,
  sleep,
  typeAtEnd,
  typeInFirstLine,
  unmount,
} from "./harness";
import { NoteSession } from "../lib/noteSession";
import { splitNote } from "../lib/frontmatter";

vi.setConfig({ testTimeout: 30_000 });
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: async () => null, ask: async () => true }));

const { App } = await import("../app/App");

beforeEach(() => fake.reset());
afterEach(unmount);

async function boot() {
  await mount(createElement(App));
  await sleep(300);
}
const menu = (id: string) => act(async () => fake.emit("menu", id));
const content = (p: string) => fake.files.get(p)?.content;
const banner = () => document.querySelector(".banner.error")?.textContent ?? null;

describe("BUG-02 재검증: 제목 입력 직후 다른 메모로 가도 선택이 되돌아가지 않는다", () => {
  it("A: ⌘N → '장보기' 입력 → 0.1초 뒤 다른 메모 클릭", async () => {
    fake.put("메모/다른.md", "다른");
    await boot();
    await menu("new-note");
    await sleep(200);
    expect(activeTitle()).toBe("새로운 메모");
    await typeAtEnd("장보기");
    await sleep(100);
    await click(row("다른"));
    for (const t of [20, 200, 600, 1500]) {
      await sleep(t);
      expect(activeTitle()).toBe("다른");
      expect(editorText()).toBe("다른");
    }
    expect(content("메모/장보기.md")).toBe("장보기");
  });

  it("B: 기존 메모 첫 줄 수정 → 0.1초 뒤 ⌘N → 새 빈 메모가 열리고 남는다", async () => {
    fake.put("메모/기존.md", "기존\n\n본문");
    await boot();
    await click(row("기존"));
    await sleep(200);
    await typeInFirstLine(" 수정");
    await sleep(100);
    await menu("new-note");
    await sleep(1500);
    expect(activeTitle()).toBe("새로운 메모");
    expect(editorText()).toBe("");
    expect(content("메모/기존 수정.md")).toBe("기존 수정\n\n본문");
    expect(fake.files.has("메모/새 메모.md")).toBe(true);
  });
});

describe("BUG-04 재검증: 빈 메모 자동 정리는 이번에 만든 메모만", () => {
  it("다른 앱에서 만든 빈 파일은 열어 보고 떠나도 남는다", async () => {
    fake.put("메모/다른.md", "다른");
    fake.put("메모/할일.md", "");
    await boot();
    await click(row("새로운 메모"));
    await sleep(200);
    await click(row("다른"));
    await sleep(600);
    expect(fake.files.has("메모/할일.md")).toBe(true);
    expect(fake.callsOf("trash_note")).toEqual([]);
  });

  it("앱에서 ⌘N으로 만든 뒤 아무것도 안 쓰고 떠나면 휴지통으로 간다", async () => {
    fake.put("메모/다른.md", "다른");
    await boot();
    await menu("new-note");
    await sleep(200);
    await click(row("다른"));
    await sleep(600);
    expect(fake.callsOf("trash_note").map((c) => c.args.path)).toEqual(["메모/새 메모.md"]);
  });
});

describe("NFR-13 / BUG-22 재검증: 저장 실패를 알리고 다시 시도한다", () => {
  it("쓰기가 실패하면 알림이 뜨고, 권한이 돌아오면 3초 안에 저장되고 알림이 사라진다", async () => {
    fake.put("메모/메모.md", "메모");
    await boot();
    await click(row("메모"));
    await sleep(200);
    fake.failWrite = () => true;
    await typeAtEnd(" 추가");
    await sleep(800);
    expect(banner()).toContain("저장하지 못했습니다");
    fake.failWrite = () => false;
    await sleep(3300);
    expect(content("메모/메모 추가.md")).toBe("메모 추가");
    expect(banner()).toBeNull();
  });

  // BUG-24: 실패 중에 다른 메모로 넘어가면 leave()가 세션을 닫아 재시도 타이머가 지워진다 → 입력이 조용히 사라진다
  it("BUG-24: 저장 실패 중 다른 메모로 넘어가도, 권한이 돌아오면 입력이 저장되어야 한다", async () => {
    fake.put("메모/메모.md", "메모");
    fake.put("메모/다른.md", "다른");
    await boot();
    await click(row("메모"));
    await sleep(200);
    fake.failWrite = (p) => p === "메모/메모.md";
    await typeAtEnd(" 잃으면 안 되는 글");
    await sleep(800);
    expect(banner()).toContain("저장하지 못했습니다");
    await click(row("다른"));
    await sleep(300);
    fake.failWrite = () => false;
    await sleep(4000);
    expect([...fake.files.values()].some((f) => f.content.includes("잃으면 안 되는 글"))).toBe(true);
  });

  // BUG-25: 본문 쓰기는 성공했는데 이름 맞추기(sync_note_name)만 실패하면, 재시도 때 pending이 비어 있어 실패 표시가 영영 안 지워진다
  it("BUG-25: 이름 맞추기만 한 번 실패했다면 다음 재시도 뒤 알림이 사라져야 한다", async () => {
    fake.put("메모/메모.md", "메모");
    await boot();
    await click(row("메모"));
    await sleep(200);
    let once = true;
    fake.failSync = () => {
      const f = once;
      once = false;
      return f;
    };
    await typeAtEnd(" 추가");
    await sleep(800);
    expect(banner()).toContain("저장하지 못했습니다");
    await sleep(3500);
    expect(banner()).toBeNull();
  });
});

describe("FR-30 같은 메모를 두 창에서 편집", () => {
  // 스티키 창의 세션은 같은 NoteSession 코드를 쓰므로, 메인 창 옆에 세션 하나를 따로 만들어 스티키처럼 쓴다
  it("BUG-26: 스티키에서 입력하고 1초 안에 메인 창으로 넘어가 입력하면 스티키의 마지막 입력이 사라지지 않아야 한다", async () => {
    fake.put("메모/공유.md", "공유\n\n본문");
    await boot();
    await click(row("공유"));
    await sleep(300);
    const sticky = new NoteSession("메모/공유.md", splitNote(content("메모/공유.md")!).body);
    sticky.syncName = false; // 이름은 그대로 두고 본문만 본다
    sticky.edit("공유\n\n본문 스티키에서 친 글");
    await sleep(600); // 스티키가 저장(500ms)한 직후, 메인 창은 아직 다시 읽기 전(감시기 250ms)
    expect(content("메모/공유.md")).toContain("스티키에서 친 글");
    await typeAtEnd(" 메인에서 친 글");
    await sleep(1500);
    sticky.close();
    const c = content("메모/공유.md")!;
    expect(c).toContain("메인에서 친 글");
    expect(c).toContain("스티키에서 친 글");
  });

  it("한쪽에서만 쓰면 다른 쪽에 1초 안에 반영된다", async () => {
    fake.put("메모/공유.md", "공유\n\n본문");
    await boot();
    await click(row("공유"));
    await sleep(300);
    const sticky = new NoteSession("메모/공유.md", "공유\n\n본문");
    sticky.syncName = false;
    sticky.edit("공유\n\n본문 스티키");
    await sleep(1000);
    sticky.close();
    expect(editorText()).toContain("본문 스티키");
  });
});

describe("고정·꺼내기는 입력 중인 본문을 지우지 않는다", () => {
  it("입력 직후 ⌘⇧P(고정) → 본문과 pinned 둘 다 남는다", async () => {
    fake.put("메모/메모.md", "메모");
    await boot();
    await click(row("메모"));
    await sleep(200);
    await typeAtEnd(" 입력");
    await menu("toggle-pin");
    await sleep(1200);
    const c = [...fake.files.values()][0].content;
    expect(c).toBe("---\npinned: true\n---\n메모 입력");
  });

  // BUG-28: popOut은 flushAll() 전에 받은 경로를 그대로 쓴다. flush가 제목에 맞춰 파일 이름을 바꾸면 옛 경로를 읽다가 실패한다
  it("BUG-28: 제목 입력 직후(0.5초 안) ⌘⇧S → 입력이 저장되고 스티키로 꺼내져야 한다", async () => {
    fake.put("메모/메모.md", "메모");
    await boot();
    await click(row("메모"));
    await sleep(200);
    await typeAtEnd(" 입력");
    await menu("pop-out");
    await sleep(1200);
    // 실제: 알림 "Error: No such file or directory (os error 2)", 파일에는 sticky가 붙지 않고 스티키도 열리지 않는다
    const [path, f] = [...fake.files.entries()][0];
    expect(f.content).toMatch(/^---\nsticky: \{ color: yellow, x: null, y: null, w: 280, h: 280, onTop: false, open: true \}\n---\n메모 입력$/);
    expect(fake.openStickies.has(path)).toBe(true);
  });

  it("입력하고 0.5초 넘게 기다린 뒤 ⌘⇧S → 정상으로 꺼내진다 (대조군)", async () => {
    fake.put("메모/메모.md", "메모");
    await boot();
    await click(row("메모"));
    await sleep(200);
    await typeAtEnd(" 입력");
    await sleep(900);
    await menu("pop-out");
    await sleep(800);
    const [path, f] = [...fake.files.entries()][0];
    expect(f.content).toMatch(/^---\nsticky: \{ color: yellow, x: null, y: null, w: 280, h: 280, onTop: false, open: true \}\n---\n메모 입력$/);
    expect(fake.openStickies.has(path)).toBe(true);
  });
});

describe("BUG-19 재검증: UTF-8이 아닌 파일", () => {
  it("목록에 보이고, 열면 안내가 뜬다", async () => {
    fake.put("메모/옛메모.md", "", { notUtf8: true });
    await boot();
    expect(rowTitles()).toContain("새로운 메모");
    expect(document.querySelector(".note-preview")?.textContent).toBe("지원하지 않는 인코딩");
    await click(row("새로운 메모"));
    await sleep(300);
    expect(document.querySelector(".editor-empty")?.textContent).toContain("UTF-8이 아닌 인코딩");
  });
});

describe("FR-24 설정: 직접 입력 글꼴", () => {
  // BUG-27: Rust set_prefs가 customFont를 trim해 prefs-changed로 돌려주고, App이 그 값으로 입력 칸을 덮어써 끝 공백이 사라진다
  it("BUG-27: 'Nanum Gothic'처럼 공백이 든 글꼴 이름을 한 글자씩 칠 수 있어야 한다", async () => {
    await boot();
    await menu("settings");
    await sleep(100);
    const custom = [...document.querySelectorAll<HTMLButtonElement>(".segmented button")].find((b) => b.textContent === "직접 입력")!;
    await click(custom);
    await sleep(100);
    const input = () => document.querySelector<HTMLInputElement>(".sheet input.text-field")!;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    for (const ch of "Nanum Gothic") {
      await act(async () => {
        setter.call(input(), input().value + ch);
        input().dispatchEvent(new Event("input", { bubbles: true }));
      });
      await sleep(60); // 사람이 치는 속도(글자 사이 60ms)
    }
    expect(input().value).toBe("Nanum Gothic");
  });
});
