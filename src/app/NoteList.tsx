import type { RefObject } from "react";
import { MagnifyingGlass, NotePencil, PushPin, SidebarSimple, SortAscending } from "@phosphor-icons/react";
import type { NoteMeta, Prefs } from "../lib/api";
import { drag } from "../lib/drag";
import { popupMenu } from "../lib/menu";

interface Props {
  notes: NoteMeta[];
  selected: string | null;
  onSelect: (path: string) => void;
  query: string;
  onQuery: (q: string) => void;
  searchRef: RefObject<HTMLInputElement | null>;
  onNew: () => void;
  showFolder: boolean;
  sort: Prefs["noteSort"];
  onSort: (s: Prefs["noteSort"]) => void;
  sidebarCollapsed: boolean;
  onToggleSidebar: () => void;
  onPin: (path: string, pinned: boolean) => void;
  onPopOut: (path: string) => void;
  onPutBack: (path: string, remove?: boolean) => void;
  onTrash: (path: string) => void;
}

const DAY = 86_400_000;

function startOfToday() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function groupOf(ms: number, today: number) {
  if (ms >= today) return "오늘";
  if (ms >= today - DAY) return "어제";
  if (ms >= today - 7 * DAY) return "지난 7일";
  if (ms >= today - 30 * DAY) return "지난 30일";
  return new Date(ms).getFullYear() + "년";
}

function shortDate(ms: number, today: number) {
  const d = new Date(ms);
  if (ms >= today) return d.toLocaleTimeString("ko-KR", { hour: "numeric", minute: "2-digit" });
  if (ms >= today - DAY) return "어제";
  return `${d.getFullYear()}. ${d.getMonth() + 1}. ${d.getDate()}.`;
}

const titleOf = (n: NoteMeta) => n.title || "새로운 메모";

export function NoteList(p: Props) {
  const today = startOfToday();
  // 행의 날짜와 날짜 묶음은 정렬 기준 날짜를 따른다 (FR-47)
  const dateOf = (n: NoteMeta) => (p.sort === "created" ? n.created : n.modified);
  const sorted = [...p.notes].sort((a, b) =>
    p.sort === "name" ? titleOf(a).localeCompare(titleOf(b), "ko", { numeric: true }) : dateOf(b) - dateOf(a),
  );
  const pinned = sorted.filter((n) => n.pinned);
  const rest = sorted.filter((n) => !n.pinned);

  const rows: Array<{ group: string; pin?: boolean } | { note: NoteMeta }> = [];
  if (pinned.length) {
    rows.push({ group: "고정됨", pin: true });
    pinned.forEach((note) => rows.push({ note }));
  }
  let last = "";
  for (const n of rest) {
    const g = p.sort === "name" ? (pinned.length ? "메모" : "") : groupOf(dateOf(n), today);
    if (g && g !== last) {
      rows.push({ group: g });
      last = g;
    }
    rows.push({ note: n });
  }

  const rowMenu = (n: NoteMeta) =>
    popupMenu([
      { label: n.pinned ? "고정 해제" : "고정", action: () => p.onPin(n.path, !n.pinned) },
      n.sticky?.open
        ? { label: "스티키 다시 넣기", action: () => p.onPutBack(n.path) }
        : { label: "스티키로 꺼내기", action: () => p.onPopOut(n.path) },
      ...(n.sticky ? [{ label: "스티키 색·위치 기억 지우기", action: () => p.onPutBack(n.path, true) }] : []),
      "-",
      { label: "휴지통으로 이동", action: () => p.onTrash(n.path) },
    ]);

  const sortMenu = () =>
    popupMenu([
      { label: "수정일순", checked: p.sort === "modified", action: () => p.onSort("modified") },
      { label: "만든 날짜순", checked: p.sort === "created", action: () => p.onSort("created") },
      { label: "이름순", checked: p.sort === "name", action: () => p.onSort("name") },
    ]);

  return (
    <section className={`notelist ${p.sidebarCollapsed ? "with-lights" : ""}`}>
      <div className="toolbar" data-tauri-drag-region>
        {p.sidebarCollapsed && (
          <button className="icon-btn" title="사이드바 보기 (⌥⌘S)" onClick={p.onToggleSidebar}>
            <SidebarSimple size={20} />
          </button>
        )}
        <div className="search">
          <MagnifyingGlass size={16} />
          <input
            ref={p.searchRef}
            placeholder="검색"
            value={p.query}
            onChange={(e) => p.onQuery(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && p.onQuery("")}
          />
        </div>
        <button className="icon-btn" title="정렬" onClick={sortMenu}>
          <SortAscending size={20} />
        </button>
        <button className="icon-btn" title="새 메모 (⌘N)" onClick={p.onNew}>
          <NotePencil size={20} />
        </button>
      </div>
      <div className="notelist-scroll">
        {p.notes.length === 0 && (
          <div className="list-empty">{p.query ? "검색 결과가 없습니다" : "메모 없음"}</div>
        )}
        {rows.map((r) =>
          "group" in r ? (
            <div key={"g:" + r.group} className="group-label">
              {r.pin && <PushPin size={14} weight="fill" />}
              {r.group}
            </div>
          ) : (
            <button
              key={r.note.path}
              className={`note-row ${p.selected === r.note.path ? "active" : ""}`}
              draggable
              onDragStart={(e) => drag.start(e, { kind: "note", path: r.note.path })}
              onDragEnd={() => drag.end()}
              onClick={() => p.onSelect(r.note.path)}
              onContextMenu={(e) => {
                e.preventDefault();
                rowMenu(r.note);
              }}
            >
              <div className="note-title">
                <span className="t">{titleOf(r.note)}</span>
                {r.note.sticky?.open && (
                  <span className={`sticky-dot small c-${r.note.sticky.color}`} title="스티키로 꺼내져 있음" />
                )}
              </div>
              <div className="note-sub">
                <span className="note-date" title={p.sort === "created" ? "만든 날" : "고친 날"}>
                  {shortDate(dateOf(r.note), today)}
                </span>
                <span className="note-preview">
                  {r.note.readable ? r.note.preview || "추가 텍스트 없음" : "지원하지 않는 인코딩"}
                </span>
              </div>
              {p.showFolder && r.note.folder && <div className="note-folder">{r.note.folder}</div>}
            </button>
          ),
        )}
      </div>
    </section>
  );
}
