import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowSquareIn,
  CaretRight,
  Folder,
  FolderOpen,
  Notebook,
  Plus,
  SidebarSimple,
  SortAscending,
  GearSix,
  HardDrives,
} from "@phosphor-icons/react";
import type { FolderNode, Layout, NoteMeta } from "../lib/api";
import { addSeparator, displaySequence, childrenOf, flattenTree, itemKey, removeKey, type Row } from "../lib/sidebar";
import { drag, isSelfOrDescendant } from "../lib/drag";
import { popupMenu } from "../lib/menu";

export const ALL = "\u0000all";

const COLLAPSED_KEY = "modoit.collapsed";
function loadCollapsed(): Set<string> {
  try {
    return new Set(JSON.parse(localStorage.getItem(COLLAPSED_KEY) ?? "[]"));
  } catch {
    return new Set();
  }
}
function saveCollapsed(s: Set<string>) {
  try {
    localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...s]));
  } catch {
    /* 저장 못 해도 동작에는 문제 없음 */
  }
}

type Zone = "before" | "after" | "inside";
interface DropHint {
  key: string; // 행 키 (폴더 path 또는 구분선 id) 또는 "__end"
  zone: Zone;
}

export interface SidebarActions {
  selectFolder: (f: string) => void;
  setLayout: (l: Layout) => void;
  createFolder: (parent: string, name: string) => Promise<void>;
  renameFolder: (path: string, name: string) => Promise<void>;
  trashFolder: (path: string) => Promise<void>;
  /** 폴더를 destParent 안 beforeKey 앞(null=맨 뒤)으로. 부모가 같으면 순서만 바꾼다 */
  moveFolder: (path: string, destParent: string, beforeKey: string | null, into: boolean) => Promise<void>;
  moveSeparator: (id: string, fromParent: string, destParent: string, beforeKey: string | null) => Promise<void>;
  moveNote: (path: string, folder: string) => Promise<void>;
  openSticky: (path: string) => void;
  putBack: (path: string, remove?: boolean) => void;
  openNote: (path: string) => void;
  changeVault: () => void;
  openSettings: () => void;
  toggleSidebar: () => void;
}

interface Props {
  vault: string;
  folders: FolderNode[];
  notes: NoteMeta[];
  layout: Layout;
  folder: string;
  actions: SidebarActions;
}

const basename = (p: string) => p.split("/").pop() ?? p;

export function Sidebar({ vault, folders, notes, layout, folder, actions }: Props) {
  const [collapsed, setCollapsed] = useState<Set<string>>(loadCollapsed);
  const [creating, setCreating] = useState<string | null>(null); // 새 폴더를 만들 부모
  const [renaming, setRenaming] = useState<string | null>(null);
  const [hint, setHint] = useState<DropHint | null>(null);
  const hoverTimer = useRef<number | undefined>(undefined);

  const rows = useMemo(() => flattenTree(folders, layout, collapsed), [folders, layout, collapsed]);
  const counts = useMemo(() => {
    const m = new Map<string, number>();
    for (const n of notes) m.set(n.folder, (m.get(n.folder) ?? 0) + 1);
    return m;
  }, [notes]);
  // 지금 화면에 떠 있는 스티키만. 넣어 둔 메모는 색·위치만 기억하고 여기에는 보이지 않는다 (FR-31 개정, 2026-11-07 사용자 피드백)
  const stickies = notes.filter((n) => n.sticky?.open);
  const vaultName = vault.split("/").filter(Boolean).pop() ?? vault;

  const toggle = (path: string, open?: boolean) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      const willOpen = open ?? next.has(path);
      if (willOpen) next.delete(path);
      else next.add(path);
      saveCollapsed(next);
      return next;
    });
  };

  // 새 하위 폴더를 만들 때 부모를 펼쳐 둔다
  useEffect(() => {
    if (creating) toggle(creating, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [creating]);

  /** parent 안에서 key 다음 항목의 key (after 놓기용) */
  const nextKey = (parent: string, key: string): string | null => {
    const seq = displaySequence(parent, childrenOf(folders, parent), layout).map(itemKey);
    const i = seq.indexOf(key);
    return i >= 0 && i + 1 < seq.length ? seq[i + 1] : null;
  };

  const zoneFor = (e: React.DragEvent, row: Row): Zone | null => {
    const d = drag.get();
    if (!d) return null;
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const y = (e.clientY - r.top) / r.height;
    if (d.kind === "note") return row.kind === "folder" ? "inside" : null;
    if (row.kind === "sep") return y < 0.5 ? "before" : "after";
    if (d.kind === "folder") {
      if (isSelfOrDescendant(d.path, row.path)) return null;
      if (y < 0.28) return "before";
      if (y > 0.72) return "after";
      return d.parent === row.path ? null : "inside";
    }
    // 구분선은 폴더 안으로 넣지 않는다
    return y < 0.5 ? "before" : "after";
  };

  const onDragOver = (e: React.DragEvent, row: Row) => {
    const z = zoneFor(e, row);
    if (!z) {
      setHint(null);
      return;
    }
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    const key = row.kind === "sep" ? row.id : row.path;
    if (hint?.key !== key || hint.zone !== z) {
      setHint({ key, zone: z });
      window.clearTimeout(hoverTimer.current);
      // 접힌 폴더 위에 잠시 머무르면 펼친다
      if (z === "inside" && row.kind === "folder" && !row.expanded && row.hasChildren) {
        hoverTimer.current = window.setTimeout(() => toggle(row.path, true), 600);
      }
    }
  };

  const onDrop = async (e: React.DragEvent, row: Row | null) => {
    e.preventDefault();
    window.clearTimeout(hoverTimer.current);
    const d = drag.get();
    const z = row ? zoneFor(e, row) : "after";
    setHint(null);
    drag.end();
    if (!d || !z) return;
    if (d.kind === "note") {
      if (row?.kind === "folder") await actions.moveNote(d.path, row.path);
      return;
    }
    // 놓을 부모와 기준 항목
    let destParent = "";
    let beforeKey: string | null = null;
    if (row === null) {
      destParent = "";
      beforeKey = null;
    } else if (z === "inside" && row.kind === "folder") {
      destParent = row.path;
      beforeKey = null;
    } else {
      destParent = row.parent;
      const key = row.kind === "sep" ? row.id : row.name;
      beforeKey = z === "before" ? key : nextKey(row.parent, key);
    }
    if (d.kind === "folder") {
      if (isSelfOrDescendant(d.path, destParent)) return;
      if (beforeKey === d.name && destParent === d.parent) return;
      await actions.moveFolder(d.path, destParent, beforeKey, z === "inside" && row?.kind === "folder");
    } else {
      if (beforeKey === d.id) return;
      await actions.moveSeparator(d.id, d.parent, destParent, beforeKey);
    }
  };

  const folderMenu = (row: Extract<Row, { kind: "folder" }>) =>
    popupMenu([
      { label: "새 하위 폴더", action: () => setCreating(row.path) },
      { label: "이름 변경", action: () => setRenaming(row.path) },
      { label: "아래에 구분선 추가", action: () => actions.setLayout(addSeparator(folders, layout, row.parent, row.name)) },
      "-",
      { label: "휴지통으로 이동", action: () => actions.trashFolder(row.path) },
    ]);

  const sepMenu = (row: Extract<Row, { kind: "sep" }>) =>
    popupMenu([{ label: "구분선 삭제", action: () => actions.setLayout(removeKey(layout, row.parent, row.id)) }]);

  const sortMenu = () =>
    popupMenu([
      { label: "직접 정렬", checked: layout.sort === "custom", action: () => actions.setLayout({ ...layout, sort: "custom" }) },
      { label: "이름순", checked: layout.sort === "name", action: () => actions.setLayout({ ...layout, sort: "name" }) },
      { label: "최신순", checked: layout.sort === "recent", action: () => actions.setLayout({ ...layout, sort: "recent" }) },
      "-",
      { label: "새 폴더", action: () => setCreating("") },
      { label: "맨 아래에 구분선 추가", action: () => {
        const seq = displaySequence("", folders, layout).map(itemKey);
        actions.setLayout(addSeparator(folders, layout, "", seq[seq.length - 1] ?? ""));
      } },
    ]);

  const nameInput = (initial: string, onDone: (v: string | null) => void, depth: number) => (
    <NameInput initial={initial} depth={depth} onDone={onDone} />
  );

  return (
    <aside className="sidebar">
      <div className="titlebar-space" data-tauri-drag-region>
        <div className="grow" data-tauri-drag-region />
        <button className="icon-btn" title="사이드바 가리기 (⌥⌘S)" onClick={actions.toggleSidebar}>
          <SidebarSimple size={20} />
        </button>
      </div>
      <div className="sidebar-scroll">
        <button className={`side-item ${folder === ALL ? "active" : ""}`} onClick={() => actions.selectFolder(ALL)}>
          <span className="caret-space" />
          <Notebook size={18} weight={folder === ALL ? "fill" : "regular"} />
          <span className="label">모든 메모</span>
          <span className="count">{notes.length}</span>
        </button>

        <div className="section-label">
          <span>폴더</span>
          <div className="section-actions">
            <button className="icon-btn small" title="정렬·폴더 메뉴" onClick={sortMenu}>
              <SortAscending size={16} />
            </button>
            <button className="icon-btn small" title="새 폴더 (⌥⌘N)" onClick={() => setCreating("")}>
              <Plus size={16} />
            </button>
          </div>
        </div>

        {creating === "" &&
          nameInput("", async (v) => {
            setCreating(null);
            if (v) await actions.createFolder("", v);
          }, 0)}

        {rows.map((row) => {
          if (row.kind === "sep") {
            const h = hint?.key === row.id ? hint.zone : null;
            return (
              <div
                key={row.id}
                className={`side-sep ${h ? "drop-" + h : ""}`}
                style={{ marginLeft: 8 + row.depth * 16 }}
                draggable
                onDragStart={(e) => drag.start(e, { kind: "sep", id: row.id, parent: row.parent })}
                onDragEnd={() => {
                  drag.end();
                  setHint(null);
                }}
                onDragOver={(e) => onDragOver(e, row)}
                onDragLeave={() => setHint(null)}
                onDrop={(e) => onDrop(e, row)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  sepMenu(row);
                }}
              >
                <span />
              </div>
            );
          }
          const active = folder === row.path;
          const h = hint?.key === row.path ? hint.zone : null;
          return (
            <div key={row.path}>
              {renaming === row.path ? (
                nameInput(row.name, async (v) => {
                  setRenaming(null);
                  if (v && v !== row.name) await actions.renameFolder(row.path, v);
                }, row.depth)
              ) : (
                <div
                  className={`side-item folder-row ${active ? "active" : ""} ${h ? "drop-" + h : ""}`}
                  style={{ paddingLeft: 6 + row.depth * 16 }}
                  draggable
                  onDragStart={(e) => drag.start(e, { kind: "folder", path: row.path, parent: row.parent, name: row.name })}
                  onDragEnd={() => {
                    drag.end();
                    setHint(null);
                  }}
                  onDragOver={(e) => onDragOver(e, row)}
                  onDragLeave={() => {
                    window.clearTimeout(hoverTimer.current);
                    setHint(null);
                  }}
                  onDrop={(e) => onDrop(e, row)}
                  onClick={() => actions.selectFolder(row.path)}
                  onDoubleClick={() => setRenaming(row.path)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    folderMenu(row);
                  }}
                >
                  {row.hasChildren ? (
                    <button
                      className={`caret ${row.expanded ? "open" : ""}`}
                      onClick={(e) => {
                        e.stopPropagation();
                        toggle(row.path);
                      }}
                    >
                      <CaretRight size={13} weight="bold" />
                    </button>
                  ) : (
                    <span className="caret-space" />
                  )}
                  {row.expanded && row.hasChildren ? (
                    <FolderOpen size={18} weight={active ? "fill" : "regular"} />
                  ) : (
                    <Folder size={18} weight={active ? "fill" : "regular"} />
                  )}
                  <span className="label">{row.name}</span>
                  <span className="count">{counts.get(row.path) ?? 0}</span>
                </div>
              )}
              {creating === row.path &&
                nameInput("", async (v) => {
                  setCreating(null);
                  if (v) await actions.createFolder(row.path, v);
                }, row.depth + 1)}
            </div>
          );
        })}
        {/* 맨 아래에 놓으면 최상위 맨 뒤로 */}
        <div
          className={`side-end ${hint?.key === "__end" ? "drop-after" : ""}`}
          onDragOver={(e) => {
            const d = drag.get();
            if (!d || d.kind === "note") return;
            e.preventDefault();
            setHint({ key: "__end", zone: "after" });
          }}
          onDragLeave={() => setHint(null)}
          onDrop={(e) => onDrop(e, null)}
        />

        {stickies.length > 0 && (
          <>
            <div className="section-label">
              <span>꺼내 둔 메모</span>
            </div>
            {stickies.map((n) => {
              const menu = () =>
                popupMenu([
                  { label: "다시 넣기", action: () => actions.putBack(n.path) },
                  { label: "메인 창에서 열기", action: () => actions.openNote(n.path) },
                  "-",
                  { label: "다시 넣고 색·위치 기억 지우기", action: () => actions.putBack(n.path, true) },
                ]);
              return (
                <div
                  key={n.path}
                  className="side-item sticky-row"
                  title="스티키로 꺼내 둠 — 눌러서 앞으로 가져오기"
                  onClick={() => actions.openSticky(n.path)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    menu();
                  }}
                >
                  <span className="caret-space" />
                  <span className={`sticky-dot c-${n.sticky!.color}`} />
                  <span className="label">{n.title || basename(n.path).replace(/\.md$/, "")}</span>
                  <button
                    className="icon-btn small row-action"
                    title="다시 넣기"
                    onClick={(e) => {
                      e.stopPropagation();
                      actions.putBack(n.path);
                    }}
                  >
                    <ArrowSquareIn size={16} />
                  </button>
                </div>
              );
            })}
          </>
        )}
      </div>
      <div className="side-footer">
        <button className="vault-switch" title={vault} onClick={actions.changeVault}>
          <HardDrives size={16} />
          <span className="label">{vaultName}</span>
          <span className="hint">변경</span>
        </button>
        <button className="icon-btn" title="설정 — 모양(다크 모드)·강조 색·글꼴 (⌘,)" onClick={actions.openSettings}>
          <GearSix size={18} />
        </button>
      </div>
    </aside>
  );
}

function NameInput({ initial, depth, onDone }: { initial: string; depth: number; onDone: (v: string | null) => void }) {
  const [v, setV] = useState(initial);
  const done = useRef(false);
  const finish = (val: string | null) => {
    if (done.current) return;
    done.current = true;
    onDone(val);
  };
  return (
    <input
      className="side-input"
      style={{ marginLeft: 6 + depth * 16, width: `calc(100% - ${6 + depth * 16}px)` }}
      autoFocus
      placeholder="폴더 이름"
      value={v}
      onFocus={(e) => e.currentTarget.select()}
      onChange={(e) => setV(e.target.value)}
      onBlur={() => finish(v.trim() || null)}
      onKeyDown={(e) => {
        if (e.key === "Enter") finish(v.trim() || null);
        if (e.key === "Escape") finish(null);
      }}
    />
  );
}
