import Foundation
import ModoitCore

/// 열린 메모의 세션 모음. 같은 메모를 여는 편집기는 같은 세션을 받는다 (V2-09).
@MainActor
public final class SessionStore {
    public let vault: String
    private let delays: NoteSession.Delays
    private var sessions: [NoteSession] = []

    /// 세션의 저장 실패 여부가 바뀌었다
    public var onState: (() -> Void)?
    /// 어떤 메모가 저장됐다 / 파일 이름이 바뀌었다
    public var onSaved: (() -> Void)?
    public var onRenamed: ((String, String) -> Void)?

    public init(vault: String, delays: NoteSession.Delays = NoteSession.Delays()) {
        self.vault = vault
        self.delays = delays
    }

    public func existing(_ path: String) -> NoteSession? {
        sessions.first { $0.path.sameBytes(path) }
    }

    /// 그 메모의 세션. 없으면 파일을 읽어 만든다. UTF-8이 아니면 `VaultError.notUTF8`
    public func open(_ path: String, createdNew: Bool = false) throws -> NoteSession {
        if let s = existing(path) { return s }
        let body = try readParts(vault: vault, path).body
        let s = NoteSession(vault: vault, path: path, body: body, createdNew: createdNew, delays: delays)
        s.onState = { [weak self] in self?.onState?() }
        s.onSaved = { [weak self, weak s] in
            self?.onSaved?()
            if let s { self?.sweep(s) }
        }
        s.onRenamed = { [weak self] old, new in self?.onRenamed?(old, new) }
        sessions.append(s)
        return s
    }

    /// 편집기가 떠났다. 저장할 것이 남았으면 저장될 때까지 세션을 살려 둔다 (BUG-24)
    public func detach(_ id: EditorID, from s: NoteSession) {
        s.detach(id)
        if s.editorCount == 0 { s.flush() }
        sweep(s)
    }

    private func sweep(_ s: NoteSession) {
        if s.editorCount == 0, !s.busy { sessions.removeAll { $0 === s } }
    }

    /// 모든 메모를 지금 저장한다. 저장하지 못한 메모 수를 돌려준다 (종료 직전, 저장 폴더 변경, 이동 전)
    @discardableResult
    public func flushAll() -> Int {
        for s in sessions { s.flush() }
        let unsaved = unsavedCount
        for s in sessions { sweep(s) }
        return unsaved
    }

    public var unsavedCount: Int { sessions.filter(\.dirty).count }
    /// 화면에서 떠났는데 아직 저장하지 못한 메모 수
    public var backgroundFailing: Int { sessions.filter { $0.editorCount == 0 && $0.dirty }.count }
    public var failing: [NoteSession] { sessions.filter { $0.failure != nil } }
    public var count: Int { sessions.count }

    /// 그 경로(또는 그 폴더 아래, ""이면 전부)의 세션을 저장하지 않고 닫는다: 휴지통으로 보낼 때 (Brief 3.3-4)
    public func discardUnder(_ path: String) {
        for s in sessions where path.isEmpty || s.path.sameBytes(path) || s.path.bytesHasPrefix(path + "/") { s.discard() }
        sessions.removeAll { !$0.busy && ($0.editorCount == 0 || path.isEmpty || $0.path.sameBytes(path) || $0.path.bytesHasPrefix(path + "/")) }
    }

    /// 이름 변경·이동(from → to)을 열린 세션의 경로에 반영한다
    public func applyMove(from: String, to: String) {
        for s in sessions {
            if s.path.sameBytes(from) {
                s.moved(to: to)
            } else if s.path.bytesHasPrefix(from + "/") {
                s.moved(to: to + s.path.droppingBytes(from.utf8.count))
            }
        }
    }

    /// 파일 감시: 바뀐 메모를 열린 세션에 알린다
    public func diskChanged(_ paths: [String]? = nil) {
        for s in sessions where paths == nil || paths!.contains(where: { $0.sameBytes(s.path) }) { s.diskChanged() }
    }
}
