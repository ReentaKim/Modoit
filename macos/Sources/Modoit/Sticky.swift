import AppKit
import ModoitCore
import ModoitKit
import WebKit

// 스티키 = 메모 하나를 바탕화면에 꺼낸 상태 (F-08). 메인 창과 같은 편집 세션을 쓴다 (V2-09).
// 보기 전용이다. 체크박스만 누를 수 있고, 두 번 누르면 메인 창에서 열린다 (D-25).
// 옮겨 온 곳: src-tauri/src/sticky.rs, src/sticky/StickyApp.tsx

/// 스티키 색: 종이, 상단 막대, 강조(체크·링크). 값은 v0.x sticky.css와 같다
struct StickyPaper {
    let body: NSColor
    let bar: NSColor
    let accent: NSColor
    /// 웹 화면에 넘기는 강조 색(`#rrggbb`)
    let accentHex: String

    private static func c(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func named(_ name: String) -> StickyPaper {
        switch name {
        case "pink": StickyPaper(body: c(0xffe0ea), bar: c(0xffc4d6), accent: c(0xb0405f), accentHex: "#b0405f")
        case "blue": StickyPaper(body: c(0xdcefff), bar: c(0xbfe0ff), accent: c(0x2f6fae), accentHex: "#2f6fae")
        case "green": StickyPaper(body: c(0xe1f7d8), bar: c(0xc8efb8), accent: c(0x3d7f2a), accentHex: "#3d7f2a")
        case "purple": StickyPaper(body: c(0xece3ff), bar: c(0xdccbff), accent: c(0x6a4bb5), accentHex: "#6a4bb5")
        default: StickyPaper(body: c(0xfff6b3), bar: c(0xffe97a), accent: c(0x8a6d00), accentHex: "#8a6d00")
        }
    }
}

/// 눌러도 다른 앱이 비활성화되지 않는 패널 (FR-40). 글을 골라 복사할 수 있게 키 입력은 받는다
final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 상단 막대. 빈 곳을 끌면 창이 움직인다
private final class StickyBar: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 마우스를 올렸을 때만 색 견본을 보인다 (F-08 4.3)
private final class StickyRoot: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

private final class Swatch: NSButton {
    var colorName = ""
}

@MainActor
final class StickyController: NSObject, NSWindowDelegate {
    let session: NoteSession
    let id = EditorID()
    let panel: StickyPanel
    private(set) var meta: StickyMeta
    private(set) var kind: StickyEditorKind
    /// ⌘⇧N으로 방금 만든 메모인가. 빈 채로 넣을 때만 휴지통으로 보낸다 (F-08 R-7)
    let fresh: Bool
    private(set) var textView: MarkupTextView?
    private(set) var web: WebEditor?

    private unowned let manager: StickyManager
    private let root = StickyRoot()
    private let bar = StickyBar()
    private let editorHost = NSView()
    private let swatches = NSStackView()
    private var pinButton: NSButton!
    private var geometryGeneration = 0
    private var shown = false
    private let vault: String
    private var prefs: Prefs

    init(session: NoteSession, meta: StickyMeta, fresh: Bool, manager: StickyManager, vault: String, prefs: Prefs, index: Int) {
        self.session = session
        self.meta = meta
        self.fresh = fresh
        self.manager = manager
        self.vault = vault
        self.prefs = prefs
        kind = stickyEditorKind(session.body)
        panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 280),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        configurePanel(index: index)
        buildViews()
        installEditor()
        session.attach(id) { [weak self] body in self?.sessionChanged(body) }
        panel.delegate = self
    }

    // MARK: 창

    private static func screens() -> (primaryHeight: Double, rects: [ScreenRect]) {
        let h = Double(NSScreen.screens.first?.frame.height ?? 900)
        return (h, NSScreen.screens.map { ScreenRect(Double($0.frame.minX), h - Double($0.frame.maxY), Double($0.frame.width), Double($0.frame.height)) })
    }

    private func configurePanel(index: Int) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        // 모든 데스크톱과 전체 화면 앱 위에 보인다 (FR-40)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: stickyMinWidth, height: stickyMinHeight)
        // 스티키는 다크 모드에서도 밝은 종이다
        panel.appearance = NSAppearance(named: .aqua)
        panel.title = "Sticky"
        applyLevel()

        let (primary, rects) = Self.screens()
        let w = max(meta.w, stickyMinWidth), h = max(meta.h, stickyMinHeight)
        var x = meta.x, y = meta.y
        // 기억한 위치가 연결된 모니터 밖이면 기본 위치 (F-08 R-8, BUG-12)
        if x == nil || y == nil || !barVisible(x: x!, y: y!, w: w, monitors: rects) {
            let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let o = defaultStickyOrigin(index: index, screen: ScreenRect(Double(v.minX), primary - Double(v.maxY), Double(v.width), Double(v.height)))
            (x, y) = (o.x, o.y)
        }
        panel.setFrame(NSRect(x: x!, y: primary - y! - h, width: w, height: h), display: false)
    }

    private func applyLevel() {
        panel.level = meta.onTop ? .floating : .normal
        panel.isFloatingPanel = meta.onTop
    }

    /// 지금 창의 위치·크기 (v0.x 좌표)
    private func currentGeometry() -> (x: Double, y: Double, w: Double, h: Double) {
        let f = panel.frame
        let primary = Self.screens().primaryHeight
        return (Double(f.minX), primary - Double(f.maxY), Double(f.width), Double(f.height))
    }

    func show(key: Bool) {
        if key {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        shown = true
    }

    func close() {
        shown = false
        session.detach(id)
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    func windowDidMove(_ notification: Notification) { geometryChanged() }
    func windowDidResize(_ notification: Notification) { geometryChanged() }

    /// 움직임이 멈춘 뒤 한 번 저장한다 (F-08 4.3)
    private func geometryChanged() {
        guard shown else { return }
        geometryGeneration += 1
        let g = geometryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.shown, self.geometryGeneration == g else { return }
            self.syncGeometry()
            self.manager.write(self)
        }
    }

    /// 창의 지금 위치·크기를 meta에 담는다
    func syncGeometry() {
        let g = currentGeometry()
        (meta.x, meta.y, meta.w, meta.h) = (g.x, g.y, g.w, g.h)
    }

    // MARK: 화면

    private func symbolButton(_ name: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: label)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = NSColor.black.withAlphaComponent(0.55)
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    private func buildViews() {
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        bar.wantsLayer = true
        panel.contentView = root

        swatches.orientation = .horizontal
        swatches.spacing = 5
        swatches.alphaValue = 0
        for name in stickyColors {
            let s = Swatch(title: "", target: self, action: #selector(pickColor(_:)))
            s.colorName = name
            s.isBordered = false
            s.wantsLayer = true
            s.layer?.cornerRadius = 6.5
            s.layer?.backgroundColor = StickyPaper.named(name).bar.cgColor
            s.layer?.borderWidth = 1
            s.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            s.toolTip = name
            s.widthAnchor.constraint(equalToConstant: 13).isActive = true
            s.heightAnchor.constraint(equalToConstant: 13).isActive = true
            swatches.addArrangedSubview(s)
        }
        root.onHover = { [weak self] on in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self?.swatches.animator().alphaValue = on ? 1 : 0 }
        }

        pinButton = symbolButton("pin", "항상 위에 고정", #selector(togglePin))
        let openMain = symbolButton("macwindow", "메인 창에서 열기", #selector(openInMain))
        let closeButton = symbolButton("xmark", "다시 넣기", #selector(putBack))
        let buttons = NSStackView(views: [pinButton, openMain, closeButton])
        buttons.spacing = 2

        for v in [bar, editorHost, swatches, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(bar)
        root.addSubview(editorHost)
        bar.addSubview(swatches)
        bar.addSubview(buttons)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: stickyBarHeight),
            swatches.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            swatches.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            editorHost.topAnchor.constraint(equalTo: bar.bottomAnchor),
            editorHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        applyLook()
    }

    private func applyLook() {
        let paper = StickyPaper.named(meta.color)
        root.layer?.backgroundColor = paper.body.cgColor
        bar.layer?.backgroundColor = paper.bar.cgColor
        textView?.accent = paper.accent
        web?.tint(paper.accentHex)
        pinButton.image = NSImage(systemSymbolName: meta.onTop ? "pin.fill" : "pin", accessibilityDescription: "항상 위에 고정")
        pinButton.contentTintColor = meta.onTop ? paper.accent : NSColor.black.withAlphaComponent(0.55)
    }

    // MARK: 편집기 (F-08 4.2)

    private func fill(_ v: NSView) {
        editorHost.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        editorHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: editorHost.topAnchor), v.bottomAnchor.constraint(equalTo: editorHost.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: editorHost.leadingAnchor), v.trailingAnchor.constraint(equalTo: editorHost.trailingAnchor),
        ])
    }

    private func installEditor() {
        textView = nil
        web = nil
        switch kind {
        case .native:
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            let tv = MarkupTextView.make(frame: NSRect(x: 0, y: 0, width: 280, height: 250))
            tv.minSize = .zero
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            tv.accent = StickyPaper.named(meta.color).accent
            tv.show(session.body)
            tv.onChange = { [weak self, weak tv] in
                guard let self, let tv else { return }
                // 체크한 원문을 그대로 보낸다. 다른 줄은 바이트가 그대로다 (F-08 R-9)
                self.session.edit(tv.string, from: self.id)
            }
            tv.onOpen = { [weak self] in self?.openInMain() }
            scroll.documentView = tv
            fill(scroll)
            textView = tv
        case .web:
            let w = WebEditor()
            w.vault = vault
            w.webView.appearance = NSAppearance(named: .aqua)
            // 보기 전용이라 change는 오지 않는다. 체크만 원문의 그 줄 한 글자를 바꾼다
            w.onCheck = { [weak self] index, checked in
                guard let self, let body = toggleCheckbox(self.session.body, index: index, checked: checked) else { return }
                self.session.edit(body, from: self.id)
                self.web?.update(markdown: body)
            }
            w.onOpen = { [weak self] in self?.openInMain() }
            w.onError = { [weak self] m in self?.manager.notice(m) }
            w.load(markdown: session.body, notePath: session.path, compact: true, viewer: true,
                   tint: StickyPaper.named(meta.color).accentHex, prefs: prefs)
            fill(w.webView)
            web = w
        }
    }

    /// 다른 쪽(메인 창, 다른 앱)에서 본문이 바뀌었다
    private func sessionChanged(_ body: String) {
        if let t = textView { t.show(body) } else { web?.update(markdown: body) }
        manager.recheck(self)
    }

    /// 본문에 맞는 방식으로 다시 그린다. 보기 전용이라 어느 쪽으로든 바로 바꾼다 (R-10)
    func switchKindIfNeeded() {
        let want = stickyEditorKind(session.body)
        guard want != kind else { return }
        kind = want
        installEditor()
    }

    func pathChanged() { web?.moved(to: session.path) }

    func apply(prefs p: Prefs) {
        prefs = p
        web?.apply(prefs: p)
        textView?.refont()
    }

    // MARK: 막대 버튼

    func set(onTop: Bool) {
        meta.onTop = onTop
        applyLevel()
        applyLook()
    }

    func set(color: String) {
        meta.color = color
        applyLook()
    }

    @objc private func togglePin() { manager.setOnTop(session.path, !meta.onTop) }
    @objc private func openInMain() { manager.openInMain(session.path) }
    @objc private func putBack() { manager.putBack(session.path) }
    @objc private func pickColor(_ sender: Swatch) { manager.setColor(session.path, sender.colorName) }
}

/// 떠 있는 스티키 모음. 꺼내기·넣기와 frontmatter `sticky` 저장을 맡는다 (F-08 4.1)
@MainActor
final class StickyManager {
    weak var model: AppModel?
    private(set) var controllers: [StickyController] = []

    func controller(_ path: String) -> StickyController? { controllers.first { $0.session.path.sameBytes(path) } }
    func isOpen(_ path: String) -> Bool { controller(path) != nil }
    func notice(_ text: String) { model?.show(notice: text) }

    /// 스티키 정보를 그 메모의 frontmatter에 쓴다. 본문과 다른 키는 그대로다 (R-2, NFR-09)
    func write(_ c: StickyController) {
        guard let model, let vault = model.vault else { return }
        do {
            try patchMeta(vault: vault, c.session.path, MetaPatch(sticky: .some(c.meta)))
        } catch {
            notice("스티키 정보를 저장하지 못했습니다: \(error)")
        }
        model.refresh()
    }

    private func make(_ s: NoteSession, _ meta: StickyMeta, fresh: Bool) -> StickyController? {
        guard let model, let vault = model.vault else { return nil }
        Metrics.use(model.prefs)
        let c = StickyController(session: s, meta: meta, fresh: fresh, manager: self, vault: vault, prefs: model.prefs, index: controllers.count)
        controllers.append(c)
        return c
    }

    /// 메모를 스티키로 꺼낸다 (FR-30)
    func popOut(_ path: String, fresh: Bool = false) {
        guard let model, let vault = model.vault, let store = model.store else { return }
        if let c = controller(path) { return c.show(key: true) }
        // 입력을 먼저 저장한다. 저장하며 이름이 바뀔 수 있다 (BUG-28)
        let existing = store.existing(path)
        existing?.flush()
        let p = existing?.path ?? path
        do {
            var meta = readMeta(front: try readParts(vault: vault, p).front).sticky ?? .firstOpen
            meta.open = true
            try patchMeta(vault: vault, p, MetaPatch(sticky: .some(meta)))
            let s = try store.open(p, createdNew: fresh)
            make(s, meta, fresh: fresh)?.show(key: false)
        } catch {
            notice("스티키로 꺼낼 수 없습니다: \(error)")
        }
        model.refresh()
    }

    private func remove(_ c: StickyController) {
        c.close()
        controllers.removeAll { $0 === c }
        model?.store?.detach(c.id, from: c.session)
    }

    /// 다시 넣는다. 저장하지 못한 입력이 있으면 넣지 않는다 (R-5). 색·위치·크기는 기억한다 (R-3)
    @discardableResult
    func putBack(_ path: String, forget: Bool = false) -> Bool {
        guard let model, let vault = model.vault, let store = model.store, let c = controller(path) else { return false }
        if !c.session.flush() {
            notice("저장하지 못한 입력이 있어 스티키를 넣지 않았습니다.")
            return false
        }
        c.syncGeometry()
        var meta = c.meta
        meta.open = false
        let p = c.session.path
        do {
            try patchMeta(vault: vault, p, MetaPatch(sticky: forget ? .some(nil) : .some(meta)))
        } catch {
            notice("스티키를 넣지 못했습니다: \(error)")
            return false
        }
        let blank = c.fresh && c.session.body.allSatisfy(\.isWhitespace)
        remove(c)
        // ⌘⇧N으로 만든 빈 메모만 정리한다 (R-7, BUG-23)
        if blank, store.existing(p)?.editorCount ?? 0 == 0 {
            store.discardUnder(p)
            try? trashPath(vault + "/" + p)
        }
        model.refresh()
        return true
    }

    /// 색·위치 기억 지우기: sticky 키만 지운다 (FR-44)
    func forget(_ path: String) {
        guard let model, let vault = model.vault else { return }
        if isOpen(path) {
            putBack(path, forget: true)
            return
        }
        let s = model.store?.existing(path)
        s?.flush()
        do {
            try patchMeta(vault: vault, s?.path ?? path, MetaPatch(sticky: .some(nil)))
        } catch {
            notice("기억을 지우지 못했습니다: \(error)")
        }
        model.refresh()
    }

    func toggle(_ path: String) {
        if isOpen(path) { putBack(path) } else { popOut(path) }
    }

    /// 항상 위 (FR-40). 사이드바의 핀과 스티키 막대의 핀이 같은 상태다 (FR-55)
    func setOnTop(_ path: String, _ on: Bool) {
        guard let c = controller(path) else { return }
        c.set(onTop: on)
        write(c)
    }

    func setColor(_ path: String, _ color: String) {
        guard let c = controller(path), stickyColors.contains(color) else { return }
        c.set(color: color)
        write(c)
    }

    func openInMain(_ path: String) { model?.reveal(path) }

    /// 시작할 때(저장 폴더를 열 때) 떠 있던 스티키를 다시 띄운다. 파일을 쓰지 않는다 (R-8)
    func restore() {
        guard let model, let store = model.store else { return }
        for n in model.tree.notes where n.sticky?.open == true && !isOpen(n.path) {
            guard let meta = n.sticky, let s = try? store.open(n.path) else { continue }
            make(s, meta, fresh: false)?.show(key: false)
        }
    }

    /// 파일에 쓰지 않고 모두 닫는다(저장 폴더 변경). 입력은 부르는 쪽이 먼저 저장한다
    func closeAll() {
        for c in controllers { c.close(); model?.store?.detach(c.id, from: c.session) }
        controllers = []
    }

    /// 휴지통으로 보내는 메모·폴더의 스티키를 저장 없이 닫는다 (Brief 3.3-4)
    func discardUnder(_ path: String) {
        for c in controllers where c.session.path.sameBytes(path) || c.session.path.bytesHasPrefix(path + "/") {
            c.close()
            controllers.removeAll { $0 === c }
        }
    }

    func pathsChanged() { controllers.forEach { $0.pathChanged() } }
    func apply(prefs: Prefs) {
        Metrics.use(prefs)
        controllers.forEach { $0.apply(prefs: prefs) }
    }

    func recheck(_ c: StickyController) {
        // 편집 처리 도중에 편집기를 바꾸지 않는다
        DispatchQueue.main.async { [weak c] in c?.switchKindIfNeeded() }
    }
}
