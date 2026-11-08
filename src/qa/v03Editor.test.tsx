// @vitest-environment jsdom
/**
 * QA v0.3 — 편집기 신규 기능: 토글(FR-48, NFR-14), 화살표(FR-49), `|` 인용(FR-50), 편집 가능 판정(BUG-29 수정).
 * 실제 ModoitEditor(React + TipTap) 또는 buildExtensions 편집기로 확인한다.
 * it.fails 는 v0.3 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Editor, type JSONContent } from "@tiptap/core";
import { fake } from "./fakeBackend";
import { createElement, editor, mount, sleep, unmount } from "./harness";
import { buildExtensions } from "../editor/extensions";
import { tidyMarkdown } from "../lib/markdownSafety";
import { splitDetails } from "../editor/toggle";

vi.setConfig({ testTimeout: 20_000 });
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);

const { ModoitEditor } = await import("../editor/ModoitEditor");
const { unsupportedFeatures } = await import("../editor/editability");

afterEach(unmount);

let changes: string[] = [];
async function mountEditor(initial = "") {
  fake.reset();
  changes = [];
  await mount(createElement(ModoitEditor, { initial, onChange: (m: string) => changes.push(m) }));
}

async function type(text: string) {
  for (const ch of text) {
    await act(async () => {
      const ed = editor();
      const { from, to } = ed.state.selection;
      const handled = ed.view.someProp("handleTextInput", (f) => f(ed.view, from, to, ch, () => ed.state.tr.insertText(ch, from, to)));
      if (!handled) ed.view.dispatch(ed.state.tr.insertText(ch, from, to));
    });
  }
}

async function key(k: string) {
  await act(async () => {
    const ed = editor();
    const ev = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
    ed.view.someProp("handleKeyDown", (f) => f(ed.view, ev));
  });
}

const md = () => tidyMarkdown(editor().getMarkdown()).replace(/\n+$/, "");

/** 편집기 밖에서 Markdown 열기 → 저장 → 다시 열기 */
const mk = (src: string) => new Editor({ element: document.createElement("div"), extensions: buildExtensions(), content: src, contentType: "markdown" });
function save(content: JSONContent[]) {
  const ed = new Editor({ element: document.createElement("div"), extensions: buildExtensions() });
  ed.commands.setContent({ type: "doc", content });
  const out = tidyMarkdown(ed.getMarkdown());
  ed.destroy();
  return out;
}
const json = (src: string) => {
  const ed = mk(src);
  const j = JSON.stringify(ed.getJSON());
  ed.destroy();
  return j;
};

const D = (summary: string, inner: string) => `<details>\n<summary>${summary}</summary>\n\n${inner}${inner ? "\n\n" : ""}</details>`;

describe("FR-48 토글 입력·저장", () => {
  it("줄 맨 앞 '> ' → 토글, 제목·내용을 쓰면 계약서 형식(<details>/<summary>/빈 줄)으로 저장", async () => {
    await mountEditor();
    await type("> ");
    expect(editor().state.doc.firstChild?.type.name).toBe("details");
    await type("장보기");
    await act(async () => {
      const ed = editor();
      let pos = -1;
      ed.state.doc.descendants((n, p) => {
        if (n.type.name === "detailsContent") pos = p + 2;
      });
      ed.commands.setTextSelection(pos);
    });
    await type("우유");
    expect(md()).toBe(D("장보기", "우유"));
  });

  it("'/토글' 메뉴로도 만든다", async () => {
    await mountEditor();
    await type("/토글");
    expect([...document.querySelectorAll(".slash-menu .slash-label")].map((e) => e.textContent)).toEqual(["토글"]);
    await key("Enter");
    expect(editor().state.doc.firstChild?.type.name).toBe("details");
  });

  it("열 때는 접힌 상태이고, 삼각형 버튼으로 펴고 접는다 (상태는 저장하지 않음)", async () => {
    await mountEditor(D("제목", "내용"));
    const content = () => document.querySelector<HTMLElement>('.toggle [data-type="detailsContent"]')!;
    expect(content().hasAttribute("hidden")).toBe(true);
    await act(async () => document.querySelector<HTMLButtonElement>(".toggle > button")!.click());
    expect(content().hasAttribute("hidden")).toBe(false);
    await sleep(600);
    expect(changes).toEqual([]); // 펴기·접기는 파일을 바꾸지 않는다
  });

  it.each([
    ["기본", D("제목", "내용")],
    ["빈 내용", D("제목", "")],
    ["빈 제목", D("", "내용")],
    ["2단 중첩", D("바깥", "앞\n\n" + D("안", "깊은 내용"))],
    ["3단 중첩", D("1", D("2", D("3", "바닥")))],
    ["목록·체크박스·번호", D("목록", "- a\n- [ ] b\n\n1. c")],
    ["코드 블록", D("코드", "```js\nconst a = 1;\n```")],
    ["표", D("표", "| a | b |\n| --- | --- |\n| 1 | 2 |")],
    ["이미지", D("그림", "![](../attachments/a.png)")],
    ["인용", D("인용", "> 인용문")],
    ["제목 서식·특수 문자", D("**굵게** `코드` R&D a < b", "내용")],
    ["토글 두 개 연달아", D("하나", "1") + "\n\n" + D("둘", "2")],
  ])("왕복해도 구조가 같다: %s", (_n, src) => {
    expect(unsupportedFeatures(src)).toEqual([]);
    const a = mk(src);
    const saved = tidyMarkdown(a.getMarkdown());
    a.destroy();
    expect(json(saved)).toBe(json(src));
  });

  it.each([
    ["한 줄 <details><summary>", "<details><summary>한 줄</summary>\n\n내용\n\n</details>"],
    ["속성 있는 <details class>", '<details class="x">\n<summary>s</summary>\n\n내용\n\n</details>'],
    ["</details> 뒤에 글", "<details>\n<summary>s</summary>\n\n내용\n\n</details>뒤 글"],
    ["안쪽 HTML", "<details>\n<summary>s</summary>\n\n<b>굵게</b>\n\n</details>"],
    ["인용 안의 토글", "> <details>\n> <summary>s</summary>\n>\n> 내용\n>\n> </details>"],
  ])("NFR-14: Modoit 형식이 아닌 <details>는 읽기 전용: %s", (_n, src) => {
    expect(unsupportedFeatures(src).length).toBeGreaterThan(0);
  });

  it("다른 앱 변형 중 Modoit 형식으로 읽는 것: open 속성·대문자·들여쓴 태그 (저장 시 정규화, 내용 보존)", () => {
    for (const src of [
      "<details open>\n<summary>s</summary>\n\n내용\n\n</details>",
      "<DETAILS>\n<SUMMARY>s</SUMMARY>\n\n내용\n\n</DETAILS>",
      "<details>\n  <summary>s</summary>\n\n  내용\n\n</details>",
    ]) {
      expect(unsupportedFeatures(src)).toEqual([]);
      const a = mk(src);
      const saved = tidyMarkdown(a.getMarkdown());
      a.destroy();
      expect(saved).toBe(D("s", "내용"));
    }
  });

  // BUG-41: splitDetails/detailsEnd가 코드 안의 </details>도 닫는 태그로 센다.
  // 앱에서 토글 안에 `</details>`를 인라인 코드로 쓰고 저장하면, 다시 열 때 토글이 그 자리에서 끝나고(편집 가능 판정도 통과),
  // 다음 저장 때 내용이 토글 밖으로 흩어지고 역슬래시가 붙는다.
  it("BUG-41: 토글 안 인라인 코드 `</details>`를 저장하고 다시 열어도 같은 구조여야 한다", () => {
    const saved = save([
      {
        type: "details",
        content: [
          { type: "detailsSummary", content: [{ type: "text", text: "설명" }] },
          {
            type: "detailsContent",
            content: [
              {
                type: "paragraph",
                content: [
                  { type: "text", text: "닫는 태그는 " },
                  { type: "text", text: "</details>", marks: [{ type: "code" }] },
                  { type: "text", text: " 입니다" },
                ],
              },
            ],
          },
        ],
      },
    ]);
    const again = mk(saved);
    const saved2 = tidyMarkdown(again.getMarkdown());
    again.destroy();
    expect(saved2).toBe(saved);
  });

  it("BUG-41: 토글 안 코드 블록에 '</details>' 한 줄이 있는 문서는 읽기 전용이거나 그대로 보존되어야 한다", () => {
    const src = D("HTML 예시", "```html\n</details>\n```\n\n뒤 내용");
    const editable = unsupportedFeatures(src).length === 0;
    const a = mk(src);
    const saved = tidyMarkdown(a.getMarkdown());
    a.destroy();
    expect(!editable || saved.replace(/\n+$/, "") === src).toBe(true);
  });

  // BUG-46: 다른 앱의 불완전한 <details>는 stripToggleTags가 태그 줄을 걷어 내 검사를 통과하고(편집 가능),
  // 편집기는 원문과 다르게 읽으므로 첫 저장 때 구조가 바뀌거나 태그가 사라진다. 왕복 비교는 첫 해석 이후만 비교해 잡지 못한다.
  it.each([
    ["닫는 태그 없음 → 내용이 토글 밖으로 나가고 </details>가 덧붙음", "<details>\n<summary>제목</summary>\n\n닫는 태그 없음"],
    ["summary 없음 → 내용이 토글 밖으로 나감", "<details>\n\n요약 없음\n\n</details>"],
    ["짝 없는 </details> → 저장 때 사라짐", "글\n\n</details>"],
    ["토글 안 들여쓴 코드 → 문단이 됨", "<details>\n<summary>s</summary>\n\n    들여쓴 코드\n\n</details>"],
  ])("BUG-46: %s — 읽기 전용이거나 그대로 보존되어야 한다", (_n, src) => {
    const editable = unsupportedFeatures(src).length === 0;
    const a = mk(src);
    const saved = tidyMarkdown(a.getMarkdown()).replace(/\n+$/, "");
    a.destroy();
    // v0.3 수정: 들여쓴 코드는 코드 블록으로 읽고 펜스로 저장한다 — 형식 정규화(OBS-1, PM: 의미 보존 기준)는 허용
    const fenced = src.replace("    들여쓴 코드", "```\n들여쓴 코드\n```");
    expect(!editable || saved === src || saved === fenced).toBe(true);
  });

  it("splitDetails: 닫는 태그 없는 <details>는 토글로 읽지 않는다", () => {
    expect(splitDetails("<details>\n<summary>s</summary>\n\n내용")).toBeNull();
  });
});

describe("FR-49 화살표", () => {
  it("'->' → '→', '<-' → '←'", async () => {
    await mountEditor();
    await type("a -> b <- c");
    expect(md()).toBe("a → b ← c");
  });

  it("바뀐 직후 Backspace → 원래 글자", async () => {
    await mountEditor();
    await type("a ->");
    expect(md()).toBe("a →");
    await key("Backspace");
    expect(md()).toBe("a ->");
  });

  it("코드 블록·인라인 코드 안에서는 바꾸지 않는다", async () => {
    await mountEditor();
    await act(async () => void editor().commands.setCodeBlock());
    await type("x -> y");
    expect(editor().state.doc.firstChild?.textContent).toBe("x -> y");
    await mountEditor("`abc` 뒤");
    await act(async () => void editor().commands.setTextSelection(2)); // 인라인 코드 안 (a와 b 사이)
    await type("->");
    expect(editor().state.doc.firstChild?.textContent).toBe("a->bc 뒤");
  });
});

describe("FR-50 인용 '|'", () => {
  it("줄 맨 앞 '| ' → 인용, 파일에는 표준 '> '로 저장", async () => {
    await mountEditor();
    await type("| 인용문");
    expect(editor().state.doc.firstChild?.type.name).toBe("blockquote");
    expect(md()).toBe("> 인용문");
  });

  it("'> '로 저장된 인용은 다시 열면 인용으로 보인다 (토글이 아님)", async () => {
    await mountEditor("> 인용문");
    expect(editor().state.doc.firstChild?.type.name).toBe("blockquote");
  });

  it("/ 메뉴의 인용 표기는 '|', 토글 표기는 '>'", async () => {
    const { SLASH_ITEMS } = await import("../editor/slash");
    expect(SLASH_ITEMS.find((i) => i.id === "quote")?.hint).toBe("|");
    expect(SLASH_ITEMS.find((i) => i.id === "toggle")?.hint).toBe(">");
  });
});

describe("BUG-29 수정 재검증: 편집 가능 판정(unsupportedFeatures)", () => {
  it.each([
    ["![](<my pic.png>)"],
    ["[파일](<my file.md>)"],
    ["[![](a.png)](https://x.com)"],
    ["````\n```\n````"],
    ["a&nbsp;b &copy; 2026"],
    ["<div>x</div>"],
  ])("읽기 전용: %j", (src) => {
    expect(unsupportedFeatures(src).length).toBeGreaterThan(0);
  });

  it.each([["* 별표\n* 둘"], ["__굵게__"], ["| a |\n|:-|\n| 1 |"], ["a &amp; b"], ["CRLF\r\n줄"]])("형식만 바뀌는 문서는 편집 가능: %j", (src) => {
    expect(unsupportedFeatures(src)).toEqual([]);
  });
});
