import { convertFileSrc } from "@tauri-apps/api/core";

/** "a/b/../c" → "a/c" */
export function normalize(path: string): string {
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return (path.startsWith("/") ? "/" : "") + out.join("/");
}

const EXTERNAL = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i;

/** 메모 안의 이미지 경로 → 화면에 띄울 주소 */
export function assetUrl(vault: string, notePath: string | null, src: string): string {
  if (!src || EXTERNAL.test(src)) return src;
  // 조각마다 풀어야 %23(#)·%3F(?)·%2F 같은 문자도 실제 파일 이름으로 돌아온다 (BUG-30)
  const decoded = src
    .split("/")
    .map((part) => {
      try {
        return decodeURIComponent(part);
      } catch {
        return part; // 잘못된 인코딩은 그대로
      }
    })
    .join("/");
  const folder = notePath && notePath.includes("/") ? notePath.slice(0, notePath.lastIndexOf("/")) : "";
  const abs = decoded.startsWith("/") ? decoded : normalize(`${vault}/${folder}/${decoded}`);
  return convertFileSrc(abs);
}
