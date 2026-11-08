/**
 * 토글(접어 두기) 블록 (FR-48).
 * - 줄 맨 앞에서 `> ` → 토글. 첫 줄은 제목, 아래는 접고 펴는 내용.
 * - 파일에는 GitHub·Obsidian에서도 접혀 보이는 HTML로 저장한다.
 *
 *   <details>
 *   <summary>제목</summary>
 *
 *   내용
 *
 *   </details>
 */
import { InputRule, type JSONContent, type MarkdownToken } from "@tiptap/core";
import { Details, DetailsContent, DetailsSummary } from "@tiptap/extension-details";
import { Placeholder } from "@tiptap/extensions";
import { splitDetails } from "../lib/details";

export { splitDetails } from "../lib/details";

const emptyParagraph: JSONContent = { type: "paragraph" };

export const Toggle = Details.extend({
  addInputRules() {
    return [
      new InputRule({
        find: /^\s*>\s$/,
        handler: ({ range, chain }) => {
          chain().deleteRange(range).setDetails().run();
        },
      }),
    ];
  },

  markdownTokenizer: {
    name: "details",
    level: "block",
    start: (src: string) => src.search(/^<details[\s>]/im),
    tokenize(src, _tokens, lexer) {
      const d = splitDetails(src);
      if (!d) return undefined;
      return {
        type: "details",
        raw: src.slice(0, d.length),
        summaryTokens: lexer.inlineTokens(d.summary),
        tokens: d.inner ? lexer.blockTokens(d.inner) : [],
      } as MarkdownToken;
    },
  },

  parseMarkdown(token, h) {
    const t = token as MarkdownToken & { summaryTokens?: MarkdownToken[] };
    const body = h.parseChildren(t.tokens ?? []);
    return h.createNode("details", undefined, [
      h.createNode("detailsSummary", undefined, h.parseInline(t.summaryTokens ?? [])),
      h.createNode("detailsContent", undefined, body.length ? body : [emptyParagraph]),
    ]);
  },

  renderMarkdown(node, h) {
    const [summary, content] = node.content ?? [];
    const title = summary?.content ? h.renderChildren(summary.content) : "";
    const body = content?.content ? h.renderChildren(content.content, "\n\n") : "";
    const inner = body.replace(/^(?:\s*&nbsp;\s*)+$/, "").trim();
    return `<details>\n<summary>${title.replace(/\n/g, " ")}</summary>\n\n${inner}${inner ? "\n\n" : ""}</details>`;
  },
});

export const toggleExtensions = [
  Toggle.configure({ HTMLAttributes: { class: "toggle" } }),
  DetailsSummary,
  DetailsContent,
];

/** 빈 토글 제목·내용의 안내 문구 (디자인 v0.3 4장) */
export function togglePlaceholder(base: string) {
  return Placeholder.configure({
    includeChildren: true,
    placeholder: ({ node, editor, pos }) => {
      if (node.type.name === "detailsSummary") return "토글";
      if (node.type.name === "paragraph" && pos <= editor.state.doc.content.size) {
        // 장식을 계산하는 시점의 문서가 editor.state보다 앞설 수 있어 범위를 확인한다
        try {
          const $pos = editor.state.doc.resolve(pos);
          for (let d = $pos.depth; d > 0; d--) {
            if ($pos.node(d).type.name === "detailsContent") return "내용을 입력하세요";
          }
        } catch {
          /* 위치가 맞지 않으면 기본 문구 */
        }
      }
      return base;
    },
  });
}
