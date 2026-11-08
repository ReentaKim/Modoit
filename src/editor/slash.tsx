/** `/` 명령 메뉴 (FR-34) */
import { Extension, type Editor, type Range } from "@tiptap/core";
import { PluginKey } from "@tiptap/pm/state";
import { ReactRenderer } from "@tiptap/react";
import Suggestion, { type SuggestionKeyDownProps, type SuggestionProps } from "@tiptap/suggestion";
import { forwardRef, useEffect, useImperativeHandle, useRef, useState, type ComponentType } from "react";
import {
  CheckSquare,
  Code,
  Image as ImageIcon,
  ListBullets,
  ListNumbers,
  Minus,
  Quotes,
  TextHOne,
  TextHThree,
  TextHTwo,
  TextT,
  type IconProps, CaretRight } from "@phosphor-icons/react";

export interface SlashItem {
  id: string;
  label: string;
  hint: string;
  keywords: string[];
  icon: ComponentType<IconProps>;
  run: (editor: Editor, range: Range, pickImage: (e: Editor) => void) => void;
}

export const SLASH_ITEMS: SlashItem[] = [
  { id: "text", label: "텍스트", hint: "", keywords: ["text", "문단", "본문"], icon: TextT,
    run: (e, r) => e.chain().focus().deleteRange(r).setParagraph().run() },
  { id: "h1", label: "제목 1", hint: "#", keywords: ["h1", "heading", "제목", "큰"], icon: TextHOne,
    run: (e, r) => e.chain().focus().deleteRange(r).setHeading({ level: 1 }).run() },
  { id: "h2", label: "제목 2", hint: "##", keywords: ["h2", "heading", "제목", "중간"], icon: TextHTwo,
    run: (e, r) => e.chain().focus().deleteRange(r).setHeading({ level: 2 }).run() },
  { id: "h3", label: "제목 3", hint: "###", keywords: ["h3", "heading", "제목", "작은"], icon: TextHThree,
    run: (e, r) => e.chain().focus().deleteRange(r).setHeading({ level: 3 }).run() },
  { id: "bullet", label: "점 목록", hint: "-", keywords: ["bullet", "list", "목록", "글머리"], icon: ListBullets,
    run: (e, r) => e.chain().focus().deleteRange(r).toggleBulletList().run() },
  { id: "ordered", label: "번호 목록", hint: "1.", keywords: ["number", "ordered", "list", "목록", "숫자"], icon: ListNumbers,
    run: (e, r) => e.chain().focus().deleteRange(r).toggleOrderedList().run() },
  { id: "task", label: "체크박스", hint: "[ ]", keywords: ["todo", "task", "check", "할일", "할 일", "체크"], icon: CheckSquare,
    run: (e, r) => e.chain().focus().deleteRange(r).toggleTaskList().run() },
  { id: "toggle", label: "토글", hint: ">", keywords: ["toggle", "details", "접기", "펼치기", "토글"], icon: CaretRight,
    run: (e, r) => e.chain().focus().deleteRange(r).setDetails().run() },
  { id: "quote", label: "인용", hint: "|", keywords: ["quote", "인용문"], icon: Quotes,
    run: (e, r) => e.chain().focus().deleteRange(r).toggleBlockquote().run() },
  { id: "code", label: "코드", hint: "```", keywords: ["code", "코드블록"], icon: Code,
    run: (e, r) => e.chain().focus().deleteRange(r).toggleCodeBlock().run() },
  { id: "hr", label: "구분선", hint: "---", keywords: ["divider", "hr", "line", "선"], icon: Minus,
    run: (e, r) => e.chain().focus().deleteRange(r).setHorizontalRule().run() },
  { id: "image", label: "이미지", hint: "", keywords: ["image", "picture", "사진", "그림"], icon: ImageIcon,
    run: (e, r, pick) => {
      e.chain().focus().deleteRange(r).run();
      pick(e);
    } },
];

export function filterSlash(query: string): SlashItem[] {
  const q = query.trim().toLowerCase();
  if (!q) return SLASH_ITEMS;
  return SLASH_ITEMS.filter(
    (it) => it.label.toLowerCase().includes(q) || it.keywords.some((k) => k.toLowerCase().startsWith(q) || k.includes(q)),
  );
}

interface MenuHandle {
  onKeyDown: (e: KeyboardEvent) => boolean;
}

interface MenuProps {
  items: SlashItem[];
  command: (item: SlashItem) => void;
}

const SlashMenu = forwardRef<MenuHandle, MenuProps>(function SlashMenu({ items, command }, ref) {
  const [active, setActive] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => setActive(0), [items]);
  useEffect(() => {
    listRef.current?.querySelector<HTMLElement>(`[data-i="${active}"]`)?.scrollIntoView({ block: "nearest" });
  }, [active]);
  useImperativeHandle(ref, () => ({
    onKeyDown: (e) => {
      if (e.key === "ArrowDown") {
        setActive((a) => (items.length ? (a + 1) % items.length : 0));
        return true;
      }
      if (e.key === "ArrowUp") {
        setActive((a) => (items.length ? (a - 1 + items.length) % items.length : 0));
        return true;
      }
      if (e.key === "Enter") {
        if (items[active]) command(items[active]);
        return true;
      }
      return false;
    },
  }));
  return (
    <div className="slash-menu" ref={listRef} onMouseDown={(e) => e.preventDefault()}>
      {items.length === 0 && <div className="slash-empty">결과 없음</div>}
      {items.map((it, i) => {
        const Icon = it.icon;
        return (
          <button
            key={it.id}
            data-i={i}
            className={`slash-item ${i === active ? "active" : ""}`}
            onMouseEnter={() => setActive(i)}
            onClick={() => command(it)}
          >
            <Icon size={18} />
            <span className="slash-label">{it.label}</span>
            <span className="slash-hint">{it.hint}</span>
          </button>
        );
      })}
    </div>
  );
});

function place(el: HTMLElement, rect: DOMRect | null | undefined) {
  if (!rect) return;
  const h = el.offsetHeight || 300;
  const below = rect.bottom + 6;
  const top = below + h > window.innerHeight - 8 ? Math.max(8, rect.top - h - 6) : below;
  const left = Math.min(rect.left, window.innerWidth - (el.offsetWidth || 280) - 8);
  el.style.top = `${top}px`;
  el.style.left = `${Math.max(8, left)}px`;
}

export const SlashCommand = Extension.create<{ pickImage: (e: Editor) => void }>({
  name: "slashCommand",
  addOptions() {
    return { pickImage: () => {} };
  },
  addProseMirrorPlugins() {
    const pickImage = () => this.options.pickImage;
    return [
      Suggestion<SlashItem, SlashItem>({
        editor: this.editor,
        pluginKey: new PluginKey("slashCommand"),
        char: "/",
        allowSpaces: false,
        startOfLine: false,
        allow: ({ state, range }) => {
          // 코드 안에서는 띄우지 않는다
          const $from = state.doc.resolve(range.from);
          return $from.parent.type.name !== "codeBlock";
        },
        items: ({ query }) => filterSlash(query),
        command: ({ editor, range, props }) => props.run(editor, range, pickImage()),
        render: () => {
          let renderer: ReactRenderer<MenuHandle, MenuProps> | null = null;
          let host: HTMLDivElement | null = null;
          return {
            onStart: (props: SuggestionProps<SlashItem, SlashItem>) => {
              host = document.createElement("div");
              host.className = "slash-host";
              document.body.appendChild(host);
              renderer = new ReactRenderer(SlashMenu, {
                editor: props.editor,
                props: { items: props.items, command: props.command },
              });
              host.appendChild(renderer.element);
              requestAnimationFrame(() => host && place(host, props.clientRect?.()));
            },
            onUpdate: (props: SuggestionProps<SlashItem, SlashItem>) => {
              renderer?.updateProps({ items: props.items, command: props.command });
              if (host) place(host, props.clientRect?.());
            },
            onKeyDown: (props: SuggestionKeyDownProps) => {
              if (props.event.key === "Escape") {
                host?.remove();
                return true;
              }
              return renderer?.ref?.onKeyDown(props.event) ?? false;
            },
            onExit: () => {
              renderer?.destroy();
              host?.remove();
              renderer = null;
              host = null;
            },
          };
        },
      }),
    ];
  },
});
