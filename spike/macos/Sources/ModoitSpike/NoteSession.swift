import Foundation
import ModoitCore

/// v0.3 `noteSession.ts`의 축소판: 입력 0.5초 뒤 본문만 저장한다.
/// 스파이크에서 뺀 것: 3-way 병합(BUG-26), 이름 맞추기(sync_note_name), 재시도 안내 막대.
@MainActor
final class NoteSession {
    let vault: Vault
    let path: String
    var onSaved: (() -> Void)?
    private var pending: String?
    private var timer: Task<Void, Never>?

    init(vault: Vault, path: String) {
        self.vault = vault
        self.path = path
    }

    func edit(_ body: String) {
        pending = body
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        timer?.cancel()
        guard let body = pending else { return }
        pending = nil
        do {
            try vault.writeBody(path, body: body)
            onSaved?()
        } catch {
            pending = body
            print("[session] 저장 실패:", error)
        }
    }
}
