/**
 * QA용 가짜 Rust 백엔드 (docs/dev/api-v0.2.md 계약을 메모리 파일 시스템으로 흉내 낸다).
 * 테스트 파일에서 vi.mock("@tauri-apps/api/core" | "@tauri-apps/api/event" | ...)의 구현으로 쓴다.
 * - 명령마다 IPC 지연(기본 2ms)을 둔다.
 * - 파일을 바꾸는 명령 뒤에는 감시기처럼 250ms 묶음으로 vault-changed를 보낸다.
 * - 제목·파일 이름 규칙은 실제 Rust보다 단순하다(첫 줄의 #, -, [ ] 기호만 뗀다). 이름 규칙 자체는 Rust 하네스에서 검증한다.
 */
import { readMeta, splitNote } from "../lib/frontmatter";

export interface FakeFile {
  content: string;
  mtime: number;
  /** true면 read_note가 NOT_UTF8 오류 */
  notUtf8?: boolean;
  /** 생성 시각(ms). 없으면 mtime (FR-47) */
  created?: number;
}

type Handler = (e: { payload: unknown }) => void;

export interface Call {
  cmd: string;
  args: Record<string, unknown>;
}

export class FakeBackend {
  files = new Map<string, FakeFile>();
  folders = new Set<string>(["메모"]);
  calls: Call[] = [];
  listeners = new Map<string, Set<Handler>>();
  prefs = { fontFamily: "system", customFont: "", fontSize: 17, sidebarCollapsed: false, noteSort: "modified", theme: "system", accent: "yellow" };
  layout: { sort: string; order: Record<string, string[]> } = { sort: "custom", order: {} };
  openStickies = new Set<string>();
  /** 숨겼지만 닫지 않은 스티키 창 (Rust sticky::hide — has_sticky_window는 false) */
  hiddenStickies = new Set<string>();
  clock = 1_000_000;
  ipcDelay = 2;
  watch = true;
  /** 이 경로에 쓰기를 시도하면 실패시킨다 */
  failWrite: (path: string) => boolean = () => false;
  failSync: (path: string) => boolean = () => false;
  private watchTimer: ReturnType<typeof setTimeout> | undefined;

  reset() {
    this.files.clear();
    this.folders = new Set(["메모"]);
    this.calls = [];
    this.listeners.clear();
    this.prefs = { fontFamily: "system", customFont: "", fontSize: 17, sidebarCollapsed: false, noteSort: "modified", theme: "system", accent: "yellow" };
    this.layout = { sort: "custom", order: {} };
    this.openStickies.clear();
    this.hiddenStickies.clear();
    this.ipcDelay = 2;
    this.watch = true;
    this.failWrite = () => false;
    this.failSync = () => false;
    clearTimeout(this.watchTimer);
  }

  put(path: string, content: string, extra: Partial<FakeFile> = {}) {
    const created = this.files.get(path)?.created;
    this.files.set(path, { content, mtime: ++this.clock, ...(created !== undefined ? { created } : {}), ...extra });
    const dir = dirOf(path);
    if (dir) this.folders.add(dir);
  }

  /** 다른 프로그램이 파일을 바꾼 것처럼 */
  externalWrite(path: string, content: string) {
    this.put(path, content);
    this.changed();
  }

  /** 앱이 부른 명령 중 이름이 같은 것 */
  callsOf(cmd: string) {
    return this.calls.filter((c) => c.cmd === cmd);
  }

  writes() {
    return this.calls.filter((c) => ["write_note", "sync_note_name", "trash_note", "move_entry"].includes(c.cmd));
  }

  emit(event: string, payload: unknown = null) {
    for (const h of [...(this.listeners.get(event) ?? [])]) h({ payload });
  }

  listen(event: string, h: Handler) {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(h);
    return () => {
      this.listeners.get(event)?.delete(h);
    };
  }

  changed() {
    if (!this.watch) return;
    clearTimeout(this.watchTimer);
    this.watchTimer = setTimeout(() => this.emit("vault-changed"), 250);
  }

  async invoke(cmd: string, args: Record<string, unknown> = {}): Promise<unknown> {
    this.calls.push({ cmd, args });
    await new Promise((r) => setTimeout(r, this.ipcDelay));
    return this.run(cmd, args);
  }

  private run(cmd: string, a: Record<string, unknown>): unknown {
    const s = (k: string) => String(a[k] ?? "");
    switch (cmd) {
      case "get_vault":
        return "/v";
      case "set_vault":
        return null;
      case "get_prefs":
        return { ...this.prefs };
      case "set_prefs": {
        // Rust config::Prefs::normalized()와 같이 다듬은 뒤 모든 창에 보낸다
        const p = { ...(a.prefs as typeof this.prefs) };
        p.customFont = p.customFont.trim();
        p.fontSize = Math.min(22, Math.max(14, p.fontSize));
        this.prefs = p;
        setTimeout(() => this.emit("prefs-changed", { ...p }), 1);
        return null;
      }
      case "list_tree":
        return this.tree();
      case "read_note": {
        const f = this.files.get(s("path"));
        if (!f) throw new Error("No such file or directory (os error 2)");
        if (f.notUtf8) throw "NOT_UTF8";
        return f.content;
      }
      case "write_note": {
        if (this.failWrite(s("path"))) throw "Permission denied (os error 13)";
        this.put(s("path"), s("content"));
        this.changed();
        return null;
      }
      case "create_note": {
        const folder = s("folder") || "메모";
        this.folders.add(folder);
        const p = this.unique(folder, "새 메모");
        this.put(p, "");
        this.changed();
        return p;
      }
      case "sync_note_name": {
        const from = s("path");
        const f = this.files.get(from);
        if (!f) throw new Error("없음: " + from);
        if (this.failSync(from)) throw "Operation not permitted (os error 1)";
        const base = fileBase(titleOf(f.content));
        const cur = from.slice(from.lastIndexOf("/") + 1).replace(/\.md$/, "");
        if (cur === base) return from;
        const to = this.unique(dirOf(from), base, from);
        if (to === from) return from;
        this.files.delete(from);
        this.files.set(to, f);
        if (this.openStickies.delete(from)) this.openStickies.add(to);
        this.emit("entry-moved", { from, to, isDir: false });
        this.changed();
        return to;
      }
      case "trash_note": {
        if (!this.files.delete(s("path"))) throw new Error("없음");
        this.openStickies.delete(s("path"));
        this.hiddenStickies.delete(s("path"));
        this.changed();
        return null;
      }
      case "move_entry": {
        const from = s("from");
        const dest = s("toFolder");
        const f = this.files.get(from);
        if (!f) throw new Error("없음");
        const name = from.slice(from.lastIndexOf("/") + 1).replace(/\.md$/, "");
        const to = this.unique(dest, name);
        this.files.delete(from);
        this.files.set(to, f);
        this.emit("entry-moved", { from, to, isDir: false });
        this.changed();
        return to;
      }
      case "create_folder": {
        const p = (s("parent") ? s("parent") + "/" : "") + s("name");
        this.folders.add(p);
        return p;
      }
      case "set_layout":
        this.layout = a.layout as typeof this.layout;
        return null;
      case "save_attachment":
        return "../attachments/20261107-120000-abcd.png";
      case "open_sticky":
        // 이미 있는 창(숨긴 창 포함)이면 그 창을 다시 보인다
        this.hiddenStickies.delete(s("path"));
        this.openStickies.add(s("path"));
        return null;
      case "has_sticky_window":
        return this.openStickies.has(s("path"));
      case "hide_sticky_window":
        if (this.openStickies.delete(s("path"))) this.hiddenStickies.add(s("path"));
        return null;
      case "close_sticky_window":
        this.openStickies.delete(s("path"));
        this.hiddenStickies.delete(s("path"));
        return null;
      case "set_sticky_on_top":
      case "show_main":
      case "rename_folder":
      case "trash_folder":
        return null;
      default:
        throw new Error("알 수 없는 명령: " + cmd);
    }
  }

  private unique(dir: string, base: string, own?: string) {
    for (let n = 1; ; n++) {
      const p = (dir ? dir + "/" : "") + (n === 1 ? base : `${base} ${n}`) + ".md";
      if (p === own || !this.files.has(p)) return p;
    }
  }

  private tree() {
    const notes = [...this.files.entries()]
      .sort((x, y) => y[1].mtime - x[1].mtime)
      .map(([path, f]) => {
        const { front } = splitNote(f.content);
        const m = readMeta(front);
        return {
          path,
          folder: dirOf(path),
          title: f.notUtf8 ? "" : titleOf(f.content),
          preview: "",
          modified: f.mtime,
          created: f.created ?? f.mtime,
          pinned: m.pinned,
          sticky: m.legacy ? null : m.sticky,
          readable: !f.notUtf8,
        };
      });
    const folders = [...this.folders]
      .filter((p) => !p.includes("/"))
      .sort()
      .map((p) => ({ path: p, name: p, modified: 0, children: [] }));
    return { folders, notes, layout: this.layout };
  }
}

export const dirOf = (p: string) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "");

/** 간단한 제목 규칙: frontmatter를 건너뛴 첫 의미 있는 줄에서 블록 기호를 뗀다 */
export function titleOf(content: string) {
  const { body } = splitNote(content);
  for (const line of body.split("\n")) {
    const t = line
      .trim()
      .replace(/^(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s*)/, "")
      .replace(/^\[[ xX]\]\s*/, "")
      .trim();
    if (t && !/^(-{3,}|!\[.*\]\(.*\))$/.test(t)) return t;
  }
  return "";
}

const fileBase = (t: string) => t.replace(/[/\\:*?"<>|]/g, " ").replace(/\s+/g, " ").trim().slice(0, 60) || "새 메모";

/** 싱글턴: 테스트 파일의 vi.mock 팩토리에서 쓴다 */
export const fake = new FakeBackend();

export const tauriCore = {
  invoke: (cmd: string, args?: Record<string, unknown>) => fake.invoke(cmd, args),
  convertFileSrc: (p: string) => "asset://localhost/" + encodeURIComponent(p),
};

export const tauriEvent = {
  listen: async (event: string, h: Handler) => fake.listen(event, h),
  emit: async (event: string, payload?: unknown) => {
    await new Promise((r) => setTimeout(r, 1));
    fake.emit(event, payload ?? null);
  },
};

/** 스티키 창용 getCurrentWindow 가짜 */
export const fakeWindow = {
  outerPosition: async () => ({ x: 100, y: 100 }),
  innerSize: async () => ({ width: 280, height: 280 }),
  scaleFactor: async () => 2,
  onMoved: async () => () => {},
  onResized: async () => () => {},
  close: async () => {},
};
