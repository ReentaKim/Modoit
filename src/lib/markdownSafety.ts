/**
 * Markdown 원본을 지키기 위한 도구 모음.
 * - encodeMarkdownText: 글자를 Markdown으로 쓸 때 꼭 필요한 곳에만 이스케이프한다 (BUG-03, BUG-01)
 * - findUnsupported: Modoit 편집기가 그대로 되살릴 수 없는 서식이 있는지 검사한다 (FR-43)
 */
import { stripToggleTags } from "./details";
import { Lexer, type Token, type Tokens } from "marked";

/**
 * 텍스트 노드 하나를 Markdown 문자열로 바꾼다.
 * 기존 구현은 모든 & < > 를 엔티티로, _ [ ] * ~ ` \ 를 모두 역슬래시로 바꿨다.
 * 여기서는 다시 읽을 때 의미가 바뀌는 경우에만 바꾼다.
 */
export function encodeMarkdownText(text: string, atLineStart: boolean): string {
  let out = text
    // \ 뒤에 문장부호가 오면 이스케이프로 읽히므로 \ 자체를 지킨다
    .replace(/\\(?=[!-/:-@[-`{-~])/g, "\\\\")
    // `, * 는 언제든 강조·코드가 될 수 있다
    .replace(/[`*]/g, "\\$&")
    // _ 는 단어 경계에 있을 때만 강조가 된다 (snake_case 는 그대로)
    .replace(/(^|[^\p{L}\p{N}])_|_(?=$|[^\p{L}\p{N}])/gu, (m) => m.replace("_", "\\_"))
    // ~~ 는 취소선
    .replace(/~~/g, "\\~\\~")
    // [글](주소), [글][참조], [글]: 형태가 될 수 있을 때만 [ 를 이스케이프 ([[위키]] 는 그대로)
    .replace(/\[(?=[^\]\n]*\](?:\(|\[|:))/g, "\\[")
    // 엔티티처럼 보이는 & 만 엔티티로 (R&D 는 그대로)
    .replace(/&(?=#?[A-Za-z0-9]+;)/g, "&amp;")
    // 태그처럼 보이는 < 만 엔티티로 (& 처리 뒤에 해야 &lt; 가 다시 바뀌지 않는다)
    .replace(/<(?=[A-Za-z/!?])/g, "&lt;");

  if (atLineStart) {
    // 줄 맨 앞에서 블록 문법으로 읽히는 모양이면 첫 글자를 이스케이프
    out = out
      .replace(/^(#{1,6})(?=\s|$)/, "\\$1")
      .replace(/^([-+])(?=\s)/, "\\$1")
      .replace(/^(\d{1,9})([.)])(?=\s)/, "$1\\$2")
      .replace(/^>/, "\\>")
      .replace(/^(={3,}|-{3,})\s*$/, "\\$1");
  }
  return out;
}

/** Modoit 편집기가 그대로 되살릴 수 있는 토큰 */
const SUPPORTED_BLOCK = new Set([
  "space",
  "paragraph",
  "heading",
  "list",
  "list_item",
  "blockquote",
  "code",
  "hr",
  "table",
  "text",
  "checkbox",
]);
const SUPPORTED_INLINE = new Set([
  "text",
  "strong",
  "em",
  "codespan",
  "del",
  "link",
  "image",
  "br",
  "escape",
  "checkbox",
]);

/** &amp; &lt; &gt; &quot; &#39; 말고 다른 문자 참조 — 편집기는 이를 풀지 않고 글자로 보여 준다 */
const ENTITY = /&(?!(?:amp|lt|gt|quot|#39);)(?:[A-Za-z][A-Za-z0-9]{1,31}|#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6});/;

const LABEL: Record<string, string> = {
  html: "HTML",
  def: "참조 링크 정의",
  footnote: "각주",
  lheading: "밑줄식 제목",
};

/** 지원하지 않는 서식 이름 목록. 비어 있으면 안전하게 편집할 수 있다. */
export { stripToggleTags } from "./details";

export function findUnsupported(markdown: string): string[] {
  const found = new Set<string>();
  let tokens: Token[];
  try {
    tokens = new Lexer({ gfm: true }).lex(stripToggleTags(markdown));
  } catch {
    return ["해석할 수 없는 Markdown"];
  }
  const visit = (list: Token[] | undefined, inline: boolean) => {
    for (const t of list ?? []) {
      // Modoit이 빈 줄을 남기려고 쓰는 `&nbsp;` 한 줄짜리 문단은 지원 서식
      if (t.type === "paragraph" && t.raw.trim() === "&nbsp;") continue;
      const ok = inline ? SUPPORTED_INLINE.has(t.type) : SUPPORTED_BLOCK.has(t.type);
      if (!ok) {
        found.add(LABEL[t.type] ?? t.type);
        continue;
      }
      if (t.type === "heading" && /\n\s*(=+|-+)\s*$/.test(t.raw)) found.add(LABEL.lheading);
      if (t.type === "link" && (t as Tokens.Link).title) found.add("링크 제목");
      if (t.type === "image" && (t as Tokens.Image).title) found.add("이미지 제목");
      // 아래는 편집기가 열거나 저장할 때 바뀌는 서식 (BUG-29)
      if ((t.type === "link" || t.type === "image") && /\]\(\s*</.test(t.raw)) found.add("꺾쇠로 감싼 링크 주소");
      if (t.type === "link" && (t as Tokens.Link).tokens?.some((c) => c.type === "image")) found.add("링크 걸린 이미지");
      if (t.type === "code" && /^ {0,3}(`{4,}|~{3,})/.test(t.raw) && /^ {0,3}```/m.test((t as Tokens.Code).text)) {
        found.add("``` 를 담은 코드 블록");
      }
      if (t.type === "text" && ENTITY.test(t.raw)) found.add("HTML 엔티티");
      if (t.type === "list") visit((t as Tokens.List).items as unknown as Token[], false);
      else if (t.type === "list_item") visit((t as Tokens.ListItem).tokens, false);
      else if (t.type === "blockquote") visit((t as Tokens.Blockquote).tokens, false);
      else if (t.type === "table") {
        const tb = t as Tokens.Table;
        for (const cell of [...tb.header, ...tb.rows.flat()]) visit(cell.tokens, true);
      } else if ("tokens" in t && Array.isArray(t.tokens)) {
        visit(t.tokens, true);
      }
    }
  };
  visit(tokens, false);
  return [...found];
}

/** 표 앞뒤에 변환기가 덧붙이는 빈 줄을 하나로 줄인다 (표 밖의 빈 줄은 그대로) */
export function tidyMarkdown(md: string): string {
  return md
    .replace(/^\n+(?=\|)/, "")
    .replace(/\n{3,}(?=\|[^\n]*\|[ \t]*\n\|[ \t:|-]*-)/g, "\n\n")
    .replace(/(\|[ \t]*)\n{3,}/g, "$1\n\n")
    .replace(/(\|[ \t]*)\n+$/, "$1")
    // 문서 끝의 빈 문단(&nbsp;)은 의미가 없다
    .replace(/(?:\n+(?:&nbsp;|\u00a0)[ \t]*)+\s*$/, "")
    // 맨 앞 구분선을 `---`로 쓰면 다음에 열 때 frontmatter로 읽힐 수 있다 (BUG-31)
    .replace(/^---(?=\n|$)/, "***");
}
