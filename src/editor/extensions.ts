import { Extension, mergeAttributes, textInputRule, wrappingInputRule, type AnyExtension, type Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { Markdown } from "@tiptap/markdown";
import Image from "@tiptap/extension-image";
import { TableKit } from "@tiptap/extension-table";
import { encodeMarkdownText } from "../lib/markdownSafety";
import Blockquote from "@tiptap/extension-blockquote";
import { SlashCommand } from "./slash";
import { toggleExtensions, togglePlaceholder } from "./toggle";

/** 목록 밖에서 Tab을 누르면 넣는 들여쓰기(전각 공백 2개).
 *  일반 공백·탭은 Markdown에서 코드 블록으로 바뀌어 버리므로 쓰지 않는다. */
export const INDENT = "  ";

const LIST_ITEMS = ["listItem", "taskItem"] as const;

function inList(editor: Editor) {
  return LIST_ITEMS.some((n) => editor.isActive(n));
}

/** 선택한 문단마다 앞에 들여쓰기를 넣거나(+) 뺀다(-) — BUG-06 */
function indentBlocks(editor: Editor, dir: 1 | -1) {
  const { state } = editor;
  const { from, to } = state.selection;
  const starts: number[] = [];
  state.doc.nodesBetween(from, to, (node, pos) => {
    if (node.isTextblock) {
      starts.push(pos + 1);
      return false;
    }
    return true;
  });
  const tr = state.tr;
  for (const start of starts.reverse()) {
    if (dir === 1) tr.insertText(INDENT, start);
    else {
      const head = state.doc.textBetween(start, Math.min(start + 2, state.doc.content.size));
      const n = head.startsWith(INDENT) ? 2 : head.startsWith(" ") ? 1 : 0;
      if (n) tr.delete(start, start + n);
    }
  }
  if (tr.docChanged) editor.view.dispatch(tr);
  return true;
}

/**
 * Notion식 Tab / Shift+Tab
 * - 목록·체크박스 안: 한 단계 들어가기 / 나오기
 * - 코드 블록 안: 공백 2칸
 * - 그 밖: 전각 공백 들여쓰기. 여러 문단을 선택했으면 문단마다 (포커스가 빠지지 않게 Tab을 항상 가로챈다)
 */
export const NotionTab = Extension.create({
  name: "notionTab",
  priority: 1000,
  addKeyboardShortcuts() {
    return {
      Tab: ({ editor }) => {
        for (const n of LIST_ITEMS) {
          if (editor.can().sinkListItem(n)) return editor.commands.sinkListItem(n);
        }
        if (inList(editor)) return true;
        if (editor.isActive("table")) return editor.commands.goToNextCell() || true;
        if (editor.isActive("codeBlock")) return editor.commands.insertContent("  ");
        if (!editor.state.selection.empty) return indentBlocks(editor, 1);
        return editor.commands.insertContent(INDENT);
      },
      "Shift-Tab": ({ editor }) => {
        for (const n of LIST_ITEMS) {
          if (editor.can().liftListItem(n)) return editor.commands.liftListItem(n);
        }
        if (inList(editor)) return true;
        if (editor.isActive("table")) return editor.commands.goToPreviousCell() || true;
        const { $from, empty } = editor.state.selection;
        if (!empty) return indentBlocks(editor, -1);
        const before = $from.parent.textBetween(0, $from.parentOffset);
        const m = before.match(/ {1,2}$/);
        if (m) {
          const from = $from.pos - m[0].length;
          return editor.commands.deleteRange({ from, to: $from.pos });
        }
        return true;
      },
    };
  },
});

/** Markdown으로 쓸 때 꼭 필요한 곳에만 이스케이프한다 (BUG-03, BUG-01) */
export const SafeMarkdownText = Extension.create({
  name: "safeMarkdownText",
  // Markdown 확장(우선순위 100)의 onBeforeCreate가 먼저 돌아 manager를 만든 뒤에 실행되도록
  priority: 10,
  onBeforeCreate() {
    patch(this.editor);
  },
  onCreate() {
    patch(this.editor);
  },
});

type JsonNode = { type?: string; text?: string; marks?: Array<{ type: string } | string>; content?: JsonNode[] };
type Manager = {
  codeTypes: Set<string>;
  encodeTextForMarkdown: (text: string, node: JsonNode, parent?: JsonNode) => string;
  __modoit?: boolean;
};

function patch(editor: Editor) {
  const mgr = (editor as unknown as { markdown?: Manager }).markdown;
  if (!mgr || mgr.__modoit) return;
  mgr.__modoit = true;
  mgr.encodeTextForMarkdown = function (text, node, parent) {
    const inCode =
      (parent?.type != null && this.codeTypes.has(parent.type)) ||
      (node.marks ?? []).some((m) => this.codeTypes.has(typeof m === "string" ? m : m.type));
    if (inCode) return text;
    const atLineStart = !!parent?.content && parent.content[0] === node;
    return encodeMarkdownText(text, atLineStart);
  };
}

/** 인용은 `| `로 시작한다. `> `는 토글(FR-48)이 쓴다. 파일에는 표준 `> `로 저장 (FR-50) */
export const PipeQuote = Blockquote.extend({
  addInputRules() {
    return [wrappingInputRule({ find: /^\s*\|\s$/, type: this.type })];
  },
});

/** `->` → `→`, `<-` → `←`. 바로 Backspace를 누르면 되돌아간다. 코드 안에서는 바꾸지 않는다 (FR-49) */
export const Arrows = Extension.create({
  name: "arrows",
  addInputRules() {
    return [textInputRule({ find: /->$/, replace: "→" }), textInputRule({ find: /<-$/, replace: "←" })];
  },
});

export interface MediaOptions {
  /** Markdown 안의 상대 경로 → 화면에 보여 줄 주소 */
  resolveSrc: (src: string) => string;
}

/** Markdown에는 상대 경로를 그대로 두고, 화면에서만 에셋 주소로 바꿔 보여 주는 이미지 */
export const NoteImage = Image.extend<MediaOptions & Record<string, unknown>>({
  addOptions() {
    return {
      ...this.parent?.(),
      inline: false,
      allowBase64: false,
      resolveSrc: (src: string) => src,
    };
  },
  addAttributes() {
    return {
      ...this.parent?.(),
      src: {
        default: null,
        // 편집기 안에서 복사·붙여넣기 할 때 화면용 주소가 아니라 원래 경로를 쓴다
        parseHTML: (el: HTMLElement) => el.getAttribute("data-src") ?? el.getAttribute("src"),
      },
    };
  },
  renderHTML({ HTMLAttributes }) {
    const raw = HTMLAttributes.src as string | null;
    const shown = raw ? (this.options.resolveSrc as (s: string) => string)(raw) : raw;
    return [
      "img",
      mergeAttributes(this.options.HTMLAttributes as Record<string, unknown>, HTMLAttributes, {
        src: shown,
        "data-src": raw,
        draggable: "true",
      }),
    ];
  },
});

export interface ExtensionOptions {
  placeholder?: string;
  resolveSrc?: (src: string) => string;
  /** `/이미지` 를 골랐을 때 */
  pickImage?: (editor: Editor) => void;
}

export function buildExtensions(opts: ExtensionOptions = {}): AnyExtension[] {
  return [
    StarterKit.configure({
      heading: { levels: [1, 2, 3] },
      // Markdown 표준에 없는 밑줄은 끄고, 링크는 클릭해도 편집이 되도록
      underline: false,
      blockquote: false,
      link: { openOnClick: false, autolink: true },
    }),
    TaskList,
    // TipTap 3의 체크박스 노드 뷰는 data-type을 붙이지 않으므로 직접 넣는다 (CSS 선택자용)
    TaskItem.configure({ nested: true, HTMLAttributes: { "data-type": "taskItem" } }),
    NoteImage.configure({ resolveSrc: opts.resolveSrc ?? ((s: string) => s) }),
    TableKit.configure({ table: { resizable: false } }),
    PipeQuote,
    ...toggleExtensions,
    Arrows,
    togglePlaceholder(opts.placeholder ?? "메모를 입력하세요…"),
    Markdown.configure({ indentation: { style: "space", size: 2 } }),
    SafeMarkdownText,
    SlashCommand.configure({ pickImage: opts.pickImage ?? (() => {}) }),
    NotionTab,
  ];
}
