import AppKit
import ModoitCore

enum StickyKind: String {
    /// v2.0 계획: TipTap 편집기를 WKWebView로
    case web
    /// v2.x 후보: NSTextView (스파이크는 Markdown 원문을 그대로 편집)
    case native
}

private let stickyBackground: [String: NSColor] = [
    "yellow": NSColor(srgbRed: 1, green: 0xf6 / 255, blue: 0xb3 / 255, alpha: 1),
    "pink": NSColor(srgbRed: 1, green: 0xe0 / 255, blue: 0xea / 255, alpha: 1),
    "blue": NSColor(srgbRed: 0xdc / 255, green: 0xef / 255, blue: 1, alpha: 1),
    "green": NSColor(srgbRed: 0xe1 / 255, green: 0xf7 / 255, blue: 0xd8 / 255, alpha: 1),
    "purple": NSColor(srgbRed: 0xec / 255, green: 0xe3 / 255, blue: 1, alpha: 1),
]

/// 스티키 = 키 창이 될 수 있는 non-activating NSPanel (공개 API만 사용, ADR-14)
final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StickyController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let path: String
    let panel: StickyPanel
    private let vault: Vault
    private let session: NoteSession
    private var meta: StickyMeta
    /// 디스크에 있는 sticky 값. 같으면 다시 쓰지 않는다 (열기만 해서는 쓰지 않음)
    private var written: StickyMeta?
    private var web: WebEditor?
    private var textView: NSTextView?
    private var geometryTimer: Task<Void, Never>?
    var onClose: ((String) -> Void)?

    init(vault: Vault, path: String, meta: StickyMeta?, kind: StickyKind, onLoaded: @escaping () -> Void) {
        self.vault = vault
        self.path = path
        self.session = NoteSession(vault: vault, path: path)
        var m = meta ?? StickyMeta()
        m.open = true
        self.meta = m
        self.written = meta

        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // frontmatter의 x·y는 v0.3(Tauri)처럼 주 화면 왼쪽 위 기준
        let origin = NSPoint(x: m.x ?? 120, y: screen.maxY - (m.y ?? 120) - m.h)
        panel = StickyPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: m.w, height: m.h)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = stickyBackground[m.color] ?? stickyBackground["yellow"]!
        panel.level = m.onTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        if m.x == nil { panel.center() }

        let body = (try? vault.read(path)).map { splitNote($0).body } ?? ""
        switch kind {
        case .web:
            let w = WebEditor(vault: vault)
            w.onChange = { [session] in session.edit($0) }
            w.onLoaded = onLoaded
            w.load(markdown: body, notePath: path, compact: true)
            w.webView.frame = panel.contentView!.bounds
            w.webView.autoresizingMask = [.width, .height]
            panel.contentView!.addSubview(w.webView)
            web = w
        case .native:
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = panel.contentView!.bounds.insetBy(dx: 0, dy: 0)
            scroll.autoresizingMask = [.width, .height]
            scroll.drawsBackground = false
            let tv = scroll.documentView as! NSTextView
            tv.drawsBackground = false
            tv.font = .systemFont(ofSize: 16)
            tv.textColor = NSColor(srgbRed: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255, alpha: 1)
            tv.textContainerInset = NSSize(width: 12, height: 28)
            tv.isRichText = false
            tv.allowsUndo = true
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.string = body
            tv.delegate = self
            panel.contentView!.addSubview(scroll)
            textView = tv
            DispatchQueue.main.async { onLoaded() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        saveGeometry()
    }

    func textDidChange(_ notification: Notification) {
        if let tv = textView { session.edit(tv.string) }
    }

    func windowDidMove(_ notification: Notification) { scheduleGeometry() }
    func windowDidResize(_ notification: Notification) { scheduleGeometry() }

    /// ✕ = 다시 넣기: 남은 입력을 저장하고 open:false
    func windowWillClose(_ notification: Notification) {
        session.flush()
        meta.open = false
        try? vault.updateSticky(path, meta)
        onClose?(path)
    }

    private func scheduleGeometry() {
        geometryTimer?.cancel()
        geometryTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveGeometry()
        }
    }

    private func saveGeometry() {
        let screen = NSScreen.screens.first?.frame ?? .zero
        let f = panel.frame
        let next = StickyMeta(color: meta.color, x: f.minX.rounded(), y: (screen.maxY - f.maxY).rounded(),
                              w: f.width.rounded(), h: f.height.rounded(), onTop: meta.onTop, open: true)
        meta = next
        guard next != written else { return }
        session.flush()
        try? vault.updateSticky(path, next)
        written = next
    }

    func flush() { session.flush() }
}

@MainActor
final class StickyManager {
    private(set) var open: [String: StickyController] = [:]
    var onChanged: (() -> Void)?

    func show(vault: Vault, path: String, meta: StickyMeta?, kind: StickyKind, onLoaded: @escaping () -> Void = {}) {
        if let c = open[path] {
            c.panel.orderFrontRegardless()
            onLoaded()
            return
        }
        let c = StickyController(vault: vault, path: path, meta: meta, kind: kind, onLoaded: onLoaded)
        c.onClose = { [weak self] p in
            self?.open[p] = nil
            self?.onChanged?()
        }
        open[path] = c
        c.show()
        onChanged?()
    }

    func flushAll() { open.values.forEach { $0.flush() } }
}
