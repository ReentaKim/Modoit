// @vitest-environment jsdom
/**
 * QA v0.2 — "사용자가 아무것도 고치지 않았는데 파일이 다시 쓰이는가" (개발 통합 중 고친 문제의 재검증)
 * 실제 App + EditorPane + ModoitEditor(TipTap)를 가짜 백엔드에 붙여 돌린다.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.setConfig({ testTimeout: 30_000 });
import { fake } from "./fakeBackend";
import { activeTitle, click, createElement, editor, editorText, mount, row, sleep, touchEditor, typeAtEnd, unmount } from "./harness";

vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: async () => null, ask: async () => true }));

const { App } = await import("../app/App");

const NOTES: Record<string, string> = {
  "메모/제목끝.md": "제목끝\n\n본문\n\n# 끝 제목",
  "메모/표.md": "표\n\n| a | b |\n|---|---|\n| 1 | 2 |",
  "메모/이미지.md": "이미지\n\n![](../attachments/a.png)",
  "메모/체크.md": "체크\n\n- [ ] 우유\n- [x] 빵",
  "메모/외부HTML.md": "외부HTML\n\n<div>가운데</div>\n\n- [ ] 읽기 전용 체크",
  "메모/고정.md":
    "---\npinned: true\nsticky: {color: pink, x: 10, y: 10, w: 260, h: 260, onTop: false, open: false}\n---\n고정\n\n- 항목",
  "메모/코드.md": "코드\n\n```js\nconst a = 1;\n```",
  "메모/인용.md": "인용\n\n> 인용문",
  "메모/CRLF.md": "CRLF\r\n\r\n본문\r\n",
};

beforeEach(async () => {
  fake.reset();
  for (const [p, c] of Object.entries(NOTES)) fake.put(p, c);
  await mount(createElement(App));
  await sleep(300);
});
afterEach(unmount);

const snapshot = () => JSON.stringify([...fake.files.entries()].map(([p, f]) => [p, f.content]));

describe("열기·전환·커서 이동만으로는 파일을 쓰지 않는다", () => {
  it("모든 메모를 차례로 열고, 편집기 안을 누르고, 다른 메모로 넘어가도 쓰기 명령이 없다", async () => {
    const before = snapshot();
    for (const title of ["제목끝", "표", "이미지", "체크", "외부HTML", "고정", "코드", "인용", "CRLF"]) {
      await click(row(title));
      await sleep(150);
      expect(activeTitle()).toBe(title);
      await touchEditor(); // 끝 빈 문단(TrailingNode)이 붙는 선택 변경
      await sleep(700); // 저장 지연(500ms)보다 길게
    }
    await click(row("제목끝"));
    await sleep(800);
    expect(fake.writes()).toEqual([]);
    expect(snapshot()).toBe(before);
  });

  it("읽기 전용(FR-43) 메모의 체크박스를 눌러도 쓰지 않고 체크도 바뀌지 않는다", async () => {
    await click(row("외부HTML"));
    await sleep(200);
    expect(document.querySelector(".banner")?.textContent).toContain("읽기 전용");
    const cb = document.querySelector<HTMLInputElement>(".ProseMirror input[type=checkbox]")!;
    await click(cb);
    await sleep(800);
    expect(cb.checked).toBe(false);
    expect(fake.writes()).toEqual([]);
  });

  it("편집 가능한 메모의 체크박스를 누르면 그 변경만 저장된다 (대조군)", async () => {
    await click(row("체크"));
    await sleep(200);
    const cb = document.querySelector<HTMLInputElement>(".ProseMirror input[type=checkbox]")!;
    await click(cb);
    await sleep(800);
    expect(fake.callsOf("write_note")).toHaveLength(1);
    // 관찰(OBS-2): 목록·제목·표 등으로 끝나는 메모는 첫 편집 때 끝 빈 문단이 빈 줄 두 개로 저장된다(한 번만, 누적 안 됨)
    expect(fake.files.get("메모/체크.md")!.content).toBe("체크\n\n- [x] 우유\n- [x] 빵\n\n");
  });

  it("외부 변경을 다시 읽어도 쓰지 않는다", async () => {
    await click(row("체크"));
    await sleep(200);
    fake.externalWrite("메모/체크.md", "체크\n\n- [ ] 우유\n- [ ] 다른 앱에서 추가");
    await sleep(600);
    expect(editorText()).toContain("다른 앱에서 추가");
    await touchEditor();
    await sleep(800);
    expect(fake.writes()).toEqual([]);
  });

  it("이미지가 든 메모를 열면 쓰지 않고, 이미지는 저장 폴더 기준 절대 경로로 보인다", async () => {
    await click(row("이미지"));
    await sleep(300);
    const img = document.querySelector<HTMLImageElement>(".ProseMirror img")!;
    expect(decodeURIComponent(img.getAttribute("src")!)).toBe("asset://localhost//v/attachments/a.png");
    expect(img.getAttribute("data-src")).toBe("../attachments/a.png");
    await sleep(800);
    expect(fake.writes()).toEqual([]);
  });

  it("frontmatter가 있는 메모를 편집하면 본문만 바뀌고 frontmatter는 그대로다 (NFR-09)", async () => {
    await click(row("고정"));
    await sleep(200);
    await typeAtEnd("!");
    await sleep(900);
    const c = fake.files.get("메모/고정.md")!.content;
    expect(c.startsWith(NOTES["메모/고정.md"].split("고정\n")[0])).toBe(true);
    expect(c).toContain("- 항목!");
  });

  it("편집기 인스턴스는 선택 변경 뒤 끝 빈 문단이 붙은 상태다 (위 테스트들이 실제로 그 경로를 지났는지 확인)", async () => {
    await click(row("제목끝"));
    await sleep(200);
    await touchEditor();
    expect(editor().state.doc.lastChild?.type.name).toBe("paragraph");
  });
});
