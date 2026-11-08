// @vitest-environment jsdom
/**
 * QA v0.3 — 순수 로직: v0.2 결함 수정 재검증(BUG-33, BUG-37)과 그 경계 사례.
 * it.fails 는 v0.3 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { describe, expect, it } from "vitest";
import { reorder } from "../lib/sidebar";
import { DEFAULT_STICKY, readMeta } from "../lib/frontmatter";
import type { FolderNode, Layout } from "../lib/api";

const node = (path: string, modified = 0, children: FolderNode[] = []): FolderNode => ({
  path,
  name: path.split("/").pop()!,
  modified,
  children,
});
const folders = [node("가", 3), node("나", 1), node("다", 2)];

describe("BUG-33 수정 재검증과 경계", () => {
  it("이름순에서 다른 폴더 '안'으로 옮기면 정렬 방식 유지", () => {
    const l: Layout = { sort: "name", order: {} };
    expect(reorder([node("가"), node("나", 0, [node("나/다")])], l, "나", "다", null, true)).toBe(l); // v0.3 BUG-45: '안으로'를 명시
  });

  it("이름순에서 폴더 '사이'에 놓으면 화면 순서를 고정하고 직접 정렬로 (의도된 동작)", () => {
    const l = reorder(folders, { sort: "name", order: {} }, "", "다", "가");
    expect(l.sort).toBe("custom");
    expect(l.order[""]).toEqual(["다", "가", "나"]);
  });

  // BUG-45: '안으로 옮김'과 '같은 부모의 맨 뒤에 놓음'이 둘 다 beforeKey=null이라 구분되지 않는다.
  // 이름순·최신순에서 폴더나 구분선을 맨 뒤(마지막 행 아래쪽, 사이드바 맨 아래 빈 곳)로 끌면 아무 일도 없다.
  it("BUG-45: 이름순에서 폴더를 같은 부모의 맨 뒤로 끌면 직접 정렬로 바뀌고 맨 뒤에 놓여야 한다", () => {
    const l = reorder(folders, { sort: "name", order: {} }, "", "가", null);
    expect(l.sort).toBe("custom");
    expect(l.order[""]).toEqual(["나", "다", "가"]);
  });

  it("BUG-45: 최신순에서 구분선을 맨 뒤로 끌면 맨 뒤로 옮겨져야 한다", () => {
    const l = reorder(folders, { sort: "recent", order: { "": ["가", "sep:1", "나", "다"] } }, "", "sep:1", null);
    const seq = l.order[""] ?? [];
    expect(seq[seq.length - 1]).toBe("sep:1");
  });
});

describe("BUG-37 수정 재검증: sticky 기본값", () => {
  it("기본 크기는 280, open 키가 없으면 넣어 둠(false)", () => {
    expect([DEFAULT_STICKY.w, DEFAULT_STICKY.h]).toEqual([280, 280]);
    const m = readMeta("sticky: {color: blue}\n").sticky!;
    expect([m.w, m.h, m.open]).toEqual([280, 280, false]);
  });
});
