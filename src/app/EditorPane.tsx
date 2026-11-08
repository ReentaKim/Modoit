import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowSquareIn, ArrowSquareOut, Trash, Warning } from "@phosphor-icons/react";
import { api, on, unlistenAll, folderOf, type NoteMeta } from "../lib/api";
import { splitNote } from "../lib/frontmatter";
import { unsupportedFeatures } from "../editor/editability";
import { NoteSession } from "../lib/noteSession";
import { ModoitEditor } from "../editor/ModoitEditor";

interface Props {
  vault: string;
  path: string | null;
  meta: NoteMeta | null;
  /** 이번 실행에서 앱이 새로 만든 메모인지 (비어 있으면 떠날 때 정리) */
  isNew: (path: string) => boolean;
  autofocusPath: string | null;
  onDelete: (path: string) => void;
  /** 꺼내기 ↔ 다시 넣기 (FR-44) */
  onToggleSticky: (path: string) => void;
  onMissing: () => void;
  onNotice: (msg: string) => void;
}

interface Doc {
  key: number;
  body: string;
  /** 지원하지 않는 서식 목록 — 있으면 읽기 전용 (FR-43) */
  unsupported: string[];
  forceEdit: boolean;
  notUtf8?: boolean;
  /** 다시 보여 줄 때 커서를 끝에 둔다 (병합 후) */
  focus?: boolean;
}

export function EditorPane({ vault, path, meta, isNew, autofocusPath, onDelete, onToggleSticky, onMissing, onNotice }: Props) {
  const [doc, setDoc] = useState<Doc | null>(null);
  const [failing, setFailing] = useState(false);
  const sessionRef = useRef<NoteSession | null>(null);
  const keyRef = useRef(0);
  const reqRef = useRef(0);

  const show = useCallback((body: string, extra: Partial<Doc> = {}) => {
    keyRef.current += 1;
    setDoc({ key: keyRef.current, body, unsupported: unsupportedFeatures(body), forceEdit: false, ...extra });
  }, []);

  /** 메모 하나를 열어 새 세션을 만든다 */
  const open = useCallback(
    async (p: string, req: number) => {
      let src: string;
      try {
        src = await api.readNote(p);
        if (req !== reqRef.current) return; // 그사이 다른 메모를 골랐다
      } catch (e) {
        if (req !== reqRef.current) return;
        if (String(e).includes("NOT_UTF8")) {
          sessionRef.current = null;
          keyRef.current += 1;
          setDoc({ key: keyRef.current, body: "", unsupported: [], forceEdit: false, notUtf8: true });
        } else onMissing();
        return;
      }
      const { body } = splitNote(src);
      const s = new NoteSession(p, body, isNew(p));
      s.onState = (st) => setFailing(st.failing);
      // 다른 창에서 동시에 고친 내용과 병합했으면 병합 결과를 보여 준다 (BUG-26)
      // 입력 중이어도 보여 준다: 화면이 상대 줄을 모르면 다음 저장이 그 줄을 덮어쓴다 (BUG-39)
      s.onMerged = (merged) => {
        if (sessionRef.current === s) show(merged, { focus: true });
      };
      sessionRef.current = s;
      setFailing(false);
      show(body);
    },
    [isNew, onMissing, show],
  );

  /** 지금 세션을 저장하고 닫는다. 이번에 만든 빈 메모면 휴지통으로 (BUG-04).
   *  저장에 실패 중이면 닫지 않고 뒤에서 계속 다시 시도한다 (BUG-24) */
  const leave = useCallback(
    async (s: NoteSession | null) => {
      if (!s) return;
      await s.flush();
      const body = s.pending ?? s.saved;
      if (!s.release()) {
        onNotice("이전 메모를 아직 저장하지 못했습니다. 저장될 때까지 계속 다시 시도합니다.");
        return;
      }
      if (s.createdNew && !body.trim()) api.trashNote(s.path).catch(() => {});
    },
    [onNotice],
  );

  // 선택이 바뀌면 이전 세션은 혼자 저장되게 두고 바로 새 메모를 연다 (BUG-02)
  useEffect(() => {
    const cur = sessionRef.current;
    if (path !== null && cur && cur.path === path) return;
    sessionRef.current = null;
    const req = ++reqRef.current;
    void leave(cur);
    if (path) void open(path, req);
    else setDoc(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path]);

  // 다른 곳(스티키, Finder, 다른 편집기)에서 본문이 바뀌면 다시 읽기. 이동으로 폴더가 바뀌어도 다시 읽기(링크가 고쳐졌으므로)
  useEffect(() => {
    let lastFolder = path ? folderOf(path) : "";
    const reloadIfChanged = async () => {
      const s = sessionRef.current;
      if (!s || s.dirty) return;
      try {
        const { body } = splitNote(await api.readNote(s.path));
        if (sessionRef.current === s && !s.dirty && body !== s.saved) {
          s.saved = body;
          show(body);
        }
      } catch {
        /* 이름이 바뀌는 중일 수 있다 — 선택은 entry-moved가 처리 */
      }
    };
    return unlistenAll([
      on.vaultChanged(reloadIfChanged),
      on.entryMoved(() => {
        const s = sessionRef.current;
        if (!s) return;
        const f = folderOf(s.path);
        if (f !== lastFolder) {
          lastFolder = f;
          void reloadIfChanged();
        }
      }),
    ]);
  }, [path, show]);

  // 창을 닫거나 숨기거나 다른 창(스티키)으로 넘어갈 때 남은 내용 바로 저장 (BUG-26: 창 사이 지연 줄이기)
  useEffect(() => {
    const flush = () => void sessionRef.current?.flush();
    document.addEventListener("visibilitychange", flush);
    window.addEventListener("beforeunload", flush);
    window.addEventListener("blur", flush);
    return () => {
      document.removeEventListener("visibilitychange", flush);
      window.removeEventListener("beforeunload", flush);
      window.removeEventListener("blur", flush);
    };
  }, []);

  if (!path || !doc) {
    return (
      <main className="editor-pane empty">
        <div className="toolbar" data-tauri-drag-region />
        <div className="editor-empty">메모를 선택하거나 ⌘N으로 새로 만드세요</div>
      </main>
    );
  }

  const readOnly = doc.unsupported.length > 0 && !doc.forceEdit;

  return (
    <main className="editor-pane">
      <div className="toolbar" data-tauri-drag-region>
        <div className="toolbar-spacer" data-tauri-drag-region />
        <button
          className={`icon-btn ${meta?.sticky?.open ? "on" : ""}`}
          title={meta?.sticky?.open ? "스티키 다시 넣기 (⌘⇧S)" : "스티키로 꺼내기 (⌘⇧S)"}
          disabled={!!doc.notUtf8}
          onClick={() => onToggleSticky(sessionRef.current?.path ?? path)}
        >
          {meta?.sticky?.open ? <ArrowSquareIn size={20} weight="bold" /> : <ArrowSquareOut size={20} />}
        </button>
        <button
          className="icon-btn"
          title="휴지통으로 이동"
          onClick={() => {
            // 지운 파일을 저장 타이머가 되살리지 않도록 먼저 끊는다
            const s = sessionRef.current;
            s?.cancel();
            s?.close();
            sessionRef.current = null;
            setDoc(null);
            onDelete(s?.path ?? path);
          }}
        >
          <Trash size={20} />
        </button>
      </div>
      {failing && (
        <div className="banner error">
          <Warning size={18} weight="fill" />
          <span>저장하지 못했습니다 — 다시 시도 중…</span>
        </div>
      )}
      {readOnly && (
        <div className="banner">
          <span>
            이 메모에는 Modoit이 지원하지 않는 서식({doc.unsupported.join(", ")})이 있어 읽기 전용으로 열었습니다.
          </span>
          <button
            className="banner-btn"
            onClick={() => {
              onNotice("편집하면 지원하지 않는 서식은 바뀔 수 있습니다.");
              setDoc({ ...doc, forceEdit: true });
            }}
          >
            그래도 편집
          </button>
        </div>
      )}
      {meta && <div className="editor-date">{dateLine(meta.created, meta.modified)}</div>}
      {doc.notUtf8 ? (
        <div className="editor-empty">이 파일은 UTF-8이 아닌 인코딩이라 열 수 없습니다.</div>
      ) : (
        <ModoitEditor
          key={doc.key}
          initial={doc.body}
          readOnly={readOnly}
          onChange={(md) => {
            if (!readOnly) sessionRef.current?.edit(md);
          }}
          autofocus={autofocusPath === path || !!doc.focus}
          placeholder="제목을 입력하고 Enter…   ( / 명령,  - 점 목록,  [ ] 체크박스,  Tab 들여쓰기 )"
          media={{
            vault,
            notePath: () => sessionRef.current?.path ?? path,
            onError: onNotice,
          }}
        />
      )}
    </main>
  );
}

const FULL: Intl.DateTimeFormatOptions = { year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "2-digit" };
const TIME: Intl.DateTimeFormatOptions = { hour: "numeric", minute: "2-digit" };

/** "만든 날 2026년 11월 7일 오후 5:22  ·  고친 날 오후 6:34" — 같은 날이면 고친 날은 시각만 (FR-47) */
function dateLine(created: number, modified: number): string {
  const c = new Date(created);
  const m = new Date(modified);
  const sameDay = c.toDateString() === m.toDateString();
  const made = `만든 날 ${c.toLocaleString("ko-KR", FULL)}`;
  if (Math.abs(modified - created) < 60_000) return made;
  return `${made}  ·  고친 날 ${m.toLocaleString("ko-KR", sameDay ? TIME : FULL)}`;
}
