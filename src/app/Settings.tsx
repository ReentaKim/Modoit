import { useEffect } from "react";
import { X } from "@phosphor-icons/react";
import type { Prefs } from "../lib/api";
import { ACCENT_CHOICES, FONT_CHOICES, THEME_CHOICES, fontCss } from "../lib/prefs";

interface Props {
  prefs: Prefs;
  onChange: (p: Partial<Prefs>) => void;
  onClose: () => void;
}

const NOTICES = [
  ["Phosphor Icons", "MIT"],
  ["Pretendard", "SIL Open Font License 1.1"],
  ["TipTap", "MIT"],
  ["Tauri", "MIT / Apache-2.0"],
  ["marked", "MIT"],
  ["yaml", "ISC"],
  ["node-diff3", "MIT"],
];

export function Settings({ prefs, onChange, onClose }: Props) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="sheet-backdrop" onMouseDown={onClose}>
      <div className="sheet" onMouseDown={(e) => e.stopPropagation()}>
        <div className="sheet-head">
          <h2>설정</h2>
          <button className="icon-btn" title="닫기 (Esc)" onClick={onClose}>
            <X size={18} />
          </button>
        </div>

        <label className="field-label">모양</label>
        <div className="segmented">
          {THEME_CHOICES.map((t) => (
            <button key={t.id} className={prefs.theme === t.id ? "on" : ""} onClick={() => onChange({ theme: t.id })}>
              {t.label}
            </button>
          ))}
        </div>

        <label className="field-label">강조 색</label>
        <div className="accent-row" role="radiogroup" aria-label="강조 색">
          {ACCENT_CHOICES.map((c) => (
            <button
              key={c.id}
              role="radio"
              aria-checked={prefs.accent === c.id}
              title={c.label}
              className={`accent-dot ${prefs.accent === c.id ? "on" : ""}`}
              style={{ background: c.swatch }}
              onClick={() => onChange({ accent: c.id })}
            />
          ))}
        </div>

        <label className="field-label">글꼴</label>
        <div className="segmented">
          {FONT_CHOICES.map((f) => (
            <button
              key={f.id}
              className={prefs.fontFamily === f.id ? "on" : ""}
              style={{ fontFamily: f.id === "custom" ? undefined : f.css }}
              onClick={() => onChange({ fontFamily: f.id })}
            >
              {f.label}
            </button>
          ))}
        </div>
        {prefs.fontFamily === "custom" && (
          <input
            className="text-field"
            placeholder="설치된 글꼴 이름 (예: Nanum Gothic)"
            value={prefs.customFont}
            onChange={(e) => onChange({ customFont: e.target.value })}
          />
        )}

        <label className="field-label">
          본문 크기 <span className="value">{prefs.fontSize}px</span>
        </label>
        <input
          type="range"
          min={14}
          max={22}
          step={1}
          value={prefs.fontSize}
          onChange={(e) => onChange({ fontSize: Number(e.target.value) })}
        />

        <div className="preview" style={{ fontFamily: fontCss(prefs), fontSize: prefs.fontSize }}>
          <p>다람쥐 헌 쳇바퀴에 타고파 — The quick brown fox</p>
          <p className="preview-task">
            <span className="dot" /> 체크박스 한 줄
          </p>
        </div>

        <details className="about">
          <summary>Modoit 정보 · 라이선스</summary>
          <p>Modoit v0.2 — 메모와 스티키를 하나로.</p>
          <ul>
            {NOTICES.map(([n, l]) => (
              <li key={n}>
                {n} — {l}
              </li>
            ))}
          </ul>
        </details>
      </div>
    </div>
  );
}
