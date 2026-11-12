#!/usr/bin/env python3
"""문서 일관성 점검 (운영 모델 3.4).

    python3 scripts/check-docs.py

점검하는 것
  1. 깨진 링크: 문서의 상대 링크가 가리키는 파일이 있는지
  2. 없는 ID: D-xx, FR-xx, NFR-xx, F-xx, SCR-xx, B-xx 참조가 정의된 곳이 있는지
  3. 요구사항 검증: 기능 카드의 요구사항마다 "검증" 칸의 ID(A1, M1 …)가 그 카드 5장에 있는지,
     Must인데 검증이 비어 있지 않은지
  4. 테스트 실재: 5장이 가리키는 테스트 파일·Rust 테스트 이름이 코드에 있는지
  5. Brief 4.1 목록: 카드별 요구사항 목록과 Must·Should 개수, 합계가 카드와 같은지
  6. 문서 머리말: Brief와 기능 카드에 상태(초안 / 검토 중 / 확정)가 있는지

오류가 있으면 종료 코드 1. 경고(확인 필요)는 종료 코드에 영향을 주지 않는다.
docs/archive/ 는 고치지 않는 문서라 점검하지 않는다. 회의록·릴리스 노트는 그 시점의 기록이라 링크만 본다.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
FEATURES = DOCS / "product" / "features"
BRIEF = DOCS / "product" / "brief.md"
DECISIONS = DOCS / "decisions.md"
BACKLOG = DOCS / "product" / "backlog.md"
PROTOTYPE = DOCS / "prototype" / "index.html"

errors: list[str] = []
warnings: list[str] = []


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def err(where: str, msg: str) -> None:
    errors.append(f"{where}: {msg}")


def warn(where: str, msg: str) -> None:
    warnings.append(f"{where}: {msg}")


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def strip_code(text: str) -> str:
    """코드 블록(``` … ```)과 `인라인 코드`를 지운다. 예시 안의 링크·ID는 점검 대상이 아니다."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "", text)


def live_docs() -> list[Path]:
    """살아 있는 문서: 보관 문서를 뺀 docs/ 의 md + 저장소 루트의 md."""
    files = [p for p in DOCS.rglob("*.md") if "archive" not in p.relative_to(DOCS).parts]
    files += [ROOT / "README.md", ROOT / "CLAUDE.md"]
    return sorted(p for p in files if p.exists())


def is_snapshot(p: Path) -> bool:
    """그 시점의 기록이라 ID 정합성을 따지지 않는 문서."""
    parts = p.relative_to(ROOT).parts
    return "meetings" in parts or ("releases" in parts and p.name != "README.md")


# ───────────────────────── 1. 링크 ─────────────────────────

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def check_links() -> None:
    for doc in live_docs():
        for target in LINK.findall(strip_code(read(doc))):
            if re.match(r"^(https?:|mailto:|#)", target):
                continue
            path = target.split("#", 1)[0]
            if not path:
                continue
            dest = (doc.parent / path).resolve()
            if not dest.exists():
                err(rel(doc), f"깨진 링크 → {target}")


# ───────────────────────── 2. ID ─────────────────────────

def table_ids(text: str, prefix: str) -> set[str]:
    """표의 첫 칸에 정의된 ID. 예: | FR-30 | …"""
    return set(re.findall(rf"^\|\s*({prefix}-\d+)\b", text, flags=re.M))


def collect_definitions() -> dict[str, set[str]]:
    defs: dict[str, set[str]] = {k: set() for k in ("D", "FR", "NFR", "F", "SCR", "B")}
    defs["D"] = table_ids(read(DECISIONS), "D")
    brief = read(BRIEF)
    defs["NFR"] = table_ids(brief, "NFR")
    for card in sorted(FEATURES.glob("F-*.md")):
        text = read(card)
        defs["F"].add(re.match(r"(F-\d+)", card.name).group(1))
        defs["FR"] |= table_ids(text, "FR")
        defs["NFR"] |= table_ids(text, "NFR")
    defs["B"] = table_ids(read(BACKLOG), "B")
    proto = read(PROTOTYPE)
    defs["SCR"] = {f"SCR-{n}" for n in re.findall(r'id="scr-(\d+)"', proto)}
    # 한 구역에 두 화면을 나란히 둔 경우(예: SCR-03 옆 SCR-04)는 캡션이 정의다
    defs["SCR"] |= set(re.findall(r'class="cap">(SCR-\d+)', proto))
    return defs


# 폐지되어 정의가 없는 것이 맞는 ID (Brief 4.2 아래 "폐지" 줄)
RETIRED = {"NFR-06", "FR-12", "FR-16", "FR-17", "FR-18", "FR-19", "FR-20", "FR-21"}
# FR-26~28, FR-16~21 같은 범위 표기의 뒤쪽 숫자, B-1(행동 가설)처럼 다른 뜻으로 쓰는 것은 건너뛴다
REF = re.compile(r"(?<![\w-])(NFR|FR|SCR|D|B|F)-(\d+)(?![\w.]*\.md)\b")


def check_ids(defs: dict[str, set[str]]) -> None:
    sources = [p for p in live_docs() if not is_snapshot(p)] + [PROTOTYPE]
    for doc in sources:
        text = strip_code(read(doc))
        seen: set[str] = set()
        for kind, num in REF.findall(text):
            ref = f"{kind}-{num}"
            if ref in seen or ref in RETIRED:
                continue
            seen.add(ref)
            if kind == "B" and len(num) < 2:
                continue  # Brief의 B-1~B-4는 "예상되는 사용자 행동"이다
            if kind in ("F", "SCR", "D", "B") and len(num) < 2:
                continue
            if ref not in defs[kind]:
                err(rel(doc), f"없는 ID {ref}")
    # 기능 카드가 가리키는 프로토타입 화면
    if not defs["SCR"]:
        err(rel(PROTOTYPE), "화면 ID(id=\"scr-xx\")를 하나도 찾지 못했다")


# ───────────────────────── 3·4. 요구사항과 검증 ─────────────────────────

def split_row(line: str) -> list[str]:
    cells = re.split(r"(?<!\\)\|", line.strip())
    return [c.strip() for c in cells[1:-1]]


def section(text: str, number: int) -> str:
    m = re.search(rf"^## {number}\. .*?(?=^## \d+\. |\Z)", text, flags=re.M | re.S)
    return m.group(0) if m else ""


def tests_index() -> tuple[str, dict[str, str]]:
    rust = "\n".join(read(p) for p in (ROOT / "src-tauri" / "src").rglob("*.rs"))
    swift_dir = ROOT / "macos" / "Tests"
    swift = "\n".join(read(p) for p in swift_dir.rglob("*.swift")) if swift_dir.exists() else ""
    return rust + "\n" + swift, {}


def check_cards() -> dict[str, dict[str, list[str]]]:
    """카드마다 {'Must': [...], 'Should': [...]} 를 돌려준다(FR만)."""
    rust_src, _ = tests_index()
    result: dict[str, dict[str, list[str]]] = {}
    for card in sorted(FEATURES.glob("F-*.md")):
        text = read(card)
        where = rel(card)
        fid = re.match(r"(F-\d+)", card.name).group(1)
        result[fid] = {"Must": [], "Should": [], "Could": []}

        if not re.search(r"^\|\s*상태\s*\|\s*\*\*(초안|검토 중|확정)\*\*", text, flags=re.M):
            err(where, "머리말에 상태(초안 / 검토 중 / 확정)가 없다")

        verify = section(text, 5)
        verify_ids = set(re.findall(r"^\|\s*([AMP]\d+)\s*\|", verify, flags=re.M))
        if not verify:
            err(where, "5장(검증)이 없다")

        for line in section(text, 2).splitlines():
            if not re.match(r"^\|\s*(FR|NFR)-\d+", line):
                continue
            cells = split_row(line)
            if len(cells) < 5:
                err(where, f"요구사항 줄의 칸 수가 모자란다: {cells[0]}")
                continue
            rid, moscow, checks = cells[0], cells[2], cells[4]
            if rid.startswith("FR-"):
                if moscow not in result[fid]:
                    err(where, f"{rid}: MoSCoW 값이 이상하다({moscow})")
                else:
                    result[fid][moscow].append(rid)
            refs = re.findall(r"\b([AMP]\d+)\b", checks)
            if not refs and moscow == "Must":
                err(where, f"{rid}: Must인데 검증이 연결되어 있지 않다")
            for r in refs:
                if r not in verify_ids:
                    err(where, f"{rid}: 검증 {r}이(가) 5장에 없다")

        # 5장이 가리키는 테스트가 실제로 있는지
        for line in verify.splitlines():
            if not re.match(r"^\|\s*[AMP]\d+\s*\|", line):
                continue
            cells = split_row(line)
            vid, place = cells[0], cells[-1]
            if "신규 작성 필요" in place:
                warn(where, f"{vid}: 테스트가 아직 없다(신규 작성 필요)")
                continue
            for token in re.findall(r"`([^`]+)`", place):
                if "/" in token:
                    if not (ROOT / token).exists():
                        err(where, f"{vid}: 파일이 없다 → {token}")
                elif re.fullmatch(r"[a-z]+", token) and (ROOT / "src-tauri" / "src" / f"{token}.rs").exists():
                    continue  # 모듈 이름(예: `layout` 테스트)
                elif re.fullmatch(r"[a-z0-9_]+", token):
                    if not re.search(rf"\bfn {re.escape(token)}\b|\bfunc {re.escape(token)}\b", rust_src):
                        err(where, f"{vid}: 테스트 이름이 코드에 없다 → {token}")
    return result


# ───────────────────────── 5. Brief 4.1 ─────────────────────────

def check_brief_list(cards: dict[str, dict[str, list[str]]]) -> None:
    text = read(BRIEF)
    where = rel(BRIEF)
    if not re.search(r"^\|\s*상태\s*\|\s*\*\*(초안|검토 중|확정)\*\*", text, flags=re.M):
        err(where, "머리말에 상태가 없다")
    m = re.search(r"^### 4\.1 .*?(?=^### )", text, flags=re.M | re.S)
    if not m:
        err(where, "4.1 기능 카드 목록을 찾지 못했다")
        return
    total_must = total_should = 0
    listed: set[str] = set()
    for line in m.group(0).splitlines():
        cells = split_row(line) if line.startswith("|") else []
        if len(cells) < 4:
            continue
        fm = re.search(r"\b(F-\d+)\b", cells[0])
        if fm:
            fid = fm.group(1)
            listed.add(fid)
            if fid not in cards:
                err(where, f"4.1: 기능 카드 파일이 없다 → {fid}")
                continue
            has_fr = cells[1].startswith("FR-")  # "FR-01, 02, 03" 꼴. NFR만 있는 카드는 건너뛴다
            in_brief = {f"FR-{n}" for n in re.findall(r"\d+", cells[1])} if has_fr else set()
            in_card = set(cards[fid]["Must"]) | set(cards[fid]["Should"]) | set(cards[fid]["Could"])
            if has_fr and in_brief != in_card:
                err(where, f"4.1 {fid}: 요구사항 목록이 카드와 다르다 "
                           f"(Brief에만 {sorted(in_brief - in_card)}, 카드에만 {sorted(in_card - in_brief)})")
            must = int(cells[2]) if cells[2].isdigit() else 0
            should = int(cells[3]) if cells[3].isdigit() else 0
            if must != len(cards[fid]["Must"]) or should != len(cards[fid]["Should"]):
                err(where, f"4.1 {fid}: 개수가 다르다 (Brief Must {must}·Should {should}, "
                           f"카드 Must {len(cards[fid]['Must'])}·Should {len(cards[fid]['Should'])})")
            total_must += len(cards[fid]["Must"])
            total_should += len(cards[fid]["Should"])
        elif "합계" in cells[0]:
            nums = [int(n) for n in re.findall(r"\d+", cells[2] + " " + cells[3])]
            if nums != [total_must, total_should]:
                err(where, f"4.1 합계가 다르다 (Brief {nums}, 카드 합 [{total_must}, {total_should}])")
    for fid in sorted(set(cards) - listed):
        err(where, f"4.1: 목록에 없는 기능 카드 → {fid}")


# ───────────────────────── 실행 ─────────────────────────

def main() -> int:
    check_links()
    defs = collect_definitions()
    check_ids(defs)
    cards = check_cards()
    check_brief_list(cards)

    counts = ", ".join(f"{k} {len(v)}" for k, v in defs.items())
    print(f"점검한 문서 {len(live_docs())}개 · 정의된 ID: {counts}")
    for w in warnings:
        print(f"  경고  {w}")
    for e in errors:
        print(f"  오류  {e}")
    print(f"오류 {len(errors)}건, 경고 {len(warnings)}건")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
