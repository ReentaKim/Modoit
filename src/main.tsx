import React, { Suspense, lazy } from "react";
import ReactDOM from "react-dom/client";

declare global {
  interface Window {
    /** 스티키 창이면 Rust가 미리 넣어 주는 파일 경로 */
    __MODOIT_STICKY__?: string;
    /** ⌘⇧N으로 방금 만든 메모의 스티키인지 */
    __MODOIT_STICKY_FRESH__?: boolean;
  }
}

const stickyPath = window.__MODOIT_STICKY__;

// 창 종류에 따라 필요한 화면과 스타일만 불러온다
const Root = stickyPath
  ? lazy(() => import("./sticky/StickyApp").then((m) => ({ default: () => <m.StickyApp path={stickyPath} fresh={window.__MODOIT_STICKY_FRESH__ === true} /> })))
  : lazy(() => import("./app/App").then((m) => ({ default: m.App })));

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <Suspense fallback={null}>
      <Root />
    </Suspense>
  </React.StrictMode>,
);
