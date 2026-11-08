import { useEffect, useMemo, useRef } from "react";
import { EditorContent, useEditor } from "@tiptap/react";
import type { Editor } from "@tiptap/core";
import { buildExtensions } from "./extensions";
import { api, fileToBase64 } from "../lib/api";
import { tidyMarkdown } from "../lib/markdownSafety";
import { assetUrl } from "../lib/paths";
import "./editor.css";

export interface MediaContext {
  vault: string;
  /** 지금 편집 중인 메모 경로 (이름이 바뀌어도 최신 값을 돌려준다) */
  notePath: () => string | null;
  onError?: (message: string) => void;
}

interface Props {
  /** 처음 보여 줄 Markdown. 바꾸려면 부모가 key를 바꿔 다시 만든다. */
  initial: string;
  onChange: (markdown: string) => void;
  compact?: boolean;
  placeholder?: string;
  autofocus?: boolean;
  readOnly?: boolean;
  media?: MediaContext;
}

const IMAGE_TYPES = /^image\/(png|jpe?g|gif|webp|heic|bmp|tiff)$/;
const MAX_IMAGE = 20 * 1024 * 1024;

async function insertImages(editor: Editor, files: File[], media: MediaContext, pos?: number) {
  const path = media.notePath();
  if (!path) return;
  for (const file of files) {
    if (!IMAGE_TYPES.test(file.type)) {
      media.onError?.(`지원하지 않는 이미지 형식입니다: ${file.name || file.type}`);
      continue;
    }
    if (file.size > MAX_IMAGE) {
      media.onError?.(`이미지가 20MB를 넘습니다: ${file.name}`);
      continue;
    }
    try {
      const ext = file.type.split("/")[1].replace("jpeg", "jpg");
      const name = file.name || `image.${ext}`;
      const rel = await api.saveAttachment(path, name, await fileToBase64(file));
      const node = { type: "image", attrs: { src: rel, alt: "" } };
      if (pos !== undefined) editor.chain().focus().insertContentAt(pos, node).run();
      else editor.chain().focus().insertContent(node).run();
    } catch (e) {
      media.onError?.(`이미지를 저장하지 못했습니다: ${String(e)}`);
    }
  }
}

function pickImageFile(editor: Editor, media: MediaContext) {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = "image/*";
  input.multiple = true;
  input.onchange = () => {
    const files = Array.from(input.files ?? []);
    if (files.length) insertImages(editor, files, media);
  };
  input.click();
}

export function ModoitEditor({ initial, onChange, compact, placeholder, autofocus, readOnly, media }: Props) {
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const mediaRef = useRef(media);
  mediaRef.current = media;

  const extensions = useMemo(
    () =>
      buildExtensions({
        placeholder,
        resolveSrc: (src) => {
          const m = mediaRef.current;
          return m ? assetUrl(m.vault, m.notePath(), src) : src;
        },
        pickImage: (ed) => mediaRef.current && pickImageFile(ed, mediaRef.current),
      }),
    // 확장은 편집기를 만들 때 한 번만
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  const editor = useEditor({
    extensions,
    content: initial,
    contentType: "markdown",
    editable: !readOnly,
    autofocus: autofocus && !readOnly ? "end" : false,
    editorProps: {
      attributes: {
        class: compact ? "modoit-editor compact" : "modoit-editor",
        spellcheck: "false",
      },
      handlePaste: (_view, event) => {
        const files = Array.from(event.clipboardData?.files ?? []).filter((f) => f.type.startsWith("image/"));
        const m = mediaRef.current;
        if (!files.length || !m || !editorRef.current) return false;
        event.preventDefault();
        insertImages(editorRef.current, files, m);
        return true;
      },
      handleDrop: (view, event, _slice, moved) => {
        if (moved) return false;
        const files = Array.from(event.dataTransfer?.files ?? []).filter((f) => f.type.startsWith("image/"));
        const m = mediaRef.current;
        if (!files.length || !m || !editorRef.current) return false;
        event.preventDefault();
        const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
        insertImages(editorRef.current, files, m, at?.pos);
        return true;
      },
    },
    // 사용자가 직접 바꾼 변경만 저장한다. 편집기가 스스로 덧붙이는 변경(끝 빈 문단 등)이나
    // 읽기 전용일 때의 변경으로 파일을 다시 쓰면 열기만 해도 원본이 바뀐다.
    onUpdate: ({ editor, transaction }) => {
      if (!transaction.docChanged || !editor.isEditable) return;
      onChangeRef.current(tidyMarkdown(editor.getMarkdown()));
    },
  });
  const editorRef = useRef<Editor | null>(null);
  editorRef.current = editor;

  useEffect(() => {
    editor?.setEditable(!readOnly);
  }, [editor, readOnly]);

  // 빈 영역을 눌러도 커서가 들어가게
  const hostRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const host = hostRef.current;
    if (!host || !editor) return;
    const onDown = (e: MouseEvent) => {
      if (e.target === host && editor.isEditable) {
        e.preventDefault();
        editor.commands.focus("end");
      }
    };
    host.addEventListener("mousedown", onDown);
    return () => host.removeEventListener("mousedown", onDown);
  }, [editor]);

  return (
    <div ref={hostRef} className="editor-host">
      <EditorContent editor={editor} />
    </div>
  );
}
