// v2 스파이크: src/editor(TipTap)만 따로 번들해 Swift 앱의 WKWebView에 넣는다.
// Tauri API는 shims/ 로 바꿔 끼워 WKWebView 메시지 브리지로 보낸다.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig({
  root: here("."),
  base: "./",
  plugins: [react()],
  resolve: {
    alias: {
      "@tauri-apps/api/core": here("./shims/tauri-core.ts"),
      "@tauri-apps/api/event": here("./shims/tauri-event.ts"),
    },
  },
  build: {
    outDir: here("../macos/Sources/ModoitSpike/Resources/editor"),
    emptyOutDir: true,
    // 하나의 JS 파일로: WKWebView가 모듈을 여러 번 요청하지 않게
    rollupOptions: { output: { inlineDynamicImports: true } },
  },
});
