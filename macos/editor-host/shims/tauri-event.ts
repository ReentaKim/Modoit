// @tauri-apps/api/event 대체: 편집기 호스트에서는 창 사이 이벤트를 쓰지 않는다
export type UnlistenFn = () => void;
export async function emit(_event: string, _payload?: unknown): Promise<void> {}
export async function listen<T>(_event: string, _handler: (e: { payload: T }) => void): Promise<UnlistenFn> {
  return () => {};
}
