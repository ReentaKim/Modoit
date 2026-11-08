// @vitest-environment jsdom
/**
 * QA v0.2 — 편집기 기능을 실제 ModoitEditor(React + TipTap)로 확인한다.
 * FR-34 `/` 메뉴(플러그인 경로 그대로: 입력 → 메뉴 → 키보드), FR-32 붙여넣기 이미지, FR-14/BUG-06 Tab.
 */
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Slice } from "@tiptap/pm/model";
import { fake } from "./fakeBackend";
import { createElement, editor, mount, sleep, unmount } from "./harness";

vi.setConfig({ testTimeout: 20_000 });
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);

const { ModoitEditor } = await import("../editor/ModoitEditor");

let changes: string[] = [];
let errors: string[] = [];

beforeEach(async () => {
  fake.reset();
  changes = [];
  errors = [];
  await mount(
    createElement(ModoitEditor, {
      initial: "",
      onChange: (m: string) => changes.push(m),
      media: { vault: "/v", notePath: () => "업무/a.md", onError: (e: string) => errors.push(e) },
    }),
  );
});
afterEach(unmount);

/** 한 글자씩 입력 규칙·제안 플러그인을 태워 친다 */
async function type(text: string) {
  for (const ch of text) {
    await act(async () => {
      const ed = editor();
      const { from, to } = ed.state.selection;
      const handled = ed.view.someProp("handleTextInput", (f) => f(ed.view, from, to, ch, () => ed.state.tr.insertText(ch, from, to)));
      if (!handled) ed.view.dispatch(ed.state.tr.insertText(ch, from, to));
    });
  }
  await sleep(20);
}

async function key(k: string) {
  await act(async () => {
    const ed = editor();
    const ev = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
    const handled = ed.view.someProp("handleKeyDown", (f) => f(ed.view, ev));
    if (!handled && k === "Enter") ed.commands.enter();
  });
  await sleep(20);
}

const menuItems = () => [...document.querySelectorAll(".slash-menu .slash-label")].map((e) => e.textContent);
const md = () => editor().getMarkdown().replace(/\n+$/, "");

describe("FR-34 `/` 명령 메뉴", () => {
  it("빈 줄에서 / → 12개 항목(v0.3 토글 추가), '/체크'로 걸러 Enter → 체크박스, '/체크' 글자는 지워진다", async () => {
    await type("/");
    expect(menuItems()).toHaveLength(12);
    await type("체크");
    expect(menuItems()).toEqual(["체크박스"]);
    await key("Enter");
    await type("우유");
    expect(md()).toBe("- [ ] 우유");
    expect(document.querySelector(".slash-menu")).toBeNull();
  });

  it("↓ 로 고르고 Enter: '/제목' → ↓ → 제목 2", async () => {
    await type("/제목");
    expect(menuItems()).toEqual(["제목 1", "제목 2", "제목 3"]);
    await key("ArrowDown");
    await key("Enter");
    await type("소제목");
    expect(md()).toBe("## 소제목");
  });

  it("공백 뒤에서는 뜨고, 글자 바로 뒤(a/b, 주소)에서는 뜨지 않는다", async () => {
    await type("가격 /");
    expect(menuItems().length).toBeGreaterThan(0);
    await key("Escape");
    await type(" 1/2 https://x.com/a");
    expect(document.querySelector(".slash-menu")).toBeNull();
  });

  it("Esc로 닫은 뒤 Enter는 명령을 실행하지 않고 줄만 바꾼다", async () => {
    await type("/usr");
    await key("Escape");
    expect(document.querySelector(".slash-menu")).toBeNull();
    await key("Enter");
    await type("다음 줄");
    expect(md()).toBe("/usr\n\n다음 줄");
  });

  it("코드 블록 안에서는 뜨지 않는다", async () => {
    await act(async () => void editor().commands.setCodeBlock());
    await type("a /b");
    expect(document.querySelector(".slash-menu")).toBeNull();
  });
});

describe("FR-32 붙여넣기 이미지", () => {
  const paste = (files: File[]) =>
    act(async () => {
      const ed = editor();
      const ev = { clipboardData: { files }, preventDefault: () => {} } as unknown as ClipboardEvent;
      ed.view.someProp("handlePaste", (f) => f(ed.view, ev, Slice.empty));
    });

  it("이미지를 붙여넣으면 save_attachment(메모 경로, 이름, base64)를 부르고 상대 링크 이미지가 들어간다", async () => {
    await paste([new File([new Uint8Array([137, 80, 78, 71])], "image.png", { type: "image/png" })]);
    await sleep(100);
    const call = fake.callsOf("save_attachment")[0];
    expect(call.args.notePath).toBe("업무/a.md");
    expect(call.args.fileName).toBe("image.png");
    expect(call.args.dataBase64).toBe("iVBORw==");
    expect(md()).toBe("![](../attachments/20261107-120000-abcd.png)");
    expect(changes[changes.length - 1]).toContain("![](../attachments/20261107-120000-abcd.png)");
  });

  it("지원하지 않는 형식(svg)과 20MB 초과는 알리고 넣지 않는다", async () => {
    await paste([new File(["<svg/>"], "a.svg", { type: "image/svg+xml" })]);
    const big = new File([new Uint8Array(1)], "big.png", { type: "image/png" });
    Object.defineProperty(big, "size", { value: 20 * 1024 * 1024 + 1 });
    await paste([big]);
    await sleep(50);
    expect(fake.callsOf("save_attachment")).toEqual([]);
    // svg는 image/ 로 시작하지만 IMAGE_TYPES에 없어 안내, 20MB 초과도 안내
    expect(errors).toHaveLength(2);
    expect(md()).toBe("");
  });

  it("이미지가 아닌 붙여넣기는 가로채지 않는다", async () => {
    let handled: boolean | void | undefined;
    await act(async () => {
      const ed = editor();
      const ev = { clipboardData: { files: [], getData: () => "", types: [] }, preventDefault: () => {} } as unknown as ClipboardEvent;
      handled = ed.view.someProp("handlePaste", (f) => f(ed.view, ev, Slice.empty));
    });
    expect(handled).toBeFalsy();
  });
});
