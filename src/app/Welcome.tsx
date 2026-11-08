export function Welcome({ onPick }: { onPick: () => void }) {
  return (
    <div className="welcome" data-tauri-drag-region>
      <div className="welcome-card">
        <div className="welcome-mark" aria-hidden>
          <span />
        </div>
        <h1>Modoit에 오신 것을 환영합니다</h1>
        <p>
          메모를 저장할 폴더를 먼저 정해 주세요.
          <br />
          모든 메모는 이 폴더 안에 .md 파일로 저장됩니다.
        </p>
        <button className="primary" onClick={onPick}>
          저장 폴더 선택…
        </button>
        <p className="hint">나중에 사이드바 아래에서 언제든 바꿀 수 있어요.</p>
      </div>
    </div>
  );
}
