// @vitest-environment jsdom
/**
 * QA v0.3 — 저장 세션(noteSession.ts)의 병합(BUG-26 수정)과 release(BUG-24 수정) 수명 검증.
 * 실제 NoteSession + 가짜 백엔드. it.fails 는 v0.3 QA 보고서의 결함이다. 고치면 it 으로 바꾼다.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fake } from "./fakeBackend";
import { mergeBodies } from "../lib/merge";

vi.setConfig({ testTimeout: 20_000 });
vi.mock("@tauri-apps/api/core", async () => (await import("./fakeBackend")).tauriCore);
vi.mock("@tauri-apps/api/event", async () => (await import("./fakeBackend")).tauriEvent);

const { NoteSession, unsavedCount } = await import("../lib/noteSession");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const live: InstanceType<typeof NoteSession>[] = [];
function session(path: string, saved: string) {
  const s = new NoteSession(path, saved);
  s.syncName = false;
  live.push(s);
  return s;
}

beforeEach(() => fake.reset());
afterEach(() => {
  for (const s of live.splice(0)) s.close();
});

const body = (p: string) => fake.files.get(p)?.content;

describe("mergeBodies (ADR-12): 어느 쪽 편집도 버리지 않는다", () => {
  // 무작위 3,000건은 scratchpad 교차 검증에서 돌렸다(보고서 4.5). 여기는 대표 사례만 고정한다.
  it.each([
    ["다른 줄을 고침", "a\nb\nc", "A\nb\nc", "a\nb\nC", "A\nb\nC"],
    ["양쪽이 끝에 추가", "a", "a\n내 줄", "a\n남 줄", "a\n내 줄\n\n남 줄"],
    ["같은 줄 충돌 → 둘 다 남김", "a\nb", "a\n내 b", "a\n남 b", "a\n내 b\n\n남 b"],
    ["한쪽만 고침", "a\nb", "a\nb", "a\nb\n남", "a\nb\n남"],
    ["내가 다 지우고 상대는 추가", "a", "", "a\n추가", "\n\na\n추가"],
  ])("%s", (_name, base, mine, theirs, want) => {
    expect(mergeBodies(base, mine, theirs)).toBe(want);
  });
});

describe("NoteSession 병합 저장 (BUG-26 수정 재검증)", () => {
  it("다른 창이 먼저 저장한 줄과 내 편집을 병합해 쓰고, onMerged로 화면에 알린다", async () => {
    fake.put("메모/a.md", "제목\n\n본문");
    const s = session("메모/a.md", "제목\n\n본문");
    const merged: string[] = [];
    s.onMerged = (m) => merged.push(m);
    fake.put("메모/a.md", "제목\n\n본문\n\n스티키 줄"); // 다른 창 저장
    s.edit("제목 고침\n\n본문");
    await sleep(700);
    expect(body("메모/a.md")).toBe("제목 고침\n\n본문\n\n스티키 줄");
    expect(merged).toEqual(["제목 고침\n\n본문\n\n스티키 줄"]);
  });

  it("frontmatter는 디스크 최신본을 그대로 둔다", async () => {
    fake.put("메모/a.md", "본문");
    const s = session("메모/a.md", "본문");
    fake.put("메모/a.md", "---\npinned: true\n---\n본문\n남 줄");
    s.edit("내 줄\n본문");
    await sleep(700);
    expect(body("메모/a.md")).toBe("---\npinned: true\n---\n내 줄\n본문\n남 줄");
  });

  // BUG-39: 저장(IPC) 도중에 새 입력이 오면 onMerged가 불리지 않는다. 화면은 상대 줄을 모른 채로 남고,
  // saved는 병합본이 되므로 다음 저장 때 disk === saved 로 보고 화면 내용으로 덮어써 상대 줄이 사라진다.
  it("BUG-39: 병합 저장 중에 계속 입력해도 다른 창이 쓴 줄이 끝까지 남아야 한다", async () => {
    fake.put("메모/a.md", "제목\n\n본문");
    const s = session("메모/a.md", "제목\n\n본문");
    fake.put("메모/a.md", "제목\n\n본문\n\n스티키 줄"); // 다른 창 저장
    fake.ipcDelay = 40;
    s.edit("제목\n\n본문 내1");
    await sleep(520); // 저장 시작 (read_note 대기 중)
    s.edit("제목\n\n본문 내1 내2"); // 화면에는 스티키 줄이 없다
    await sleep(1500);
    expect(body("메모/a.md")).toContain("내2");
    expect(body("메모/a.md")).toContain("스티키 줄");
  });
});

describe("release(): 화면에서 떠난 세션의 수명 (BUG-24 수정 재검증)", () => {
  it("저장할 것이 없으면 바로 닫힌다", () => {
    const s = new NoteSession("메모/a.md", "a");
    expect(s.release()).toBe(true);
    expect(unsavedCount()).toBe(0);
  });

  it("실패 중에 떠나면 남아서 다시 시도하고, 성공하면 저절로 닫힌다", async () => {
    fake.put("메모/a.md", "a");
    const s = new NoteSession("메모/a.md", "a");
    s.syncName = false;
    fake.failWrite = () => true;
    s.edit("a 입력");
    await s.flush();
    expect(s.release()).toBe(false);
    expect(unsavedCount()).toBe(1);
    fake.failWrite = () => false;
    await sleep(3300);
    expect(body("메모/a.md")).toBe("a 입력");
    expect(unsavedCount()).toBe(0);
  });

  // BUG-40: 실패 원인이 사라지지 않으면(파일이 지워지거나 Finder에서 옮겨짐) 세션이 끝없이 남는다.
  // 입력은 어디에도 저장되지 않고, unsavedCount() > 0 이 계속되어 저장 폴더 변경도 영영 막힌다.
  it("BUG-40: 파일이 사라져 저장할 수 없는 세션은 끝없이 남지 않고 입력을 어딘가에 살려야 한다", async () => {
    fake.put("메모/a.md", "a");
    const s = new NoteSession("메모/a.md", "a");
    s.syncName = false;
    fake.files.delete("메모/a.md"); // Finder에서 옮기거나 지움
    s.edit("a 잃으면 안 되는 입력");
    await s.flush();
    s.release();
    await sleep(6500); // 재시도 두 번
    const saved = [...fake.files.values()].some((f) => f.content.includes("잃으면 안 되는 입력"));
    const n = unsavedCount();
    if (n) s.close(); // 다음 테스트에 남지 않게
    expect(saved || n === 0).toBe(true);
    expect(n).toBe(0);
  });
});
