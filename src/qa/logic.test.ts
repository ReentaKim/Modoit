// @vitest-environment jsdom
/**
 * QA v0.2 — 순수 로직 회귀 테스트
 * - frontmatter 판정이 Rust split_frontmatter와 같은가 (기대값은 scratchpad Rust 하네스로 실제 Rust 코드에서 얻은 결과)
 * - FR-43: 편집 가능으로 여는 문서는 왕복해도 의미가 같은가
 * - 이미지 표시 경로(assetUrl)
 * - 사이드바 순서(sidebar.ts)
 * it.fails 로 표시한 케이스는 v0.2 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { describe, expect, it, vi } from "vitest";
import { Editor } from "@tiptap/core";
import { buildExtensions } from "../editor/extensions";
import { findUnsupported, tidyMarkdown } from "../lib/markdownSafety";
import { readMeta, splitNote, writeMeta } from "../lib/frontmatter";
import { reorder, flattenTree } from "../lib/sidebar";
import type { FolderNode, Layout } from "../lib/api";

vi.mock("@tauri-apps/api/core", () => ({ convertFileSrc: (p: string) => p, invoke: async () => null }));
const { assetUrl } = await import("../lib/paths");

// ───────────── frontmatter: TS splitNote ↔ Rust split_frontmatter ─────────────

/** [원문, Rust가 frontmatter로 본 경우 본문] — Rust 하네스 qa_r1 결과에서 TS와 일치한 것 일부 */
const AGREE: Array<[string, string | null]> = [
  ["---\na: 1\n---\nbody", "body"],
  ["---\na: 1\n--- \nbody", "body"],
  ["﻿---\na: 1\n---\nbody", "body"],
  ["---\r\na: 1\r\n---\r\nbody", "body"],
  ["---\n---\nbody", "body"],
  ["---\n제목\n---\n본문", null],
  ["---\n- a\n- b\n---\n", null],
  ["---\nkey: [unclosed\n---\nbody", "body"],
  ["---\n# 주석만\n---\nbody", "body"],
  ["---\nfoo:bar\n---\n", null],
  ["---\n@at: 1\n---\n", null],
  ["---\nfoo: bar", null],
  ["---", null],
  ["\n---\na: 1\n---\n", null],
  ["---\na: |\n  multi\n  ---\n---\nbody", "body"],
];

/** Rust와 TS의 판정이 다른 것 (BUG-32) */
const DISAGREE: Array<[string, string]> = [
  ["--- \na: 1\n---\nbody", "body"], // 여는 줄 끝 공백: Rust는 frontmatter, TS는 본문
  ["---  \t\na: 1\n---\n", ""],
  ["---\na: 1\n...\nbody", "body"], // `...`로 닫기: Rust만 인정
  ["---\n\t탭: 1\n---\n", ""], // 탭 들여쓴 키: Rust만 키로 봄
  ["---\nnull\n---\n본문", "본문"], // null 스칼라: Rust는 빈 frontmatter
  ["---\n~\n---\n본문", "본문"],
];

describe("frontmatter 판정이 Rust와 같다 (계약서, NFR-09)", () => {
  it.each(AGREE)("%j", (src, rustBody) => {
    const t = splitNote(src);
    expect(t.front !== null).toBe(rustBody !== null);
    if (rustBody !== null) expect(t.body).toBe(rustBody);
  });
  for (const [src, rustBody] of DISAGREE) {
    it(`BUG-32: ${JSON.stringify(src)} 도 Rust처럼 frontmatter여야 한다`, () => {
      const t = splitNote(src);
      expect(t.front).not.toBeNull();
      expect(t.body).toBe(rustBody);
    });
  }
});

describe("NFR-09: 사용자가 쓴 frontmatter 키를 지우거나 바꾸지 않는다", () => {
  const toggle = (front: string) => {
    const on = writeMeta(front, { pinned: true })!;
    expect(readMeta(on).pinned).toBe(true);
    return writeMeta(on, { pinned: false });
  };
  it.each([
    "title: \"회의록\"\ntags:\n  - a\n  - b\n",
    "# 주석\ndate: 2026-11-07\naliases:\n  - 별칭\n",
    "desc: |\n  여러 줄\n  설명\n",
    "'quoted key': 'v'\nempty:\n",
  ])("pinned를 켰다 끄면 원래 YAML 그대로: %j", (front) => {
    expect(toggle(front)).toBe(front);
  });
  // BUG-34: writeMeta가 YAML 전체를 다시 직렬화해 사용자가 쓴 서식(흐름 목록 공백, 16진수 대소문자 등)이 바뀐다
  it.fails("BUG-34: 흐름 목록 [a, b] 서식이 그대로 남아야 한다", () => {
    expect(toggle("tags: [a, b]\n")).toBe("tags: [a, b]\n");
  });
  it.fails("BUG-34: 0x1F 같은 값 표기가 그대로 남아야 한다", () => {
    expect(toggle("num: 0x1F\n")).toBe("num: 0x1F\n");
  });
});

// ───────────── FR-43: 왕복 결과 ─────────────

const mk = (md: string) => {
  const ed = new Editor({ element: document.createElement("div"), extensions: buildExtensions(), content: md, contentType: "markdown" });
  ed.commands.focus("end");
  return ed;
};
/** 열고 → (사용자가 한 번 편집해 저장) → 다시 연 문서 구조가 처음과 같은가 */
function roundTripSame(md: string) {
  const a = mk(md);
  const j1 = JSON.stringify(a.getJSON());
  const saved = tidyMarkdown(a.getMarkdown());
  a.destroy();
  const b = mk(saved);
  const j2 = JSON.stringify(b.getJSON());
  b.destroy();
  return { same: j1 === j2, saved };
}

describe("FR-43 / BUG-01 재검증", () => {
  it("BUG-01 원래 재현 문서: frontmatter는 본문에서 빠지고, 표·이미지는 지원, HTML은 읽기 전용", () => {
    const src = "---\ntags: [a, b]\n---\n# 제목\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![그림](a.png)\n";
    const { front, body } = splitNote(src);
    expect(front).toBe("tags: [a, b]\n");
    expect(findUnsupported(body)).toEqual([]);
    expect(roundTripSame(body).same).toBe(true);
    expect(findUnsupported("<div>가운데</div>")).toEqual(["HTML"]);
  });

  it.each([
    ["* 별표 목록\n* 둘"],
    ["__굵게__ 글"],
    ["~~~\ncode\n~~~"],
    ["| a | b |\n|:-|-:|\n| 1 | 2 |"],
    ["a &amp; b"],
    ["snake_case_name [[위키]] C# 2*3*4"],
    ["- [ ] a\n  - [ ] b"],
  ])("형식만 바뀌고 의미는 같다: %j", (md) => {
    expect(findUnsupported(md)).toEqual([]);
    expect(roundTripSame(md).same).toBe(true);
  });

  // BUG-29: 판정이 실제 왕복 비교가 아니라 토큰 종류 검사라, 편집하면 내용이 깨지는 문서를 편집 가능으로 연다
  const DAMAGED: Array<[string, string]> = [
    ["![](<my pic.png>)", "꺾쇠로 감싼 공백 경로 이미지 → ![](my pic.png)로 저장되어 이미지가 글자가 됨"],
    ["[파일](<my file.md>)", "꺾쇠 링크 → 링크가 글자가 됨"],
    ["[![](a.png)](https://x.com)", "링크 걸린 이미지 → 링크 주소가 사라짐"],
    ["````\n```\n````", "``` 를 담은 코드 블록 → 코드 블록이 둘로 깨짐"],
  ];
  for (const [md, why] of DAMAGED) {
    it(`BUG-29: ${why}: 읽기 전용으로 열거나 보존해야 한다`, () => {
      const unsupported = findUnsupported(md).length > 0;
      expect(unsupported || roundTripSame(md).same).toBe(true);
    });
  }

  it("BUG-29: 이름 엔티티(&nbsp; &copy;)는 글자 그대로 보이고, 편집하면 &amp;nbsp; &amp;copy; 로 저장된다", () => {
    const md = "a&nbsp;b &copy; 2026";
    const unsupported = findUnsupported(md).length > 0;
    expect(unsupported || !roundTripSame(md).saved.includes("&amp;")).toBe(true);
  });

  // BUG-31: 편집기가 쓴 "구분선 / 키: 값 / 구분선"이 다음에 열 때 frontmatter로 읽혀 본문에서 사라진다
  it("BUG-31: 편집기에서 구분선·'장소: 회의실'·구분선을 쓰고 저장하면 다시 열어도 본문에 있어야 한다", () => {
    const ed = mk("");
    ed.commands.setContent({
      type: "doc",
      content: [
        { type: "horizontalRule" },
        { type: "paragraph", content: [{ type: "text", text: "장소: 회의실" }] },
        { type: "horizontalRule" },
        { type: "paragraph", content: [{ type: "text", text: "본문" }] },
      ],
    });
    const saved = tidyMarkdown(ed.getMarkdown());
    ed.destroy();
    expect(splitNote(saved).front).toBeNull();
  });
});

describe("통합 중 수정 (b): 문서 끝 빈 문단의 &nbsp; 제거", () => {
  const p = (t?: string) => (t ? { type: "paragraph", content: [{ type: "text", text: t }] } : { type: "paragraph" });
  const save = (content: object[]) => {
    const ed = new Editor({ element: document.createElement("div"), extensions: buildExtensions() });
    ed.commands.setContent({ type: "doc", content });
    const out = tidyMarkdown(ed.getMarkdown());
    ed.destroy();
    return out;
  };
  it("끝의 빈 문단 여러 개는 지운다", () => {
    expect(save([p("a"), p(), p(), p()])).toBe("a");
  });
  it("중간의 빈 문단(빈 줄 유지용 &nbsp;)은 남긴다", () => {
    expect(save([p("a"), p(), p(), p(), p("b")])).toBe("a\n\n\n\n&nbsp;\n\n&nbsp;\n\nb");
  });
  it("사용자가 친 글자 '&nbsp;'는 지우지 않는다", () => {
    expect(save([p("a"), p("&nbsp;")])).toBe("a\n\n&amp;nbsp;");
  });
});

// ───────────── 이미지 표시 경로 (FR-32, FR-33) ─────────────

describe("assetUrl: Markdown 안 상대 경로 → 실제 파일 경로", () => {
  it.each([
    ["업무/회의/a.md", "../../attachments/x.png", "/v/attachments/x.png"],
    ["a.md", "attachments/x.png", "/v/attachments/x.png"],
    ["업무/a.md", "../attachments/a%20b.png", "/v/attachments/a b.png"],
    ["업무/a.md", "../attachments/%EC%82%AC%EC%A7%84.png", "/v/attachments/사진.png"],
    ["업무/a.md", "../attachments/p%281%29.png", "/v/attachments/p(1).png"],
    ["업무/a.md", "../attachments/pct%25.png", "/v/attachments/pct%.png"],
    ["업무/a.md", "./img/../img/b.png", "/v/업무/img/b.png"],
  ])("%s 의 %s → %s", (note, src, want) => {
    expect(assetUrl("/v", note, src)).toBe(want);
  });

  it("외부 주소는 그대로", () => {
    expect(assetUrl("/v", "a.md", "https://x.com/a.png")).toBe("https://x.com/a.png");
    expect(assetUrl("/v", "a.md", "data:image/png;base64,AA")).toBe("data:image/png;base64,AA");
  });

  // BUG-30: Rust move_entry는 #, ? 를 %23, %3F로 쓰는데 decodeURI는 이 둘을 풀지 않는다
  it("BUG-30: %23(#)·%3F(?)가 든 경로도 실제 파일 이름으로 풀어야 한다", () => {
    expect(assetUrl("/v", "a.md", "C%23%20폴더/z.png")).toBe("/v/C# 폴더/z.png");
    expect(assetUrl("/v", "a.md", "attachments/q%3Fr.png")).toBe("/v/attachments/q?r.png");
  });
});

// ───────────── 사이드바 (FR-27~29) ─────────────

const node = (path: string, modified = 0, children: FolderNode[] = []): FolderNode => ({
  path,
  name: path.split("/").pop()!,
  modified,
  children,
});

describe("사이드바 순서", () => {
  const folders = [node("가", 3), node("나", 1, [node("나/하위")]), node("다", 2)];
  const names = (l: Layout) =>
    flattenTree(folders, l, new Set())
      .map((r) => (r.kind === "sep" ? "|" : r.path))
      .join(" ");

  it("구분선 구역 안에서만 이름순·최신순", () => {
    const order = { "": ["다", "sep:1", "나", "가"] };
    expect(names({ sort: "custom", order })).toBe("다 | 나 나/하위 가");
    expect(names({ sort: "name", order })).toBe("다 | 가 나 나/하위");
    expect(names({ sort: "recent", order })).toBe("다 | 가 나 나/하위");
  });

  it("직접 정렬에서 폴더 사이로 놓으면 그 자리로", () => {
    const l = reorder(folders, { sort: "custom", order: {} }, "", "다", "가");
    expect(l.order[""]).toEqual(["다", "가", "나"]);
  });

  // BUG-33: App.moveFolder는 폴더를 다른 폴더 '안'으로 옮길 때도 reorder()를 불러 정렬 방식을 직접 정렬로 바꾼다
  it("BUG-33: 이름순에서 폴더를 다른 폴더 안으로 옮겨도 정렬 방식은 이름순으로 남아야 한다", () => {
    // moveFolder("다", "나", null) 이후 App이 부르는 것과 같은 호출
    const after = [node("가", 3), node("나", 2, [node("나/하위"), node("나/다", 2)])];
    const l = reorder(after, { sort: "name", order: {} }, "나", "다", null, true); // v0.3: '안으로'를 명시 (BUG-45)
    expect(l.sort).toBe("name");
  });
});
