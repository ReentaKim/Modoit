/**
 * 토글(FR-48)의 `<details>` 블록 찾기 — 편집기 토크나이저와 안전성 검사가 함께 쓴다.
 * 코드(펜스 코드 블록·인라인 코드) 안의 태그는 세지 않는다 (BUG-41).
 */

/** 코드 구간을 같은 길이의 공백으로 가린다. 위치(index)는 원문과 같다 */
export function maskCode(src: string): string {
  const blank = (s: string) => s.replace(/[^\n]/g, " ");
  // 펜스 코드 블록: 여는 펜스부터 같은 문자·같거나 긴 닫는 펜스까지 (닫는 펜스가 없으면 문서 끝까지)
  let out = src.replace(
    /^( {0,3})(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^ {0,3}\2[`~]*[ \t]*$|(?![\s\S]))/gm,
    blank,
  );
  // 인라인 코드: 백틱 n개로 열고 정확히 n개로 닫힌 구간 (CommonMark 코드 스팬).
  // 역슬래시로 이스케이프한 백틱은 열지 않고, 빈 줄(문단 경계)을 넘어 짝짓지 않는다 (BUG-47)
  let i = 0;
  while (i < out.length) {
    if (out[i] !== "`") {
      i += out[i] === "\\" ? 2 : 1;
      continue;
    }
    let n = 0;
    while (out[i + n] === "`") n += 1;
    let j = i + n;
    let close = -1;
    while (j < out.length) {
      if (out[j] === "\n" && /^\n[ \t]*(?:\n|$)/.test(out.slice(j, j + 80))) break;
      if (out[j] !== "`") {
        j += 1;
        continue;
      }
      let k = 0;
      while (out[j + k] === "`") k += 1;
      if (k === n) {
        close = j + k;
        break;
      }
      j += k;
    }
    if (close < 0) {
      i += n;
      continue;
    }
    out = out.slice(0, i) + blank(out.slice(i, close)) + out.slice(close);
    i = close;
  }
  return out;
}

const OPEN_LINE = /^<details(?:\s+open)?\s*>[ \t]*(?:\r?\n|$)/i;
const SUMMARY_LINE = /^[ \t]*<summary>([^\n]*?)<\/summary>[ \t]*(?:\r?\n|$)/i;
const TAG = /<details(?:\s+open)?\s*>|<\/details\s*>/gi;

/** masked 기준으로, 맨 앞 `<details>`와 짝이 맞는 `</details>` 바로 뒤 위치. 없으면 -1 */
function detailsEnd(masked: string): number {
  TAG.lastIndex = 0;
  let depth = 0;
  let m: RegExpExecArray | null;
  while ((m = TAG.exec(masked))) {
    if (m[0].startsWith("</")) {
      depth -= 1;
      if (depth === 0) return m.index + m[0].length;
      if (depth < 0) return -1;
    } else depth += 1;
  }
  return -1;
}

export interface DetailsBlock {
  summary: string;
  /** 안쪽 Markdown (앞뒤 빈 줄만 뗀다 — 들여쓴 코드의 들여쓰기는 보존) */
  inner: string;
  /** 원문에서 이 블록이 차지한 길이(뒤 줄바꿈 포함) */
  length: number;
}

/**
 * src 맨 앞의 Modoit 형식 토글 하나. 형식이 아니면 null.
 * 형식: `<details>` 한 줄, `<summary>…</summary>` 한 줄, 내용, `</details>`(줄 맨 앞).
 */
export function splitDetails(src: string, masked = maskCode(src)): DetailsBlock | null {
  const open = masked.match(OPEN_LINE);
  if (!open) return null;
  const head = masked.slice(open[0].length).match(SUMMARY_LINE);
  if (!head) return null;
  const end = detailsEnd(masked);
  if (end < 0) return null;
  const closeAt = end - masked.slice(0, end).match(/<\/details\s*>$/i)![0].length;
  // 닫는 태그는 줄 맨 앞에 혼자 있어야 한다
  if (closeAt > 0 && masked[closeAt - 1] !== "\n") return null;
  const tail = masked.slice(end).match(/^[ \t]*(?:\r?\n|$)/);
  if (!tail) return null;
  const bodyStart = open[0].length + head[0].length;
  const summary = src.slice(open[0].length, bodyStart).match(SUMMARY_LINE)![1]!.trim();
  const inner = dedent(
    src
      .slice(bodyStart, closeAt)
      .replace(/^(?:[ \t]*\r?\n)+/, "")
      .replace(/(?:\r?\n[ \t]*)+$/, ""),
  );
  return { summary, inner, length: end + tail[0].length };
}

/** 모든 줄이 함께 1~3칸 들여 쓰였으면 그만큼 뗀다(태그 안을 들여 쓴 다른 앱 문서).
 *  4칸 이상은 들여쓴 코드일 수 있으므로 두다 */
function dedent(s: string): string {
  const widths = s
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => l.match(/^ */)![0].length);
  const n = widths.length ? Math.min(...widths) : 0;
  if (n === 0 || n > 3) return s;
  return s
    .split("\n")
    .map((l) => l.slice(Math.min(n, l.match(/^ */)![0].length)))
    .join("\n");
}

/**
 * 안전성 검사용: 짝이 맞는 Modoit 형식 토글의 태그 줄만 걷어 내고 안쪽 내용을 남긴다.
 * 짝이 없거나 형식이 다른 태그(닫는 태그 없음, summary 없음, 짝 없는 `</details>`)는 그대로 둔다 → HTML로 잡힌다 (BUG-46)
 */
export function stripToggleTags(md: string): string {
  const masked = maskCode(md);
  const re = /^<details(?:\s+open)?\s*>[ \t]*$/gim;
  let m: RegExpExecArray | null;
  while ((m = re.exec(masked))) {
    const at = m.index;
    const d = splitDetails(md.slice(at), masked.slice(at));
    if (!d) continue;
    const rest = md.slice(at + d.length);
    return `${md.slice(0, at)}\n${d.summary}\n\n${stripToggleTags(d.inner)}\n\n${stripToggleTags(rest)}`;
  }
  return md;
}
