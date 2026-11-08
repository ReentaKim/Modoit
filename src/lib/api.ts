/** Rust 명령 래퍼 — docs/dev/api-v0.2.md 계약서와 1:1로 맞춘다 */
import { invoke } from "@tauri-apps/api/core";
import { emit, listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { StickyMeta } from "./frontmatter";
import { joinNote, readMeta, splitNote, writeMeta, type MetaPatch } from "./frontmatter";

export interface NoteMeta {
  path: string;
  folder: string;
  title: string;
  preview: string;
  modified: number;
  /** 파일 생성 시각(ms) (FR-47) */
  created: number;
  pinned: boolean;
  sticky: StickyMeta | null;
  readable: boolean;
}

export interface FolderNode {
  path: string;
  name: string;
  modified: number;
  children: FolderNode[];
}

export interface Layout {
  sort: "custom" | "name" | "recent";
  order: Record<string, string[]>;
}

export interface Tree {
  folders: FolderNode[];
  notes: NoteMeta[];
  layout: Layout;
}

export type FontChoice = "system" | "pretendard" | "serif" | "mono" | "custom";
export type ThemeChoice = "system" | "light" | "dark";
export const ACCENTS = ["yellow", "orange", "red", "pink", "purple", "blue", "green", "graphite"] as const;
export type Accent = (typeof ACCENTS)[number];

export interface Prefs {
  fontFamily: FontChoice;
  customFont: string;
  fontSize: number;
  sidebarCollapsed: boolean;
  noteSort: "modified" | "created" | "name";
  /** 모양 (FR-45) */
  theme: ThemeChoice;
  /** 강조 색 (FR-46) */
  accent: Accent;
}

export const DEFAULT_PREFS: Prefs = {
  fontFamily: "system",
  customFont: "",
  fontSize: 17,
  sidebarCollapsed: false,
  noteSort: "modified",
  theme: "system",
  accent: "yellow",
};

export interface Geometry {
  x: number | null;
  y: number | null;
  w: number;
  h: number;
  onTop: boolean;
}

export interface EntryMoved {
  from: string;
  to: string;
  isDir: boolean;
}

export const api = {
  getVault: () => invoke<string | null>("get_vault"),
  setVault: (path: string) => invoke<void>("set_vault", { path }),
  getPrefs: () => invoke<Prefs>("get_prefs"),
  setPrefs: (prefs: Prefs) => invoke<void>("set_prefs", { prefs }),
  listTree: () => invoke<Tree>("list_tree"),
  readNote: (path: string) => invoke<string>("read_note", { path }),
  writeNote: (path: string, content: string) => invoke<void>("write_note", { path, content }),
  createNote: (folder: string) => invoke<string>("create_note", { folder }),
  syncNoteName: (path: string) => invoke<string>("sync_note_name", { path }),
  trashNote: (path: string) => invoke<void>("trash_note", { path }),
  createFolder: (parent: string, name: string) => invoke<string>("create_folder", { parent, name }),
  renameFolder: (path: string, name: string) => invoke<string>("rename_folder", { path, name }),
  trashFolder: (path: string) => invoke<void>("trash_folder", { path }),
  moveEntry: (from: string, toFolder: string) => invoke<string>("move_entry", { from, toFolder }),
  setLayout: (layout: Layout) => invoke<void>("set_layout", { layout }),
  saveAttachment: (notePath: string, fileName: string, dataBase64: string) =>
    invoke<string>("save_attachment", { notePath, fileName, dataBase64 }),
  /** fresh: ⌘⇧N으로 방금 만든 메모 (BUG-23) */
  openSticky: (path: string, geom: Geometry, fresh = false) => invoke<void>("open_sticky", { path, geom, fresh }),
  /** 그 메모의 스티키 창이 지금 떠 있는지 (BUG-36) */
  hasStickyWindow: (path: string) => invoke<boolean>("has_sticky_window", { path }),
  /** 창을 닫지 않고 숨긴다 (BUG-42) */
  hideStickyWindow: (path: string) => invoke<void>("hide_sticky_window", { path }),
  closeStickyWindow: (path: string) => invoke<void>("close_sticky_window", { path }),
  setStickyOnTop: (path: string, onTop: boolean) => invoke<void>("set_sticky_on_top", { path, onTop }),
  showMain: (path?: string) => invoke<void>("show_main", { path: path ?? null }),
};

export const on = {
  vaultChanged: (f: () => void) => listen("vault-changed", () => f()),
  entryMoved: (f: (e: EntryMoved) => void) => listen<EntryMoved>("entry-moved", (e) => f(e.payload)),
  prefsChanged: (f: (p: Prefs) => void) => listen<Prefs>("prefs-changed", (e) => f(e.payload)),
  menu: (f: (id: string) => void) => listen<string>("menu", (e) => f(e.payload)),
  openNote: (f: (path: string) => void) => listen<{ path: string }>("open-note", (e) => f(e.payload.path)),
  willQuit: (f: () => void) => listen("app-will-quit", () => f()),
  /** 메인 창이 스티키 창에 "다시 넣어라 / 스티키 정보를 지워라"를 요청 (FR-44) */
  putBack: (f: (e: PutBack) => void) => listen<PutBack>("sticky-put-back", (e) => f(e.payload)),
  /** 다시 넣기 요청 뒤 사용자가 다시 꺼냈다 — 그 전 요청은 무효 (BUG-48, 49) */
  putBackCancel: (f: (path: string) => void) => listen<{ path: string }>("sticky-put-back-cancel", (e) => f(e.payload.path)),
  /** 스티키가 다시 넣기 요청을 받았다 (BUG-42) */
  putBackAck: (f: (path: string) => void) => listen<{ path: string }>("sticky-put-back-ack", (e) => f(e.payload.path)),
  /** 스티키가 저장하지 못한 입력이 있어 다시 넣기를 거절했다 (BUG-42) */
  putBackRefused: (f: (path: string) => void) =>
    listen<{ path: string }>("sticky-put-back-refused", (e) => f(e.payload.path)),
};

export interface PutBack {
  path: string;
  /** true면 꺼내 둔 메모에서 빼기(frontmatter sticky 삭제) */
  remove: boolean;
  /** 요청 시각(ms). 늦게 받은 요청인지 가린다 (BUG-48) */
  at?: number;
}

export const requestPutBack = (e: PutBack) => emit("sticky-put-back", e);
export const cancelPutBack = (path: string) => emit("sticky-put-back-cancel", { path });
export const ackPutBack = (path: string) => emit("sticky-put-back-ack", { path });
export const refusePutBack = (path: string) => emit("sticky-put-back-refused", { path });

/** useEffect 정리 함수에서 쓰기 좋은 형태로 */
export function unlistenAll(ps: Promise<UnlistenFn>[]) {
  return () => ps.forEach((p) => p.then((f) => f()));
}

/** 경로가 이동 이벤트로 바뀌었다면 새 경로를 돌려준다 */
export function movedPath(path: string, e: EntryMoved): string | null {
  if (path === e.from) return e.to;
  if (e.isDir && path.startsWith(e.from + "/")) return e.to + path.slice(e.from.length);
  return null;
}

export const folderOf = (path: string) => (path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "");

/**
 * 메모 파일을 읽고 고쳐서 다시 쓴다.
 * 본문은 편집기가, frontmatter는 고정·스티키 기능이 따로 고치므로 항상 디스크 최신본을 기준으로 한다.
 */
export async function updateNote(
  path: string,
  fn: (parts: { front: string | null; body: string }) => { front: string | null; body: string },
): Promise<string> {
  const src = await api.readNote(path);
  const next = joinNote(fn(splitNote(src)));
  if (next !== src) await api.writeNote(path, next);
  return next;
}

export function patchMeta(path: string, patch: MetaPatch) {
  return updateNote(path, ({ front, body }) => ({ front: writeMeta(front, patch), body }));
}

export async function stickyOf(path: string): Promise<StickyMeta | null> {
  return readMeta(splitNote(await api.readNote(path)).front).sticky;
}

/** File → base64 (data: 접두사 없이) */
export function fileToBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).replace(/^data:[^,]*,/, ""));
    r.onerror = () => reject(r.error);
    r.readAsDataURL(file);
  });
}
