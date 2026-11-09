/**
 * 열려 있는 메모 하나의 저장 상태 (메인 편집기와 스티키 창이 함께 쓴다).
 * - 본문만 고친다. frontmatter(고정·스티키 정보)는 저장할 때마다 디스크 최신본을 그대로 쓴다.
 * - 메모마다 따로 저장하므로, 메모를 바꿔도 이전 메모 저장이 새 선택을 건드리지 않는다 (BUG-02).
 * - 저장에 실패하면 알리고 3초마다 다시 시도한다. 화면에서 떠나도 저장될 때까지 계속한다 (NFR-13, BUG-24).
 * - 저장 직전 디스크 본문이 내가 알던 것과 다르면(다른 창이 고침) 병합해서 쓴다 (BUG-26).
 */
import { api, movedPath, updateNote, type EntryMoved } from "./api";
import { mergeBodies } from "./merge";

const SAVE_DELAY = 500;
const RETRY_DELAY = 3000;
const registry = new Set<NoteSession>();

export interface SessionState {
  failing: boolean;
  error?: string;
}

/** 화면에서 떠난 뒤에도 저장에 실패하고 있는 세션 수가 바뀔 때 (App이 알림을 띄운다) */
let backgroundListener: ((failing: number) => void) | undefined;
export function onBackgroundFailures(f: ((failing: number) => void) | undefined) {
  backgroundListener = f;
}
const backgroundFailing = () => [...registry].filter((s) => s.released && s.dirty).length;

export class NoteSession {
  path: string;
  /** 디스크와 같다고 알고 있는 본문 */
  saved: string;
  pending: string | null = null;
  readonly createdNew: boolean;
  /** 화면에서는 떠났지만 저장이 끝나지 않아 살아 있는 세션 */
  released = false;
  private timer: number | undefined;
  private chain: Promise<void> = Promise.resolve();
  private state: SessionState = { failing: false };
  /** 본문은 저장됐지만 파일 이름을 아직 제목에 맞추지 못함 (BUG-25) */
  private nameStale = false;
  onState?: (s: SessionState) => void;
  /** 다른 창의 편집과 병합한 결과를 화면에 다시 보여 줘야 할 때 */
  onMerged?: (body: string) => void;
  /** 저장 후 파일 이름을 제목에 맞출지 */
  syncName = true;

  constructor(path: string, saved: string, createdNew = false) {
    this.path = path;
    this.saved = saved;
    this.createdNew = createdNew;
    registry.add(this);
  }

  get dirty() {
    return this.pending !== null;
  }

  get failing() {
    return this.state.failing;
  }

  edit(body: string) {
    if (body === this.saved && this.pending === null) return;
    this.pending = body;
    this.schedule(SAVE_DELAY);
  }

  private schedule(ms: number) {
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void this.flush(), ms);
  }

  /** 남은 입력을 바로 저장. 여러 번 불려도 순서대로 한 번씩 */
  flush(): Promise<void> {
    window.clearTimeout(this.timer);
    this.chain = this.chain.then(() => this.doFlush());
    return this.chain;
  }

  private async doFlush() {
    const body = this.pending;
    if (body === null && !this.nameStale) return;
    try {
      if (body !== null) {
        let written = body;
        try {
          await updateNote(this.path, ({ front, body: disk }) => {
            written = disk === this.saved ? body : mergeBodies(this.saved, body, disk);
            return { front, body: written };
          });
        } catch (e) {
          // 파일이 사라졌으면(Finder에서 옮김·지움, 동기화) 그 자리에 다시 만들어 입력을 살린다 (BUG-40)
          if (!isMissing(e)) throw e;
          await api.writeNote(this.path, body);
          written = body;
        }
        this.saved = written;
        if (this.pending === body) {
          this.pending = null;
          if (written !== body) this.onMerged?.(written);
        } else if (written !== body && this.pending !== null) {
          // 병합 저장 도중에 또 입력했다: 그 입력에도 상대 창의 줄을 합쳐 화면과 다음 저장에 반영한다 (BUG-39)
          this.pending = mergeBodies(body, this.pending, written);
          this.onMerged?.(this.pending);
          this.schedule(SAVE_DELAY);
        }
        this.nameStale = this.syncName;
      }
      if (this.nameStale) {
        const np = await api.syncNoteName(this.path);
        this.nameStale = false;
        if (np !== this.path) this.path = np;
      }
      this.setState({ failing: false });
      if (this.released && !this.dirty) this.close();
    } catch (e) {
      this.setState({ failing: true, error: String(e) });
      this.schedule(RETRY_DELAY);
    }
  }

  private setState(s: SessionState) {
    if (s.failing === this.state.failing && s.error === this.state.error) return;
    this.state = s;
    this.onState?.(s);
    if (this.released) backgroundListener?.(backgroundFailing());
  }

  /** 더 이상 저장하지 않는다 (삭제할 때) */
  cancel() {
    window.clearTimeout(this.timer);
    this.pending = null;
    this.nameStale = false;
  }

  /**
   * 화면에서 떠난다. 저장이 끝났으면 바로 닫고 true,
   * 아직 저장하지 못한 입력이 있으면 닫지 않고 뒤에서 계속 다시 시도한 뒤 false (BUG-24).
   */
  release(): boolean {
    this.onState = undefined;
    this.onMerged = undefined;
    if (!this.dirty && !this.nameStale) {
      this.close();
      return true;
    }
    this.released = true;
    backgroundListener?.(backgroundFailing());
    return false;
  }

  close() {
    window.clearTimeout(this.timer);
    const wasBackground = this.released;
    registry.delete(this);
    if (wasBackground) backgroundListener?.(backgroundFailing());
  }
}

const isMissing = (e: unknown) => /os error 2\b|No such file/i.test(String(e));

/** 그 경로(또는 그 폴더 아래, ""이면 전부) 메모의 세션을 저장하지 않고 닫는다 — 휴지통으로 보낼 때.
 *  남겨 두면 다음 저장이 지운 파일을 다시 만든다 (BUG-40) */
export function discardUnder(path: string) {
  for (const s of [...registry]) {
    if (path === "" || s.path === path || s.path.startsWith(path + "/")) {
      s.cancel();
      s.close();
    }
  }
}

/** 이 창에 열린 모든 메모를 지금 저장 (메모 이동, 스티키로 꺼내기, 종료 직전) */
export function flushAll(): Promise<void> {
  return Promise.all([...registry].map((s) => s.flush())).then(() => {});
}

/** 종료 직전: 이 창의 모든 메모를 저장하고 Rust에 알린다 (BUG-35).
 *  하나가 실패해도 나머지는 끝까지 저장하고, 저장하지 못한 수를 함께 보낸다 */
export async function flushForQuit(): Promise<void> {
  await Promise.allSettled([...registry].map((s) => s.flush()));
  await api.quitReady(unsavedCount());
}

/** 아직 저장하지 못한 입력이 있는 세션 수 */
export function unsavedCount(): number {
  return [...registry].filter((s) => s.dirty).length;
}

/**
 * path 메모를 저장한 뒤 그 메모의 지금 경로를 돌려준다.
 * 저장하면서 제목에 맞춰 파일 이름이 바뀔 수 있으므로, 저장 뒤에는 이 경로를 써야 한다 (BUG-28).
 */
export async function flushAndResolve(path: string): Promise<string> {
  const s = [...registry].find((x) => x.path === path);
  await flushAll();
  return s?.path ?? path;
}

/** 이름 변경·이동 이벤트를 열린 세션 경로에 반영 */
export function applyMove(e: EntryMoved) {
  for (const s of registry) {
    const np = movedPath(s.path, e);
    if (np) s.path = np;
  }
}
