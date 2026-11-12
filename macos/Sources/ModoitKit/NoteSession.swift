import Foundation
import ModoitCore

// 열려 있는 메모 하나의 편집 상태. 메모 하나에 세션 하나이고, 메인 창과 스티키가 함께 쓴다 (아키텍처 3.2, V2-09).
// - `body`가 화면의 기준이다. 한 편집기가 고치면 같은 세션에 붙은 다른 편집기에 바로 알린다(파일을 거치지 않는다).
// - 본문만 고친다. frontmatter는 저장할 때마다 디스크 최신본을 그대로 쓴다 (Brief 3.4).
// - 입력을 멈추고 0.5초 뒤 저장, 실패하면 3초마다 다시 시도한다 (Brief 3.2).
// - 저장 직전 디스크 본문이 알던 것과 다르면(다른 앱이 고침) 줄 단위로 병합한다 (BUG-26).
// - 저장은 메인 스레드에서 한 번에 끝낸다. 메모는 작고, 저장 도중에 입력이 끼어드는 경합(BUG-39)이 생기지 않는다.
// 옮겨 온 곳: src/lib/noteSession.ts

public struct EditorID: Hashable, Sendable {
    private let raw = UUID()
    public init() {}
}

@MainActor
public final class NoteSession {
    public struct Delays: Sendable {
        public var save: TimeInterval = 0.5
        public var retry: TimeInterval = 3
        public init(save: TimeInterval = 0.5, retry: TimeInterval = 3) {
            self.save = save
            self.retry = retry
        }
    }

    public let vault: String
    public private(set) var path: String
    /// 지금 화면에 보여야 하는 본문
    public private(set) var body: String
    /// 디스크와 같다고 알고 있는 본문(병합의 기준)
    public private(set) var saved: String
    /// 이번 실행에서 앱이 만든 메모인가. 빈 채로 떠나면 정리한다 (Brief 3.3-2)
    public let createdNew: Bool
    /// 저장하지 못한 입력이 있는가
    public private(set) var dirty = false
    /// 저장 실패 이유. 성공하면 nil (NFR-13)
    public private(set) var failure: String?
    /// 저장한 뒤 파일 이름을 제목에 맞출지
    public var syncName = true

    /// 저장 실패 여부가 바뀌었다
    public var onState: (() -> Void)?
    /// 제목이 바뀌어 파일 이름(경로)이 바뀌었다: (옛 경로, 새 경로)
    public var onRenamed: ((String, String) -> Void)?
    /// 저장했다(목록을 다시 읽을 때)
    public var onSaved: (() -> Void)?

    private let delays: Delays
    private var editors: [EditorID: (String) -> Void] = [:]
    /// 본문은 저장됐지만 파일 이름을 아직 제목에 맞추지 못했다 (BUG-25)
    private var nameStale = false
    private var discarded = false
    private var timerGeneration = 0

    public init(vault: String, path: String, body: String, createdNew: Bool = false, delays: Delays = Delays()) {
        self.vault = vault
        self.path = path
        self.body = body
        self.saved = body
        self.createdNew = createdNew
        self.delays = delays
    }

    /// 아직 할 일이 남았는가(저장 또는 이름 맞추기)
    public var busy: Bool { dirty || nameStale }
    public var editorCount: Int { editors.count }

    // MARK: 편집기

    /// 편집기를 붙인다. 다른 쪽에서 본문이 바뀌면 `onChange`로 알린다
    public func attach(_ id: EditorID, onChange: @escaping (String) -> Void) {
        editors[id] = onChange
    }

    public func detach(_ id: EditorID) {
        editors[id] = nil
    }

    private func notify(except: EditorID?) {
        for (id, f) in editors where id != except { f(body) }
    }

    /// 편집기 `from`에서 사용자가 본문을 고쳤다
    public func edit(_ new: String, from: EditorID?) {
        guard !discarded, new != body else { return }
        body = new
        dirty = true
        notify(except: from)
        schedule(delays.save)
    }

    /// 편집기가 예전 본문(`base`)을 보고 만든 `new`를 보냈다. 그 사이 다른 편집기가 고친 줄과 합친다.
    /// TipTap처럼 본문 전체를 보내는 편집기가 쓴다
    public func edit(_ new: String, basedOn base: String, from: EditorID?) {
        if base == body {
            edit(new, from: from)
        } else {
            let merged = mergeBodies(base: base, mine: new, theirs: body)
            guard !discarded, merged != body else {
                // 내 입력이 이미 다 들어 있다. 보낸 쪽 화면만 맞춘다
                if merged != new, let from, let f = editors[from] { f(body) }
                return
            }
            body = merged
            dirty = true
            // 보낸 쪽도 합친 결과로 다시 그려야 한다
            notify(except: merged == new ? from : nil)
            schedule(delays.save)
        }
    }

    // MARK: 저장

    private func schedule(_ delay: TimeInterval) {
        timerGeneration += 1
        let g = timerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.timerGeneration == g else { return }
            self.flush()
        }
    }

    /// 남은 입력을 지금 저장한다. 다 저장됐으면 true
    @discardableResult
    public func flush() -> Bool {
        timerGeneration += 1
        guard !discarded, busy else { return !busy }
        do {
            if dirty {
                let mine = body
                var written = mine
                if noteExists(vault: vault, path) {
                    try updateNote(vault: vault, path) { parts in
                        written = parts.body == saved ? mine : mergeBodies(base: saved, mine: mine, theirs: parts.body)
                        parts.body = written
                    }
                } else {
                    // 파일이 사라졌으면(Finder에서 옮김·지움, 동기화) 그 자리에 다시 만들어 입력을 살린다 (BUG-40)
                    try atomicWrite(mine, to: try resolve(vault: vault, path))
                }
                saved = written
                dirty = false
                if written != mine {
                    body = written
                    notify(except: nil)
                }
                nameStale = syncName
            }
            if nameStale {
                let old = path
                let np = try syncNoteName(vault: vault, path)
                nameStale = false
                if !np.sameBytes(old) {
                    path = np
                    onRenamed?(old, np)
                }
            }
            setFailure(nil)
            onSaved?()
            return true
        } catch {
            setFailure("\(error)")
            schedule(delays.retry)
            return false
        }
    }

    private func setFailure(_ f: String?) {
        guard f != failure else { return }
        failure = f
        onState?()
    }

    /// 다른 앱이 파일을 바꿨다(파일 감시). 입력 중이 아니면 새 내용을 보여 주고, 입력 중이면 병합해 저장한다 (F-07 4.2)
    public func diskChanged() {
        guard !discarded else { return }
        guard let disk = try? readParts(vault: vault, path).body else {
            // 지워졌다. 남은 입력이 있으면 그 자리에 다시 만든다
            if dirty { flush() }
            return
        }
        if disk == saved { return }
        if dirty {
            flush()
        } else {
            saved = disk
            body = disk
            notify(except: nil)
        }
    }

    /// 더 이상 저장하지 않는다(휴지통으로 보낼 때). 남겨 두면 다음 저장이 지운 파일을 다시 만든다 (Brief 3.3-4)
    public func discard() {
        discarded = true
        dirty = false
        nameStale = false
        timerGeneration += 1
        setFailure(nil)
    }

    /// 이름 변경·이동을 반영한다
    public func moved(to newPath: String) {
        path = newPath
    }
}
