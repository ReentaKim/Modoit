// v2 편집기 호스트: v0.x의 ModoitEditor(TipTap)를 그대로 띄우고 Swift와 메시지로 잇는다.
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { ModoitEditor } from "../../src/editor/ModoitEditor";
import { unsupportedFeatures } from "../../src/editor/editability";
import { applyPrefs } from "../../src/lib/prefs";
import { post, type LoadMessage } from "./bridge";
import { settleInvoke } from "./shims/tauri-core";
import "../../src/app/accent.css";
import "./host.css";

interface Doc extends LoadMessage {
  key: number;
  readOnly: boolean;
}

let setDocExternal: ((d: Doc) => void) | null = null;
let current: Doc | null = null;
let queued: LoadMessage | null = null;
let seq = 0;
/** 이 편집기가 마지막으로 Swift와 같다고 알던 본문. `change`에 함께 보내 병합의 기준으로 쓴다 */
let base = "";
/** 한글 조합 중에 들어와 미뤄 둔 본문 (NFR-20) */
let pendingUpdate: string | null = null;
let composing = false;

function show(m: LoadMessage) {
  const unsupported = m.forceEditable ? [] : unsupportedFeatures(m.markdown);
  if (m.prefs) applyPrefs(m.prefs);
  document.body.classList.toggle("compact", m.compact);
  base = m.markdown;
  const doc: Doc = { ...m, key: ++seq, readOnly: unsupported.length > 0 || !!m.viewer };
  // 보기 전용 화면은 다시 그려도 스크롤 위치를 지킨다
  keepScroll = m.viewer && current ? scroller()?.scrollTop ?? null : null;
  current = doc;
  // 지원하지 않는 서식이 있으면 읽기 전용으로 열고 이유를 알린다 (FR-43)
  post({ type: "opened", key: doc.key, unsupported });
  if (setDocExternal) setDocExternal(doc);
}

function applyUpdate(markdown: string) {
  if (!current || markdown === base) return;
  // 다른 편집기(스티키)나 다른 앱이 고친 본문. 문서를 다시 그린다
  show({ ...current, markdown, focus: false });
}

function scroller(): Element | null {
  return document.querySelector(".editor-host") ?? document.scrollingElement;
}
let keepScroll: number | null = null;

// 보기 전용(스티키): 체크박스는 Swift가 원문의 그 줄 한 글자만 바꾼다. 편집기는 문서를 고치지 않는다
document.addEventListener(
  "change",
  (e) => {
    const t = e.target as HTMLInputElement | null;
    if (!current?.viewer || !t || t.type !== "checkbox") return;
    const item = t.closest('li[data-type="taskItem"]');
    if (!item) return;
    const index = Array.from(document.querySelectorAll('li[data-type="taskItem"]')).indexOf(item);
    if (index >= 0) post({ type: "check", index, checked: t.checked });
  },
  true,
);
document.addEventListener("dblclick", () => {
  if (current?.viewer) post({ type: "open" });
});

document.addEventListener("compositionstart", () => (composing = true), true);
document.addEventListener(
  "compositionend",
  () => {
    composing = false;
    if (pendingUpdate !== null) {
      const m = pendingUpdate;
      pendingUpdate = null;
      // 조합으로 생긴 change가 먼저 나간 뒤에 반영한다
      setTimeout(() => applyUpdate(m), 0);
    }
  },
  true,
);

window.modoit = {
  load: (m) => {
    pendingUpdate = null;
    if (setDocExternal) show(m);
    else queued = m;
  },
  update: ({ markdown }) => {
    if (composing) pendingUpdate = markdown;
    else applyUpdate(markdown);
  },
  prefs: (p) => {
    // 다시 그릴 때 옛 설정으로 돌아가지 않게 기억해 둔다
    if (current) current.prefs = p;
    applyPrefs(p);
  },
  // 제목이 바뀌어 파일 이름이 바뀌었다. 이미지 경로 계산에 쓰는 메모 경로를 맞춘다
  moved: (notePath) => {
    if (current) current.notePath = notePath;
  },
  settleInvoke,
};

function Host() {
  const [doc, setDoc] = useState<Doc | null>(null);
  useEffect(() => {
    setDocExternal = setDoc;
    if (queued) {
      show(queued);
      queued = null;
    }
    post({ type: "ready" });
  }, []);
  // 문서를 DOM에 넣은 뒤 알린다 (실행 시간 측정, NFR-18).
  // requestAnimationFrame은 창이 가려지면 멈추므로 쓰지 않는다.
  useEffect(() => {
    if (!doc) return;
    if (keepScroll !== null) {
      const s = scroller();
      if (s) s.scrollTop = keepScroll;
    }
    post({ type: "loaded", key: doc.key });
  }, [doc?.key]);
  if (!doc) return null;
  return (
    <ModoitEditor
      key={doc.key}
      initial={doc.markdown}
      compact={doc.compact}
      readOnly={doc.readOnly}
      autofocus={doc.compact || doc.focus}
      onChange={(markdown) => {
        post({ type: "change", markdown, base });
        base = markdown;
      }}
      media={{
        vault: doc.vault,
        notePath: () => doc.notePath,
        onError: (message) => post({ type: "error", message }),
      }}
    />
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(<Host />);
