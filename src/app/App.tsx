import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ask, open as openDialog } from "@tauri-apps/plugin-dialog";
import {
  api,
  on,
  unlistenAll,
  movedPath,
  patchMeta,
  requestPutBack,
  cancelPutBack,
  stickyOf,
  DEFAULT_PREFS,
  type Layout,
  type NoteMeta,
  type Prefs,
  type Tree,
} from "../lib/api";
import { DEFAULT_STICKY } from "../lib/frontmatter";
import { applyPrefs } from "../lib/prefs";
import { applyMove, discardUnder, flushAll, flushAndResolve, onBackgroundFailures, unsavedCount } from "../lib/noteSession";
import { childrenOf, customSequence, itemKey, reorder, removeKey } from "../lib/sidebar";
import { Sidebar, ALL, type SidebarActions } from "./Sidebar";
import { NoteList } from "./NoteList";
import { EditorPane } from "./EditorPane";
import { Welcome } from "./Welcome";
import { Settings } from "./Settings";
import "./app.css";
import "./accent.css";

/** 스티키가 다시 넣기 요청을 받았다는 응답을 ms 안에 받으면 true (BUG-42) */
function waitForAck(path: string, ms: number): Promise<boolean> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v: boolean) => {
      if (done) return;
      done = true;
      window.clearTimeout(timer);
      void off.then((f) => f());
      resolve(v);
    };
    const off = on.putBackAck((p) => p === path && finish(true));
    const timer = window.setTimeout(() => finish(false), ms);
  });
}

export function App() {
  const [vault, setVault] = useState<string | null | undefined>(undefined);
  const [prefs, setPrefs] = useState<Prefs>(DEFAULT_PREFS);

  useEffect(() => {
    api.getVault().then(setVault);
    api.getPrefs().then((p) => {
      setPrefs(p);
      applyPrefs(p);
    });
    // prefs-changed는 듣지 않는다: 설정을 바꾸는 곳은 이 창뿐이고, Rust가 정리(trim)해 되돌려 준 값으로
    // 입력 칸을 덮어쓰면 치는 중인 공백이 사라진다 (BUG-27). 스티키 창만 이 이벤트로 설정을 따라간다.
  }, []);

  const pickVault = useCallback(async () => {
    const dir = await openDialog({ directory: true, title: "메모를 저장할 폴더를 선택하세요" });
    if (typeof dir === "string") {
      await flushAll();
      if (unsavedCount() > 0) {
        // 저장하지 못한 입력을 두고 폴더를 바꾸면 그 입력이 사라진다 (BUG-24). 막아 두기만 하면 영영 못 바꿀 수 있으니 고르게 한다 (BUG-40)
        const discard = await ask(
          `저장하지 못한 메모 ${unsavedCount()}개가 있습니다. 바꾸면 그 입력은 사라집니다. 그래도 저장 폴더를 바꿀까요?`,
          { title: "저장 폴더 변경", kind: "warning", okLabel: "버리고 바꾸기", cancelLabel: "취소" },
        );
        if (!discard) return;
        discardUnder("");
      }
      await api.setVault(dir);
      setVault(dir);
    }
  }, []);

  const updatePrefs = useCallback(
    (patch: Partial<Prefs>) => {
      const next = { ...prefs, ...patch };
      setPrefs(next);
      applyPrefs(next);
      api.setPrefs(next).catch(console.error);
    },
    [prefs],
  );

  if (vault === undefined) return null;
  if (vault === null) return <Welcome onPick={pickVault} />;
  return <Workspace key={vault} vault={vault} prefs={prefs} updatePrefs={updatePrefs} onChangeVault={pickVault} />;
}

interface WorkspaceProps {
  vault: string;
  prefs: Prefs;
  updatePrefs: (p: Partial<Prefs>) => void;
  onChangeVault: () => void;
}

function Workspace({ vault, prefs, updatePrefs, onChangeVault }: WorkspaceProps) {
  const [tree, setTree] = useState<Tree>({ folders: [], notes: [], layout: { sort: "custom", order: {} } });
  const [folder, setFolder] = useState<string>(ALL);
  const [selected, setSelected] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [justCreated, setJustCreated] = useState<string | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const createdRef = useRef(new Set<string>());
  const searchRef = useRef<HTMLInputElement>(null);
  const selectedRef = useRef(selected);
  selectedRef.current = selected;

  const refresh = useCallback(async () => {
    const t = await api.listTree();
    setTree(t);
    return t;
  }, []);

  const toast = useCallback((msg: string) => {
    setNotice(msg);
    window.setTimeout(() => setNotice((m) => (m === msg ? null : m)), 3500);
  }, []);

  const fail = useCallback((e: unknown) => toast(String(e)), [toast]);

  // ── 스티키 ──
  const popOut = useCallback(
    async (target: string) => {
      try {
        // 저장하며 파일 이름이 제목에 맞춰 바뀔 수 있으므로 저장 뒤 경로를 쓴다 (BUG-28)
        const path = await flushAndResolve(target);
        const cur = (await stickyOf(path)) ?? { ...DEFAULT_STICKY };
        const meta = { ...cur, open: true };
        await patchMeta(path, { sticky: meta });
        await cancelPutBack(path); // 숨겨 둔 스티키의 옛 다시 넣기 요청 무효화 (BUG-48)
        await api.openSticky(path, meta);
        refresh();
      } catch (e) {
        fail(e);
      }
    },
    [refresh, fail],
  );

  /** 다시 넣기 / 꺼내 둔 메모에서 빼기 (FR-44) */
  const putBack = useCallback(
    async (target: string, remove = false) => {
      try {
        const path = await flushAndResolve(target);
        if (await api.hasStickyWindow(path)) {
          // 열린 스티키가 입력 중이던 내용을 저장한 뒤 스스로 닫는다. 받았다는 응답을 기다린다
          const acked = waitForAck(path, 500);
          await requestPutBack({ path, remove, at: Date.now() });
          if (!(await acked)) {
            // 가려진 스티키는 macOS가 스크립트를 늦춰 응답이 없다(BUG-38).
            // 창을 닫으면 저장 전 입력이 사라질 수 있으므로 숨기기만 한다.
            // 스티키가 깨어나면 저장한 뒤 스스로 닫는다 (BUG-42)
            await api.hideStickyWindow(path);
            const cur = await stickyOf(path);
            if (remove) await patchMeta(path, { sticky: null });
            else if (cur?.open) await patchMeta(path, { sticky: { ...cur, open: false } });
          }
        } else {
          // 창이 없으면(동기화된 메모, 창 열기 실패 등) 파일만 고친다 (BUG-36)
          const cur = await stickyOf(path);
          if (remove) await patchMeta(path, { sticky: null });
          else if (cur?.open) await patchMeta(path, { sticky: { ...cur, open: false } });
        }
        window.setTimeout(() => void refresh(), 400);
      } catch (e) {
        fail(e);
      }
    },
    [refresh, fail],
  );

  // 실제로 창이 떠 있는지를 기준으로 꺼내기 ↔ 다시 넣기 (BUG-36)
  const toggleSticky = useCallback(
    async (target: string) => {
      const path = await flushAndResolve(target);
      return (await api.hasStickyWindow(path)) ? putBack(path) : popOut(path);
    },
    [putBack, popOut],
  );

  // 스티키가 저장하지 못한 입력이 있어 다시 넣기를 거절했다 (BUG-42)
  useEffect(
    () =>
      unlistenAll([
        on.putBackRefused(() => toast("스티키에 아직 저장하지 못한 입력이 있어 넣지 않았습니다. 저장되면 다시 시도하세요.")),
      ]),
    [toast],
  );

  // 화면에서 떠난 메모가 뒤에서 저장에 실패하고 있으면 알린다 (BUG-24)
  useEffect(() => {
    onBackgroundFailures((n) => {
      if (n > 0) toast(`저장하지 못한 메모 ${n}개 — 계속 다시 시도 중입니다`);
    });
    return () => onBackgroundFailures(undefined);
  }, [toast]);

  // 처음 열 때: 목록 읽고, 꺼내 둔 메모를 다시 띄우기 (FR-31)
  useEffect(() => {
    refresh().then((t) => {
      for (const n of t.notes) if (n.sticky?.open) api.openSticky(n.path, n.sticky).catch(console.error);
    });
  }, [refresh]);

  // 이벤트: 파일 변경, 이름 변경·이동, 다른 창에서 메모 열기, 종료 직전
  useEffect(
    () =>
      unlistenAll([
        on.vaultChanged(() => void refresh()),
        on.entryMoved((e) => {
          applyMove(e);
          setSelected((s) => (s ? movedPath(s, e) ?? s : s));
          setFolder((f) => (f === ALL ? f : movedPath(f, e) ?? f));
          setJustCreated((j) => (j ? movedPath(j, e) ?? j : j));
          const created = createdRef.current;
          for (const p of [...created]) {
            const np = movedPath(p, e);
            if (np) {
              created.delete(p);
              created.add(np);
            }
          }
          void refresh();
        }),
        on.openNote((p) => {
          setFolder(ALL);
          setQuery("");
          setSelected(p);
        }),
        on.willQuit(() => void flushAll()),
      ]),
    [refresh],
  );

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return tree.notes.filter((n: NoteMeta) => {
      if (folder !== ALL && n.folder !== folder) return false;
      if (!q) return true;
      return (n.title + "\n" + n.preview + "\n" + n.path).toLowerCase().includes(q);
    });
  }, [tree.notes, folder, query]);

  const newNote = useCallback(async () => {
    try {
      const path = await api.createNote(folder !== ALL ? folder : "");
      createdRef.current.add(path);
      setQuery("");
      await refresh();
      setJustCreated(path);
      setSelected(path);
    } catch (e) {
      fail(e);
    }
  }, [folder, refresh, fail]);

  // ⌘⇧N: 새 메모를 바로 스티키로 (FR-38)
  const newStickyNote = useCallback(async () => {
    try {
      const path = await api.createNote(folder !== ALL ? folder : "");
      await patchMeta(path, { sticky: { ...DEFAULT_STICKY, open: true } });
      await api.openSticky(path, DEFAULT_STICKY, true);
      refresh();
    } catch (e) {
      fail(e);
    }
  }, [folder, refresh, fail]);

  const trashNote = useCallback(
    async (path: string) => {
      const idx = visible.findIndex((n) => n.path === path);
      try {
        discardUnder(path); // 지운 파일을 남은 저장이 되살리지 않게 (BUG-40)
        await api.closeStickyWindow(path);
        await api.trashNote(path);
      } catch (e) {
        fail(e);
      }
      if (selectedRef.current === path) {
        const next = visible[idx + 1] ?? visible[idx - 1];
        setSelected(next && next.path !== path ? next.path : null);
      }
      refresh();
    },
    [visible, refresh, fail],
  );

  const pin = useCallback(
    async (path: string, pinned: boolean) => {
      try {
        await patchMeta(path, { pinned });
        refresh();
      } catch (e) {
        fail(e);
      }
    },
    [refresh, fail],
  );

  // ── 폴더 ──
  const saveLayout = useCallback(
    async (l: Layout) => {
      setTree((t) => ({ ...t, layout: l }));
      try {
        await api.setLayout(l);
      } catch (e) {
        fail(e);
      }
    },
    [fail],
  );

  const sidebarActions: SidebarActions = {
    selectFolder: (f) => {
      setFolder(f);
      setSelected(null);
    },
    setLayout: saveLayout,
    createFolder: async (parent, name) => {
      try {
        const p = await api.createFolder(parent, name);
        await refresh();
        setFolder(p);
      } catch (e) {
        fail(e);
      }
    },
    renameFolder: async (path, name) => {
      try {
        await flushAll();
        await api.renameFolder(path, name);
      } catch (e) {
        fail(e);
      }
    },
    trashFolder: async (path) => {
      const count = tree.notes.filter((n) => n.folder === path || n.folder.startsWith(path + "/")).length;
      if (count > 0) {
        const ok = await ask(`"${path.split("/").pop()}" 폴더와 안의 메모 ${count}개를 휴지통으로 옮길까요?`, {
          title: "폴더 삭제",
          kind: "warning",
          okLabel: "휴지통으로 이동",
          cancelLabel: "취소",
        });
        if (!ok) return;
      }
      try {
        await flushAll();
        for (const n of tree.notes) {
          if (n.sticky?.open && (n.folder === path || n.folder.startsWith(path + "/"))) {
            await api.closeStickyWindow(n.path);
          }
        }
        discardUnder(path);
        await api.trashFolder(path);
        if (folder === path || folder.startsWith(path + "/")) setFolder(ALL);
        if (selected && selected.startsWith(path + "/")) setSelected(null);
        refresh();
      } catch (e) {
        fail(e);
      }
    },
    moveFolder: async (path, destParent, beforeKey, into) => {
      try {
        const parent = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
        let name = path.split("/").pop()!;
        if (parent !== destParent) {
          await flushAll();
          const np = await api.moveEntry(path, destParent);
          name = np.split("/").pop()!;
        }
        const t = await api.listTree();
        await saveLayout(reorder(t.folders, t.layout, destParent, name, beforeKey, into));
        refresh();
      } catch (e) {
        fail(e);
      }
    },
    moveSeparator: async (id, fromParent, destParent, beforeKey) => {
      let l = tree.layout;
      if (fromParent !== destParent) {
        // 옛 부모의 현재 순서를 고정한 뒤 빼낸다
        const seq = customSequence(fromParent, childrenOf(tree.folders, fromParent), l).map(itemKey);
        l = removeKey({ ...l, order: { ...l.order, [fromParent]: seq } }, fromParent, id);
      }
      await saveLayout(reorder(tree.folders, l, destParent, id, beforeKey));
    },
    moveNote: async (target, dest) => {
      if (target.slice(0, Math.max(0, target.lastIndexOf("/"))) === dest) return;
      try {
        const path = await flushAndResolve(target); // BUG-28
        await api.moveEntry(path, dest);
      } catch (e) {
        fail(e);
      }
    },
    openSticky: popOut,
    putBack,
    openNote: (p) => {
      setFolder(ALL);
      setQuery("");
      setSelected(p);
    },
    changeVault: onChangeVault,
    openSettings: () => setSettingsOpen(true),
    toggleSidebar: () => updatePrefs({ sidebarCollapsed: !prefs.sidebarCollapsed }),
  };

  // ── 메뉴 막대 (FR-41) ──
  const menuRef = useRef<(id: string) => void>(() => {});
  menuRef.current = (id: string) => {
    switch (id) {
      case "new-note":
        return void newNote();
      case "new-sticky-note":
        return void newStickyNote();
      case "new-folder":
        return void sidebarActions.createFolder(folder !== ALL ? folder : "", "새 폴더");
      case "pop-out":
        return selected ? void toggleSticky(selected) : undefined;
      case "toggle-pin": {
        const n = tree.notes.find((x) => x.path === selected);
        return n ? void pin(n.path, !n.pinned) : undefined;
      }
      case "change-vault":
        return onChangeVault();
      case "toggle-sidebar":
        return sidebarActions.toggleSidebar();
      case "find":
        if (prefs.sidebarCollapsed) updatePrefs({ sidebarCollapsed: false });
        return searchRef.current?.focus();
      case "settings":
      case "about":
        return setSettingsOpen(true);
      case "theme-system":
      case "theme-light":
      case "theme-dark":
        return updatePrefs({ theme: id.slice("theme-".length) as Prefs["theme"] });
    }
  };
  useEffect(() => unlistenAll([on.menu((id) => menuRef.current(id))]), []);

  const selectedMeta = tree.notes.find((n) => n.path === selected) ?? null;

  return (
    <div className={`workspace ${prefs.sidebarCollapsed ? "collapsed" : ""}`}>
      <Sidebar
        vault={vault}
        folders={tree.folders}
        notes={tree.notes}
        layout={tree.layout}
        folder={folder}
        actions={sidebarActions}
      />
      <NoteList
        notes={visible}
        selected={selected}
        onSelect={setSelected}
        query={query}
        onQuery={setQuery}
        searchRef={searchRef}
        onNew={newNote}
        showFolder={folder === ALL}
        sort={prefs.noteSort}
        onSort={(s) => updatePrefs({ noteSort: s })}
        sidebarCollapsed={prefs.sidebarCollapsed}
        onToggleSidebar={sidebarActions.toggleSidebar}
        onPin={pin}
        onPopOut={popOut}
        onPutBack={putBack}
        onTrash={trashNote}
      />
      <EditorPane
        vault={vault}
        path={selected}
        meta={selectedMeta}
        isNew={(p) => createdRef.current.has(p)}
        autofocusPath={justCreated}
        onDelete={trashNote}
        onToggleSticky={toggleSticky}
        onMissing={() => setSelected(null)}
        onNotice={toast}
      />
      {settingsOpen && <Settings prefs={prefs} onChange={updatePrefs} onClose={() => setSettingsOpen(false)} />}
      {notice && <div className="toast">{notice}</div>}
    </div>
  );
}
