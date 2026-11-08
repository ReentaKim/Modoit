import { describe, expect, it } from "vitest";
import { encodeMarkdownText, findUnsupported, tidyMarkdown } from "./markdownSafety";
import { DEFAULT_STICKY, joinNote, readMeta, splitNote, writeMeta } from "./frontmatter";
import { addSeparator, displaySequence, flattenTree, itemKey, reorder } from "./sidebar";
import { movedPath, type FolderNode, type Layout } from "./api";

describe("encodeMarkdownText (BUG-03, BUG-01)", () => {
  it("일반 글자는 바꾸지 않는다", () => {
    expect(encodeMarkdownText("R&D 와 a < b", false)).toBe("R&D 와 a < b");
    expect(encodeMarkdownText("snake_case [[위키]] 5 > 3", false)).toBe("snake_case [[위키]] 5 > 3");
  });
  it("다시 읽을 때 문법이 되는 것만 이스케이프", () => {
    expect(encodeMarkdownText("*별* `코드` _강조_", false)).toBe("\\*별\\* \\`코드\\` \\_강조\\_");
    expect(encodeMarkdownText("[글](주소)", false)).toBe("\\[글](주소)");
    expect(encodeMarkdownText("<div> &amp;", false)).toBe("&lt;div> &amp;amp;");
    expect(encodeMarkdownText("~~취소~~", false)).toBe("\\~\\~취소\\~\\~");
  });
  it("줄 맨 앞의 블록 문법", () => {
    expect(encodeMarkdownText("# 아님", true)).toBe("\\# 아님");
    expect(encodeMarkdownText("- 아님", true)).toBe("\\- 아님");
    expect(encodeMarkdownText("1. 아님", true)).toBe("1\\. 아님");
    expect(encodeMarkdownText("> 아님", true)).toBe("\\> 아님");
    expect(encodeMarkdownText("#해시태그", true)).toBe("#해시태그");
  });
});

describe("findUnsupported (FR-43)", () => {
  it("지원하는 서식만 있으면 빈 목록", () => {
    const md = "# 제목\n\n- [ ] 할 일\n  - 하위\n\n> 인용\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![그림](a.png) **굵게** `코드` ~~취소~~ [링크](http://x)\n\n```js\nx\n```\n\n---\n";
    expect(findUnsupported(md)).toEqual([]);
  });
  it("HTML, 참조 정의, 밑줄식 제목을 찾는다", () => {
    expect(findUnsupported("<div>x</div>")).toContain("HTML");
    expect(findUnsupported("글 <b>굵게</b>")).toContain("HTML");
    expect(findUnsupported("[a][1]\n\n[1]: http://x")).toContain("참조 링크 정의");
    expect(findUnsupported("제목\n===")).toContain("밑줄식 제목");
  });
});

describe("frontmatter (NFR-09)", () => {
  const src = "---\ntags: [a, b] # 내 주석\ntitle: 원래\n---\n본문\n";
  it("구분선으로 시작하는 본문은 frontmatter가 아니다 (Rust와 같은 판정)", () => {
    const hr = "---\n그냥 글\n---\n본문";
    expect(splitNote(hr)).toEqual({ front: null, body: hr });
    expect(splitNote("---\n---\n본문").front).toBe("");
    expect(splitNote("---\nkey: [깨진\n---\n본문").body).toBe("본문");
  });
  it("나누고 합치면 원본 그대로", () => {
    expect(joinNote(splitNote(src))).toBe(src);
    expect(splitNote("본문만")).toEqual({ front: null, body: "본문만" });
  });
  it("sticky를 쓰면 사용자 키·주석은 보존", () => {
    const front = writeMeta(splitNote(src).front, { sticky: { ...DEFAULT_STICKY, x: 10.4, y: 20 } })!;
    expect(front).toContain("tags: [ a, b ] # 내 주석");
    expect(front).toContain("title: 원래");
    expect(front).toMatch(/sticky: \{ color: yellow, x: 10, y: 20, w: 280, h: 280, onTop: false, open: true \}/);
    const meta = readMeta(front);
    expect(meta.sticky).toEqual({ ...DEFAULT_STICKY, x: 10, y: 20 });
  });
  it("pinned 켜고 끄기, 비면 frontmatter 제거", () => {
    const on = writeMeta(null, { pinned: true });
    expect(readMeta(on).pinned).toBe(true);
    expect(writeMeta(on, { pinned: false })).toBeNull();
  });
  it("v0.1 스티키 형식을 읽고, 새 형식으로 바꾼다 (NFR-08)", () => {
    const legacy = "color: pink\nx: 100\ny: 50\nw: 240\nh: 220\nonTop: false\nopen: false\n";
    const m = readMeta(legacy);
    expect(m.legacy).toBe(true);
    expect(m.sticky?.color).toBe("pink");
    const next = writeMeta(legacy, { sticky: { ...m.sticky!, open: true } })!;
    expect(next).not.toMatch(/^color:/m);
    expect(readMeta(next).sticky?.open).toBe(true);
  });
  it("깨진 YAML은 건드리지 않는다", () => {
    expect(writeMeta("a: [1, 2\n", { pinned: true })).toBe("a: [1, 2\n");
  });
});

const F = (path: string, modified: number, children: FolderNode[] = []): FolderNode => ({
  path,
  name: path.split("/").pop()!,
  modified,
  children,
});

describe("사이드바 순서 (FR-27~29)", () => {
  const folders = [F("가", 3), F("나", 1, [F("나/x", 1), F("나/y", 9)]), F("다", 2)];
  const custom: Layout = { sort: "custom", order: { "": ["다", "sep:1", "가"] } };

  it("직접 정렬: layout 순서 먼저, 나머지는 이름순", () => {
    expect(displaySequence("", folders, custom).map(itemKey)).toEqual(["다", "sep:1", "가", "나"]);
  });
  it("이름순·최신순은 구분선 구역 안에서만", () => {
    expect(displaySequence("", folders, { ...custom, sort: "name" }).map(itemKey)).toEqual(["다", "sep:1", "가", "나"]);
    expect(displaySequence("", folders, { ...custom, sort: "recent" }).map(itemKey)).toEqual(["다", "sep:1", "가", "나"]);
    const noSep: Layout = { sort: "recent", order: {} };
    expect(displaySequence("", folders, noSep).map(itemKey)).toEqual(["가", "다", "나"]);
  });
  it("펼침 상태 반영", () => {
    const rows = flattenTree(folders, { sort: "name", order: {} }, new Set(["나"]));
    expect(rows.map((r) => (r.kind === "sep" ? r.id : r.path))).toEqual(["가", "나", "다"]);
    const open = flattenTree(folders, { sort: "name", order: {} }, new Set());
    expect(open.map((r) => (r.kind === "sep" ? r.id : r.path))).toEqual(["가", "나", "나/x", "나/y", "다"]);
  });
  it("순서 바꾸기, 정렬 모드였다면 화면 순서를 고정하고 직접 정렬로", () => {
    const l = reorder(folders, custom, "", "나", "다");
    expect(l.order[""]).toEqual(["나", "다", "sep:1", "가"]);
    const fromName = reorder(folders, { sort: "recent", order: {} }, "나", "x", "y");
    expect(fromName.sort).toBe("custom");
    expect(fromName.order[""]).toEqual(["가", "다", "나"]);
    expect(fromName.order["나"]).toEqual(["x", "y"]);
    // 다른 폴더 '안'으로만 옮긴 경우(beforeKey null)는 정렬 방식을 그대로 둔다 (BUG-33)
    const into = { sort: "recent" as const, order: {} };
    expect(reorder(folders, into, "나", "x", null, true)).toBe(into);
  });
  it("구분선 추가", () => {
    const l = addSeparator(folders, { sort: "custom", order: {} }, "", "가");
    expect(l.order[""][0]).toBe("가");
    expect(l.order[""][1]).toMatch(/^sep:/);
  });
  it("이동 이벤트 경로 계산", () => {
    expect(movedPath("a/b.md", { from: "a/b.md", to: "c/b.md", isDir: false })).toBe("c/b.md");
    expect(movedPath("a/x/b.md", { from: "a", to: "z/a", isDir: true })).toBe("z/a/x/b.md");
    expect(movedPath("ab/b.md", { from: "a", to: "z", isDir: true })).toBeNull();
  });
});

describe("tidyMarkdown", () => {
  it("표 앞뒤 빈 줄을 하나로", () => {
    const raw = "회의록\n\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n\n끝";
    expect(tidyMarkdown(raw)).toBe("회의록\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n끝");
    expect(tidyMarkdown("줄1\n\n\n\n줄2")).toBe("줄1\n\n\n\n줄2");
    expect(tidyMarkdown("끝\n\n&nbsp;\n\n&nbsp;")).toBe("끝");
  });
});

describe("mergeBodies (BUG-26)", async () => {
  const { mergeBodies } = await import("./merge");
  it("서로 다른 줄을 고치면 둘 다 반영", () => {
    expect(mergeBodies("a\nb\nc", "A\nb\nc", "a\nb\nC")).toBe("A\nb\nC");
  });
  it("같은 줄을 고치면 둘 다 남긴다(내 것 먼저)", () => {
    expect(mergeBodies("제목\n\n본문", "제목\n\n본문 메인", "제목\n\n본문 스티키")).toBe("제목\n\n본문 메인\n\n본문 스티키");
  });
  it("한쪽만 바뀌었으면 그쪽", () => {
    expect(mergeBodies("x", "x", "y")).toBe("y");
    expect(mergeBodies("x", "y", "x")).toBe("y");
  });
});

describe("토글 태그는 지원 서식 (NFR-14)", async () => {
  const { findUnsupported } = await import("./markdownSafety");
  it("Modoit 형식 <details>는 통과, 다른 HTML은 그대로 비지원", () => {
    expect(findUnsupported("<details>\n<summary>제목</summary>\n\n내용\n\n</details>")).toEqual([]);
    expect(findUnsupported("<details><summary>한 줄</summary>내용</details>")).toEqual(["HTML"]);
    expect(findUnsupported("<details>\n<summary>t</summary>\n\n<div>x</div>\n\n</details>")).toEqual(["HTML"]);
  });
});
