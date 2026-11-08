/** 글꼴·크기 설정을 화면에 적용 (FR-24) */
import type { FontChoice, Prefs } from "./api";
import pretendardUrl from "pretendard/dist/web/variable/woff2/PretendardVariable.woff2?url";

const SYSTEM = `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Apple SD Gothic Neo", sans-serif`;

export const FONT_CHOICES: Array<{ id: FontChoice; label: string; css: string }> = [
  { id: "system", label: "시스템 기본", css: SYSTEM },
  { id: "pretendard", label: "Pretendard", css: `"Pretendard Variable", ${SYSTEM}` },
  { id: "serif", label: "명조", css: `"AppleMyungjo", "Nanum Myeongjo", "Noto Serif KR", serif` },
  { id: "mono", label: "고정폭", css: `"SF Mono", "D2Coding", Menlo, monospace` },
  { id: "custom", label: "직접 입력", css: SYSTEM },
];

let pretendardLoaded: Promise<void> | null = null;
function loadPretendard() {
  if (!pretendardLoaded) {
    const face = new FontFace("Pretendard Variable", `url(${pretendardUrl}) format("woff2")`, {
      weight: "45 920",
      style: "normal",
      display: "swap",
    });
    pretendardLoaded = face.load().then((f) => {
      document.fonts.add(f);
    });
  }
  return pretendardLoaded;
}

export function fontCss(p: Pick<Prefs, "fontFamily" | "customFont">): string {
  if (p.fontFamily === "custom") {
    const name = p.customFont.trim().replace(/["\\]/g, "");
    return name ? `"${name}", ${SYSTEM}` : SYSTEM;
  }
  return FONT_CHOICES.find((f) => f.id === p.fontFamily)?.css ?? SYSTEM;
}

export function applyPrefs(p: Prefs) {
  if (p.fontFamily === "pretendard") loadPretendard().catch(() => {});
  const root = document.documentElement.style;
  root.setProperty("--font-body", fontCss(p));
  root.setProperty("--font-size", `${Math.min(22, Math.max(14, p.fontSize))}px`);
  // 강조 색은 accent.css의 [data-accent] 규칙이 라이트·다크 값을 고른다 (FR-46)
  document.documentElement.dataset.accent = p.accent ?? "yellow";
}

export const ACCENT_CHOICES: Array<{ id: Prefs["accent"]; label: string; swatch: string }> = [
  { id: "yellow", label: "노랑", swatch: "#e0a800" },
  { id: "orange", label: "주황", swatch: "#f08a00" },
  { id: "red", label: "빨강", swatch: "#e5352b" },
  { id: "pink", label: "분홍", swatch: "#e63a6f" },
  { id: "purple", label: "보라", swatch: "#9b4fd6" },
  { id: "blue", label: "파랑", swatch: "#0a7aff" },
  { id: "green", label: "초록", swatch: "#28a745" },
  { id: "graphite", label: "흑연", swatch: "#8e8e93" },
];

export const THEME_CHOICES: Array<{ id: Prefs["theme"]; label: string }> = [
  { id: "system", label: "시스템" },
  { id: "light", label: "라이트" },
  { id: "dark", label: "다크" },
];
