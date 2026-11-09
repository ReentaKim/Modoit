// WKWebView ↔ Swift 메시지. 계약은 docs/dev/architecture-v2.md 4장.
declare global {
  interface Window {
    webkit?: { messageHandlers?: { modoit?: { postMessage: (m: unknown) => void } } };
    modoit?: {
      load: (doc: LoadMessage) => void;
      settleInvoke: (id: number, ok: boolean, value: unknown) => void;
    };
  }
}

export interface LoadMessage {
  markdown: string;
  notePath: string | null;
  vault: string;
  compact: boolean;
  /** 지원하지 않는 서식이 있어도 편집할지 ("그래도 편집") */
  forceEditable?: boolean;
  accent?: string;
}

export function post(message: Record<string, unknown>) {
  window.webkit?.messageHandlers?.modoit?.postMessage(message);
}
