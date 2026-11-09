// v2 스파이크 편집기 호스트: v0.3의 ModoitEditor를 그대로 띄운다.
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { ModoitEditor } from "../../src/editor/ModoitEditor";
import { unsupportedFeatures } from "../../src/editor/editability";
import { post, type LoadMessage } from "./bridge";
import { settleInvoke } from "./shims/tauri-core";
import "../../src/app/accent.css";
import "./host.css";

interface Doc extends LoadMessage {
  key: number;
  readOnly: boolean;
}

let setDocExternal: ((d: Doc) => void) | null = null;
let queued: LoadMessage | null = null;
let seq = 0;

function toDoc(m: LoadMessage): Doc {
  const unsupported = m.forceEditable ? [] : unsupportedFeatures(m.markdown);
  if (unsupported.length) post({ type: "readOnly", reasons: unsupported });
  if (m.accent) document.documentElement.dataset.accent = m.accent;
  document.body.classList.toggle("compact", m.compact);
  return { ...m, key: ++seq, readOnly: unsupported.length > 0 };
}

window.modoit = {
  load: (m) => {
    if (setDocExternal) setDocExternal(toDoc(m));
    else queued = m;
  },
  settleInvoke,
};

function Host() {
  const [doc, setDoc] = useState<Doc | null>(null);
  useEffect(() => {
    setDocExternal = setDoc;
    if (queued) {
      setDoc(toDoc(queued));
      queued = null;
    }
    post({ type: "ready" });
  }, []);
  // 문서를 DOM에 넣은 뒤 알린다 (스파이크의 실행 시간 측정용).
  // requestAnimationFrame은 창이 가려지면 멈추므로 쓰지 않는다.
  useEffect(() => {
    if (doc) post({ type: "loaded" });
  }, [doc?.key]);
  if (!doc) return null;
  return (
    <ModoitEditor
      key={doc.key}
      initial={doc.markdown}
      compact={doc.compact}
      readOnly={doc.readOnly}
      autofocus={doc.compact}
      onChange={(markdown) => post({ type: "change", markdown })}
      media={{
        vault: doc.vault,
        notePath: () => doc.notePath,
        onError: (message) => post({ type: "error", message }),
      }}
    />
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(<Host />);
