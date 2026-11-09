/** 스티키 창 = 꺼내 둔 메모 (FR-30, 31, 40). 메인 편집기와 같은 .md 파일을 편집한다. */
import { useCallback, useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { ArrowSquareIn, PushPin, X } from "@phosphor-icons/react";
import { ackPutBack, api, on, unlistenAll, folderOf, patchMeta, refusePutBack } from "../lib/api";
import { DEFAULT_STICKY, readMeta, splitNote, STICKY_COLORS, type StickyMeta } from "../lib/frontmatter";
import { applyPrefs } from "../lib/prefs";
import { unsupportedFeatures } from "../editor/editability";
import { applyMove, flushForQuit, NoteSession } from "../lib/noteSession";
import { ModoitEditor } from "../editor/ModoitEditor";
import "./sticky.css";

const win = getCurrentWindow();

/** fresh: ⌘⇧N으로 방금 만든 메모 — 아무것도 안 쓰고 ✕로 닫으면 정리한다 (BUG-23) */
export function StickyApp({ path: initialPath, fresh = false }: { path: string; fresh?: boolean }) {
  const [vault, setVault] = useState<string | null>(null);
  const [meta, setMeta] = useState<StickyMeta>(DEFAULT_STICKY);
  const [doc, setDoc] = useState<{ key: number; body: string; readOnly: boolean; focus?: boolean } | null>(null);
  const [failing, setFailing] = useState(false);
  const sessionRef = useRef<NoteSession | null>(null);
  const metaRef = useRef<StickyMeta>(DEFAULT_STICKY);
  const keyRef = useRef(0);
  const geomTimer = useRef<number | undefined>(undefined);
  const cancelAt = useRef(0);

  const path = () => sessionRef.current?.path ?? initialPath;

  const show = (body: string, focus = false) => {
    keyRef.current += 1;
    // 지원하지 않는 서식이 있으면 스티키에서도 읽기 전용 (FR-43)
    setDoc({ key: keyRef.current, body, readOnly: unsupportedFeatures(body).length > 0, focus });
  };

  const setMetaBoth = (m: StickyMeta) => {
    metaRef.current = m;
    setMeta(m);
  };

  /** 스티키 정보만 디스크에 반영 (본문은 세션이 따로 저장) */
  const saveMeta = useCallback(async (patch: Partial<StickyMeta>) => {
    const next = { ...metaRef.current, ...patch };
    setMetaBoth(next);
    try {
      await patchMeta(path(), { sticky: next });
    } catch {
      setFailing(true);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 처음 열기
  useEffect(() => {
    api.getVault().then(setVault);
    api.getPrefs().then(applyPrefs);
    (async () => {
      try {
        const { front, body } = splitNote(await api.readNote(initialPath));
        setMetaBoth(readMeta(front).sticky ?? DEFAULT_STICKY);
        const s = new NoteSession(initialPath, body, fresh);
        s.onState = (st) => setFailing(st.failing);
        s.onMerged = (merged) => {
          if (sessionRef.current === s) show(merged, true); // BUG-39
        };
        sessionRef.current = s;
        show(body);
      } catch {
        api.closeStickyWindow(initialPath).catch(() => win.close());
      }
    })();
    return () => sessionRef.current?.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialPath]);

  // 메인 창으로 넘어가면 바로 저장해 두 창 사이 지연을 줄인다 (BUG-26)
  useEffect(() => {
    const flush = () => void sessionRef.current?.flush();
    window.addEventListener("blur", flush);
    return () => window.removeEventListener("blur", flush);
  }, []);

  // 위치·크기 기억 (FR-31)
  useEffect(() => {
    const save = () => {
      window.clearTimeout(geomTimer.current);
      geomTimer.current = window.setTimeout(async () => {
        const [pos, size, scale] = await Promise.all([win.outerPosition(), win.innerSize(), win.scaleFactor()]);
        saveMeta({ x: pos.x / scale, y: pos.y / scale, w: size.width / scale, h: size.height / scale });
      }, 300);
    };
    const offs = [win.onMoved(save), win.onResized(save)];
    return () => offs.forEach((p) => p.then((f) => f()));
  }, [saveMeta]);

  // 메인 창·다른 프로그램에서 바뀐 내용 반영, 이름 변경·이동 따라가기, 지워지면 닫기
  useEffect(() => {
    const reload = async (force = false) => {
      const s = sessionRef.current;
      if (!s) return;
      try {
        const { front, body } = splitNote(await api.readNote(s.path));
        const m = readMeta(front).sticky;
        if (m) setMetaBoth({ ...m, open: true });
        if (!s.dirty && (force || body !== s.saved)) {
          s.saved = body;
          show(body);
        }
      } catch {
        // 파일이 사라졌다
        if (!s.dirty) api.closeStickyWindow(s.path).catch(() => win.close());
      }
    };
    return unlistenAll([
      on.vaultChanged(() => void reload()),
      on.entryMoved((e) => {
        const before = sessionRef.current?.path ?? "";
        applyMove(e);
        const after = sessionRef.current?.path ?? "";
        // 다른 폴더로 옮겨졌다면 링크가 고쳐졌으니 다시 읽는다
        if (before !== after && folderOf(before) !== folderOf(after)) void reload(true);
      }),
      on.prefsChanged(applyPrefs),
      on.willQuit(() => void flushForQuit()),
      on.putBackCancel((p) => {
        if (p === (sessionRef.current?.path ?? initialPath)) cancelAt.current = Date.now();
      }),
      on.putBack((e) => {
        const me = sessionRef.current?.path ?? initialPath;
        if (e.path !== me) return;
        void ackPutBack(me); // 살아 있다고 메인 창에 바로 알린다 (BUG-42)
        void (async () => {
          // 이 요청 뒤에 사용자가 다시 꺼냈으면(메인이 sticky-put-back-cancel을 보냄) 옛 요청은 버린다 (BUG-48, 49)
          await api.hasStickyWindow(me).catch(() => false); // 밀려 있던 이벤트가 먼저 처리되게 한 번 양보
          if (e.at && cancelAt.current >= e.at) return;
          await closeRef.current(false, e.remove);
        })();
      }),
    ]);
  }, []);

  const togglePin = async () => {
    const next = !metaRef.current.onTop;
    await api.setStickyOnTop(path(), next);
    saveMeta({ onTop: next });
  };

  /**
   * 다시 넣기. byUser: 스티키의 ✕ 버튼으로 닫았는지(빈 메모면 정리), remove: 스티키 정보까지 지우기 (FR-44)
   */
  const close = async (byUser: boolean, remove = false) => {
    const s = sessionRef.current;
    if (s) await s.flush();
    // 저장하지 못한 입력이 있으면 창을 닫지 않는다 — 닫으면 입력이 사라진다 (BUG-24, BUG-42)
    if (s?.dirty) {
      setFailing(true);
      if (!byUser) {
        // 메인 창이 숨겨 두었을 수 있으니 다시 보이고, 꺼낸 상태로 되돌린 뒤 거절을 알린다
        await saveMeta({ open: true });
        await api.openSticky(path(), metaRef.current).catch(() => {});
        void refusePutBack(path());
      }
      return;
    }
    const body = s ? s.saved : "";
    if (s && byUser && s.createdNew && !body.trim()) {
      // ⌘⇧N으로 만들고 아무것도 쓰지 않은 스티키만 남기지 않는다 (BUG-23)
      await api.trashNote(s.path).catch(() => {});
    } else if (remove) {
      await patchMeta(path(), { sticky: null }).catch(() => setFailing(true));
    } else {
      await saveMeta({ open: false });
    }
    await api.closeStickyWindow(path()).catch(() => win.close());
  };
  const closeRef = useRef(close);
  closeRef.current = close;

  if (!doc || !vault) return null;

  return (
    <div className={`sticky c-${meta.color}`}>
      <header className="sticky-bar" data-tauri-drag-region>
        <div className="colors">
          {STICKY_COLORS.map((c) => (
            <button
              key={c}
              className={`swatch c-${c} ${c === meta.color ? "on" : ""}`}
              title={c}
              onClick={() => saveMeta({ color: c })}
            />
          ))}
        </div>
        <div className="grow" data-tauri-drag-region />
        {failing && <span className="bar-warn" title="저장하지 못했습니다 — 다시 시도 중">!</span>}
        {doc.readOnly && <span className="bar-ro" title="지원하지 않는 서식이 있어 읽기 전용입니다. 메인 창에서 편집하세요.">읽기 전용</span>}
        <button className={`bar-btn ${meta.onTop ? "on" : ""}`} title="항상 위에 고정" onClick={togglePin}>
          <PushPin size={15} weight={meta.onTop ? "fill" : "regular"} />
        </button>
        <button className="bar-btn" title="메인 창에서 열기" onClick={() => api.showMain(path())}>
          <ArrowSquareIn size={15} />
        </button>
        <button className="bar-btn" title="다시 넣기 (내용은 메모에 그대로)" onClick={() => close(true)}>
          <X size={15} />
        </button>
      </header>
      <ModoitEditor
        key={doc.key}
        compact
        autofocus={(!doc.body.trim() || !!doc.focus) && !doc.readOnly}
        readOnly={doc.readOnly}
        initial={doc.body}
        placeholder="메모…  ( / 명령 )"
        onChange={(md) => {
          if (!doc.readOnly) sessionRef.current?.edit(md);
        }}
        media={{ vault, notePath: path }}
      />
    </div>
  );
}
