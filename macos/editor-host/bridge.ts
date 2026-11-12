// WKWebView ↔ Swift 메시지. 계약은 docs/dev/architecture-v2.md 3.4.
import type { Prefs } from "../../src/lib/api";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { modoit?: { postMessage: (m: unknown) => void } } };
    modoit?: {
      load: (doc: LoadMessage) => void;
      update: (m: { markdown: string }) => void;
      prefs: (p: Prefs) => void;
      tint: (hex: string) => void;
      moved: (notePath: string) => void;
      settleInvoke: (id: number, ok: boolean, value: unknown) => void;
    };
  }
}

export interface LoadMessage {
  markdown: string;
  /** 저장 폴더 기준 상대 경로 */
  notePath: string | null;
  /** 저장 폴더의 절대 경로 */
  vault: string;
  /** 스티키용 좁은 화면 */
  compact: boolean;
  /** 지원하지 않는 서식이 있어도 편집할지 ("그래도 편집") */
  forceEditable?: boolean;
  /** 열자마자 커서를 넣을지 (새 메모) */
  focus?: boolean;
  /** 보기 전용(스티키). 체크박스를 누르면 `check`, 두 번 누르면 `open`을 보낸다 (D-25) */
  viewer?: boolean;
  /** 강조 색을 앱 설정 대신 이 색(`#rrggbb`)으로 쓴다. 스티키는 종이 색에 맞춘다 */
  tint?: string;
  prefs?: Prefs;
}

export function post(message: Record<string, unknown>) {
  window.webkit?.messageHandlers?.modoit?.postMessage(message);
}
