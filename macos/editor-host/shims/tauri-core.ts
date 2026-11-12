// @tauri-apps/api/core 대체: WKWebView 메시지 브리지
import { post } from "../bridge";

type Waiter = { resolve: (v: unknown) => void; reject: (e: unknown) => void };
const waiting = new Map<number, Waiter>();
let seq = 0;

/** Swift가 invoke 결과를 돌려줄 때 부른다 */
export function settleInvoke(id: number, ok: boolean, value: unknown) {
  const w = waiting.get(id);
  if (!w) return;
  waiting.delete(id);
  if (ok) w.resolve(value);
  else w.reject(value);
}

export function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const id = ++seq;
  return new Promise<T>((resolve, reject) => {
    waiting.set(id, { resolve: resolve as (v: unknown) => void, reject });
    post({ type: "invoke", id, cmd, args: args ?? {} });
  });
}

/** 절대 경로 → Swift WKURLSchemeHandler가 내주는 주소 */
export function convertFileSrc(path: string): string {
  return "modoit-file://local" + path.split("/").map(encodeURIComponent).join("/");
}
