/**
 * 메모 파일 맨 위 frontmatter 처리.
 * 사용자가 써 둔 다른 키·주석·순서는 그대로 두고, Modoit이 쓰는 키(pinned, sticky)만 고친다 (NFR-09).
 */
import { Document, isMap, isScalar, parseDocument, YAMLMap } from "yaml";

export const STICKY_COLORS = ["yellow", "pink", "blue", "green", "purple"] as const;
export type StickyColor = (typeof STICKY_COLORS)[number];

export interface StickyMeta {
  color: StickyColor;
  x: number | null;
  y: number | null;
  w: number;
  h: number;
  onTop: boolean;
  open: boolean;
}

export const DEFAULT_STICKY: StickyMeta = {
  color: "yellow",
  x: null,
  y: null,
  w: 280,
  h: 280,
  onTop: false,
  open: true,
};

export interface NoteParts {
  /** --- 사이의 YAML 원문 (끝 줄바꿈 포함). 없으면 null */
  front: string | null;
  body: string;
}

/** Rust vault::split_frontmatter 와 한 줄씩 같은 판정 (BUG-32):
 *  - 첫 줄(BOM 제외)이 끝 공백을 빼고 `---`
 *  - 그 뒤 처음 나오는 `---` 또는 `...` 줄에서 닫힌다
 *  - 안쪽이 YAML 매핑이거나 비어 있으면(null, ~ 포함) frontmatter
 *  - 파싱이 깨져도 첫 줄이 `키:` 꼴이면 frontmatter
 *  그 밖에는 구분선으로 시작하는 본문으로 본다 (BUG-18). */
export function splitNote(src: string): NoteParts {
  const s = src.startsWith("\ufeff") ? src.slice(1) : src;
  const lines = s.match(/[^\n]*(?:\n|$)/g) ?? [];
  const text = (l: string) => l.replace(/[\r\n]+$/, "");
  if (text(lines[0] ?? "").trimEnd() !== "---") return { front: null, body: src };
  const yamlStart = lines[0]!.length;
  let pos = yamlStart;
  for (let i = 1; i < lines.length && lines[i] !== ""; i++) {
    const line = lines[i]!;
    const t = text(line).trimEnd();
    if (t === "---" || t === "...") {
      const yaml = s.slice(yamlStart, pos);
      const body = s.slice(pos + line.length);
      return isFrontmatter(yaml) ? { front: yaml, body } : { front: null, body: src };
    }
    pos += line.length;
  }
  return { front: null, body: src };
}

function isFrontmatter(yaml: string): boolean {
  const doc = parseDocument(yaml);
  if (doc.errors.length === 0) {
    const c = doc.contents;
    return c === null || isMap(c) || (isScalar(c) && c.value === null);
  }
  const first = yaml.split("\n").find((l) => l.trim()) ?? "";
  return looksLikeYamlKey(first);
}

function looksLikeYamlKey(line: string): boolean {
  const t = line.trim();
  const i = t.indexOf(":");
  return i > 0 && /^[\p{L}\p{N}_\- ]+$/u.test(t.slice(0, i));
}

export function joinNote({ front, body }: NoteParts): string {
  if (front === null) return body;
  const f = front.endsWith("\n") || front === "" ? front : front + "\n";
  return `---\n${f}---\n${body}`;
}

const num = (v: unknown, d: number | null) => (typeof v === "number" && Number.isFinite(v) ? v : d);
const LEGACY_KEYS = ["color", "x", "y", "w", "h", "onTop", "open"];

/** open 키가 없으면 Rust와 같이 '넣어 둠'으로 본다 (BUG-37). v0.1 형식은 스티키 파일이 곧 떠 있는 스티키였으므로 꺼냄 */
function toSticky(raw: Record<string, unknown>, legacy = false): StickyMeta {
  const color = (STICKY_COLORS as readonly string[]).includes(String(raw.color))
    ? (raw.color as StickyColor)
    : DEFAULT_STICKY.color;
  return {
    color,
    x: num(raw.x, null),
    y: num(raw.y, null),
    w: num(raw.w, DEFAULT_STICKY.w) ?? DEFAULT_STICKY.w,
    h: num(raw.h, DEFAULT_STICKY.h) ?? DEFAULT_STICKY.h,
    onTop: raw.onTop === true,
    open: legacy ? raw.open !== false : raw.open === true,
  };
}

export interface NoteMetaFields {
  pinned: boolean;
  sticky: StickyMeta | null;
  /** v0.1 Stickies 형식(최상위 color/x/...)이었는지 */
  legacy: boolean;
}

export function readMeta(front: string | null): NoteMetaFields {
  if (!front) return { pinned: false, sticky: null, legacy: false };
  let data: unknown;
  try {
    data = parseDocument(front).toJS();
  } catch {
    return { pinned: false, sticky: null, legacy: false };
  }
  if (!data || typeof data !== "object") return { pinned: false, sticky: null, legacy: false };
  const d = data as Record<string, unknown>;
  const pinned = d.pinned === true;
  if (d.sticky && typeof d.sticky === "object") {
    return { pinned, sticky: toSticky(d.sticky as Record<string, unknown>), legacy: false };
  }
  // v0.1 형식 (NFR-08)
  if (typeof d.color === "string" && ("w" in d || "h" in d)) {
    return { pinned, sticky: toSticky(d, true), legacy: true };
  }
  return { pinned, sticky: null, legacy: false };
}

export interface MetaPatch {
  pinned?: boolean;
  /** null 이면 sticky 키 삭제 */
  sticky?: StickyMeta | null;
}

/** frontmatter의 pinned/sticky만 바꾼 새 원문. 남는 키가 없으면 null(frontmatter 제거) */
export function writeMeta(front: string | null, patch: MetaPatch): string | null {
  const parsed = parseDocument(front ?? "");
  if (parsed.errors.length > 0) {
    // 사용자가 쓴 YAML이 깨져 있으면 건드리지 않는다
    return front;
  }
  const doc: Document = isMap(parsed.contents) ? parsed : new Document({});
  const legacy = readMeta(front).legacy;

  if (patch.pinned !== undefined) {
    if (patch.pinned) doc.set("pinned", true);
    else doc.delete("pinned");
  }
  if (patch.sticky !== undefined) {
    if (legacy) for (const k of LEGACY_KEYS) doc.delete(k);
    if (patch.sticky === null) {
      doc.delete("sticky");
    } else {
      const s = patch.sticky;
      const node = doc.createNode({
        color: s.color,
        x: s.x === null ? null : Math.round(s.x),
        y: s.y === null ? null : Math.round(s.y),
        w: Math.round(s.w),
        h: Math.round(s.h),
        onTop: s.onTop,
        open: s.open,
      });
      node.flow = true;
      doc.set("sticky", node);
    }
  }
  const map = doc.contents as YAMLMap;
  if (map.items.length === 0 && !doc.commentBefore && !doc.comment) return null;
  return doc.toString({ lineWidth: 0 });
}
