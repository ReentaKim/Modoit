// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { Editor } from "@tiptap/core";
import { buildExtensions, INDENT } from "./extensions";

let editor: Editor | null = null;
afterEach(() => {
  editor?.destroy();
  editor = null;
});

function make(md = "") {
  editor = new Editor({
    element: document.createElement("div"),
    extensions: buildExtensions(),
    content: md,
    contentType: "markdown",
  });
  return editor;
}

/** 사용자가 한 글자씩 치는 것처럼 입력 규칙(input rule)을 태운다 */
function type(ed: Editor, text: string) {
  for (const ch of text) {
    const { from, to } = ed.state.selection;
    const handled = ed.view.someProp("handleTextInput", (f) =>
      f(ed.view, from, to, ch, () => ed.state.tr.insertText(ch, from, to)),
    );
    if (!handled) ed.view.dispatch(ed.state.tr.insertText(ch, from, to));
  }
}

function press(ed: Editor, key: string, shift = false) {
  const ev = new KeyboardEvent("keydown", { key, shiftKey: shift, bubbles: true });
  ed.view.someProp("handleKeyDown", (f) => f(ed.view, ev));
}

const md = (ed: Editor) => ed.getMarkdown().replace(/^\n+|\n+$/g, "");

describe("Notion식 입력 단축키", () => {
  it("'- ' → 점 목록", () => {
    const ed = make();
    type(ed, "- 우유");
    expect(ed.isActive("bulletList")).toBe(true);
    expect(md(ed)).toBe("- 우유");
  });

  it("'[ ] ' 와 '[] ' → 체크박스", () => {
    const ed = make();
    type(ed, "[ ] 할 일");
    expect(ed.isActive("taskItem")).toBe(true);
    expect(md(ed)).toBe("- [ ] 할 일");

    const ed2 = make();
    type(ed2, "[] 다른 일");
    expect(md(ed2)).toBe("- [ ] 다른 일");
  });

  it("'[x] ' → 체크된 체크박스", () => {
    const ed = make();
    type(ed, "[x] 끝난 일");
    expect(md(ed)).toBe("- [x] 끝난 일");
  });

  it("'1. ', '# ', '| '(v0.3 인용) 도 동작", () => {
    const ed = make();
    type(ed, "1. 첫째");
    expect(md(ed)).toBe("1. 첫째");
    const h = make();
    type(h, "# 제목");
    expect(md(h)).toBe("# 제목");
    const q = make();
    type(q, "| 인용");
    expect(md(q)).toBe("> 인용");
  });

  it("목록 안에서 Tab → 한 단계 들여쓰기, Shift+Tab → 원위치", () => {
    const ed = make("- 상위\n- 하위");
    ed.commands.focus("end");
    press(ed, "Tab");
    expect(md(ed)).toBe("- 상위\n  - 하위");
    press(ed, "Tab", true);
    expect(md(ed)).toBe("- 상위\n- 하위");
  });

  it("체크박스도 Tab으로 하위 항목이 된다", () => {
    const ed = make("- [ ] 프로젝트\n- [ ] 세부 작업");
    ed.commands.focus("end");
    press(ed, "Tab");
    expect(md(ed)).toBe("- [ ] 프로젝트\n  - [ ] 세부 작업");
  });

  it("목록 밖 Tab은 전각 공백 들여쓰기 (코드 블록으로 바뀌지 않음)", () => {
    const ed = make("문단");
    ed.commands.focus("start");
    press(ed, "Tab");
    expect(md(ed)).toBe(`${INDENT}문단`);
    // 다시 읽어도 코드 블록이 아니라 문단이어야 한다
    const again = make(ed.getMarkdown());
    expect(again.isActive("codeBlock")).toBe(false);
    expect(again.getJSON().content?.[0].type).toBe("paragraph");
    press(ed, "Tab", true);
    expect(md(ed)).toBe("문단");
  });
});

describe("Markdown 왕복 변환", () => {
  it("읽고 다시 저장해도 내용이 같다", () => {
    const src = [
      "# 장보기",
      "",
      "- [ ] 우유",
      "  - [x] 저지방",
      "- [ ] 빵",
      "",
      "메모 **굵게** 와 `코드`",
      "",
      "1. 하나",
      "2. 둘",
    ].join("\n");
    const ed = make(src);
    expect(md(ed)).toBe(src);
  });
});

describe("v0.2", () => {
  it("BUG-03: R&D, a < b 는 그대로 저장된다", () => {
    const ed = make();
    type(ed, "R&D 와 a < b, snake_case [[위키]]");
    expect(md(ed)).toBe("R&D 와 a < b, snake_case [[위키]]");
  });

  it("BUG-06: 여러 문단을 선택하고 Tab → 문단마다 들여쓰기, 글은 그대로", () => {
    const ed = make("첫째\n\n둘째");
    ed.commands.selectAll();
    press(ed, "Tab");
    expect(md(ed)).toBe(`${INDENT}첫째\n\n${INDENT}둘째`);
    ed.commands.selectAll();
    press(ed, "Tab", true);
    expect(md(ed)).toBe("첫째\n\n둘째");
  });

  it("이미지 Markdown 왕복 (상대 경로 유지)", () => {
    const src = "메모\n\n![](../attachments/20261107-a1b2.png)";
    const ed = make(src);
    expect(md(ed)).toBe(src);
  });

  it("표 왕복: 내용이 보존된다", () => {
    const ed = make("| a | b |\n|---|---|\n| 1 | 2 |");
    const out = md(ed);
    expect(out).toMatch(/\|\s*a\s*\|\s*b\s*\|/);
    expect(out).toMatch(/\|\s*1\s*\|\s*2\s*\|/);
  });

  it("/ 메뉴 명령: 체크박스", async () => {
    const { SLASH_ITEMS, filterSlash } = await import("./slash");
    expect(filterSlash("체크").map((i) => i.id)).toEqual(["task"]);
    expect(filterSlash("제목").map((i) => i.id)).toEqual(["h1", "h2", "h3"]);
    const ed = make();
    type(ed, "/");
    const item = SLASH_ITEMS.find((i) => i.id === "task")!;
    const end = ed.state.selection.from;
    item.run(ed, { from: end - 1, to: end }, () => {});
    type(ed, "할 일");
    expect(md(ed)).toBe("- [ ] 할 일");
  });
});

describe("열기만 해서는 저장하지 않는다 (v0.2 통합 중 발견)", () => {
  it("선택만 바꿔도 끝 빈 문단이 붙지만, 그 변경은 사용자 변경이 아니다", () => {
    const changes: boolean[] = [];
    editor = new Editor({
      element: document.createElement("div"),
      extensions: buildExtensions(),
      content: "외부 HTML 메모\n\n<div>가운데</div>",
      contentType: "markdown",
      onUpdate: ({ transaction }) => changes.push(transaction.docChanged),
    });
    editor.commands.setTextSelection(1);
    editor.commands.focus("end");
    expect(changes.every((c) => c === false)).toBe(true);
  });
});

describe("체크박스 DOM", () => {
  it("노드 뷰의 li에 data-type=taskItem 이 붙는다 (CSS 선택자)", () => {
    const ed = make("- [ ] 할 일");
    expect(ed.view.dom.querySelector('li[data-type="taskItem"]')).not.toBeNull();
  });
});

describe("v0.3 입력 규칙 (FR-48~50)", () => {
  it("`| ` → 인용, 파일에는 표준 `> `", () => {
    const ed = make();
    type(ed, "| 인용문");
    expect(ed.getJSON().content?.[0]?.type).toBe("blockquote");
    expect(md(ed)).toBe("> 인용문");
  });

  it("`> ` → 토글, 제목을 치고 Enter 뒤 내용", () => {
    const ed = make();
    type(ed, "> ");
    expect(ed.getJSON().content?.[0]?.type).toBe("details");
    type(ed, "토글 제목");
    const out = md(ed);
    expect(out).toContain("<details>\n<summary>토글 제목</summary>");
    expect(out.trim().endsWith("</details>")).toBe(true);
  });

  it("`->` → `→`, `<-` → `←`", () => {
    const ed = make();
    type(ed, "a -> b <- c");
    expect(md(ed)).toBe("a → b ← c");
  });

  it("코드 블록 안에서는 화살표로 바꾸지 않는다", () => {
    const ed = make("```\nx\n```");
    ed.commands.focus("end");
    type(ed, "->");
    expect(md(ed)).toContain("x->");
  });
});

describe("토글 Markdown 왕복 (FR-48)", () => {
  const src = "<details>\n<summary>제목 **굵게**</summary>\n\n- 하나\n- 둘\n\n안쪽 문단\n\n</details>\n\n뒤 문단";
  it("읽으면 토글 노드, 다시 쓰면 같은 글", () => {
    const ed = make(src);
    const j = ed.getJSON().content!;
    expect(j[0]!.type).toBe("details");
    expect(j[0]!.content![0]!.type).toBe("detailsSummary");
    expect(j[0]!.content![1]!.type).toBe("detailsContent");
    expect(md(ed)).toBe(src);
  });

  it("중첩 토글", () => {
    const nested = "<details>\n<summary>바깥</summary>\n\n<details>\n<summary>안쪽</summary>\n\n내용\n\n</details>\n\n</details>";
    const ed = make(nested);
    expect(md(ed)).toBe(nested);
  });
});
