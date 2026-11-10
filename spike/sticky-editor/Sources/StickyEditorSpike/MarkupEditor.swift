import AppKit
import ModoitCore

// Markdown 원문을 그대로 담은 NSTextView. 글자는 바꾸지 않고 속성만 입혀 꾸민다.
// - 숨길 기호: 아주 작은 투명 글꼴로 만들어 폭을 없앤다
// - 점·번호·체크박스·인용 막대·구분선: 레이아웃 매니저가 여백에 그린다

extension NSAttributedString.Key {
    /// 문단의 모양(StickyLine). 문단 전체에 붙인다
    static let stickyLine = NSAttributedString.Key("modoit.stickyLine")
}

final class LineInfo: NSObject {
    let line: StickyLine
    init(_ line: StickyLine) { self.line = line }
}

enum Metrics {
    static let fontSize: CGFloat = 15
    static let marker: CGFloat = 22      // 점·체크박스 자리
    static let level: CGFloat = 18       // 목록 한 단계
    static let quote: CGFloat = 14       // 인용 한 겹
    static let hidden = NSFont.systemFont(ofSize: 0.01)
    static func body(_ traits: NSFontDescriptor.SymbolicTraits = []) -> NSFont {
        let f = NSFont.systemFont(ofSize: fontSize)
        return traits.isEmpty ? f : NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: fontSize) ?? f
    }
    static func heading(_ level: Int) -> NSFont { .systemFont(ofSize: [22, 19, 17][min(level, 3) - 1], weight: .bold) }
}

final class MarkupLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, used, _, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.location < storage.length,
                  let info = storage.attribute(.stickyLine, at: charRange.location, effectiveRange: nil) as? LineInfo else { return }
            let l = info.line
            let para = text.paragraphRange(for: NSRange(location: charRange.location, length: 0))
            let isFirst = para.location == charRange.location
            let y = origin.y + rect.minY
            // 인용 막대는 문단의 모든 줄에
            for q in 0..<l.quoteDepth {
                NSColor.tertiaryLabelColor.setFill()
                NSRect(x: origin.x + rect.minX + CGFloat(q) * Metrics.quote + 5, y: y, width: 3, height: rect.height).fill()
            }
            guard isFirst else { return }
            let contentX = origin.x + used.minX
            let box = NSRect(x: contentX - Metrics.marker + 3, y: y + (rect.height - 14) / 2, width: 14, height: 14)
            switch l.kind {
            case .bullet:
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: box.midX - 2.5, y: box.midY - 2.5, width: 5, height: 5)).fill()
            case .ordered(let n):
                let s = NSAttributedString(string: "\(n).", attributes: [.font: Metrics.body(), .foregroundColor: NSColor.secondaryLabelColor])
                s.draw(at: NSPoint(x: contentX - s.size().width - 4, y: y + (rect.height - s.size().height) / 2))
            case .checkbox(let checked):
                let p = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                if checked {
                    NSColor.controlAccentColor.setFill()
                    p.fill()
                    let c = NSBezierPath()
                    c.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
                    c.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 4))
                    c.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + 4))
                    c.lineWidth = 1.8
                    c.lineCapStyle = .round
                    NSColor.white.setStroke()
                    c.stroke()
                } else {
                    NSColor.secondaryLabelColor.setStroke()
                    p.lineWidth = 1.2
                    p.stroke()
                }
            case .rule:
                NSColor.tertiaryLabelColor.setFill()
                NSRect(x: origin.x + rect.minX + 4, y: y + rect.height / 2, width: rect.width - 8, height: 1).fill()
            default: break
            }
        }
    }
}

final class MarkupTextView: NSTextView, NSTextStorageDelegate {
    var onChange: (() -> Void)?

    static func make(frame: NSRect) -> MarkupTextView {
        let storage = NSTextStorage()
        let lm = MarkupLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        let tv = MarkupTextView(frame: frame, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Metrics.body()
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.typingAttributes = [.font: Metrics.body(), .foregroundColor: NSColor.labelColor]
        storage.delegate = tv
        return tv
    }

    /// 다른 쪽(메인 창, 다른 앱)과 마지막으로 같았던 본문. 병합의 기준이다
    private(set) var base = ""
    /// 조합 중에 들어와 미뤄 둔 다른 쪽 본문
    private var pendingExternal: String?

    /// 다른 쪽에서 본문이 바뀌었다. 내 입력과 줄 단위로 합쳐 반영한다 (F-07).
    /// 한글 조합 중이면 미룬다: 조합 중에 글자를 바꾸면 조합이 끊긴다 (NFR-20, F-07 R-4).
    func applyExternal(_ theirs: String) {
        if hasMarkedText() {
            pendingExternal = theirs
            return
        }
        pendingExternal = nil
        let mine = string
        let merged = mergeBodies(base: base, mine: mine, theirs: theirs)
        base = merged
        guard merged != mine, let storage = textStorage else { return }
        // 바뀐 가운데 부분만 바꿔 커서와 스크롤을 지킨다
        let a = Array(mine.utf16), b = Array(merged.utf16)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let old = NSRange(location: pre, length: a.count - pre - suf)
        let new = String(utf16CodeUnits: Array(b[pre..<(b.count - suf)]), count: b.count - pre - suf)
        var sel = selectedRange()
        storage.replaceCharacters(in: old, with: new)
        if sel.location >= NSMaxRange(old) { sel.location += (new as NSString).length - old.length }
        else if sel.location > old.location { sel.location = old.location + (new as NSString).length }
        restyleDirty()
        setSelectedRange(NSRange(location: min(sel.location, storage.length), length: 0))
    }

    /// 저장했다: 지금 본문이 다른 쪽과 같은 상태가 됐다
    func markSynced() { base = string }

    /// 본문을 통째로 바꾼다(열기)
    func load(_ markdown: String) {
        base = markdown
        textStorage?.replaceCharacters(in: NSRange(location: 0, length: textStorage?.length ?? 0), with: markdown)
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
        dirty = nil
    }

    // MARK: 꾸미기

    /// 고친 범위. 편집이 끝난 뒤(didChangeText) 한 번에 꾸민다.
    /// 편집 처리 도중에 속성을 바꾸면 NSTextView가 커서를 문단 끝으로 옮긴다(스파이크에서 확인).
    private var dirty: NSRange?

    func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        if var d = dirty {
            // 앞서 기록한 범위를 이번 변경만큼 민다
            if d.location > editedRange.location { d.location = max(editedRange.location, d.location + delta) }
            dirty = NSUnionRange(d, editedRange)
        } else {
            dirty = editedRange
        }
    }

    private func restyleDirty() {
        // 한글 조합 중에는 꾸밈을 건드리지 않는다. 조합이 끝나면 다시 들어온다 (NFR-20)
        guard !hasMarkedText(), let d = dirty, let storage = textStorage else { return }
        dirty = nil
        let len = storage.length
        let loc = min(d.location, len)
        restyle(NSRange(location: loc, length: min(d.length, len - loc)))
    }

    func restyle(_ range: NSRange) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let paras = text.paragraphRange(for: range)
        var loc = paras.location
        while loc < NSMaxRange(paras) || (loc == paras.location && paras.length == 0) {
            let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
            style(paragraph: para, in: storage)
            if para.length == 0 { break }
            loc = NSMaxRange(para)
        }
    }

    private func style(paragraph para: NSRange, in storage: NSTextStorage) {
        let text = storage.string as NSString
        var lineRange = para
        while lineRange.length > 0, let c = Unicode.Scalar(text.character(at: NSMaxRange(lineRange) - 1)), c == "\n" || c == "\r" {
            lineRange.length -= 1
        }
        let line = text.substring(with: lineRange)
        let l = stickyLine(line)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 2
        var indent = CGFloat(l.quoteDepth) * Metrics.quote
        var font = Metrics.body()
        var color = NSColor.labelColor
        switch l.kind {
        case .bullet, .ordered, .checkbox:
            indent += CGFloat(l.depth) * Metrics.level + Metrics.marker
            if case .checkbox(true) = l.kind { color = .secondaryLabelColor }
        case .heading(let level):
            font = Metrics.heading(level)
            ps.paragraphSpacingBefore = 4
        case .rule, .blank:
            ps.minimumLineHeight = 18
        case .paragraph: break
        }
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent
        storage.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: ps, .stickyLine: LineInfo(l)], range: para)
        if case .checkbox(true) = l.kind, lineRange.length > l.contentStart {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: NSRange(location: lineRange.location + l.contentStart, length: lineRange.length - l.contentStart))
        }
        func hide(_ r: Range<Int>) {
            guard !r.isEmpty else { return }
            storage.addAttributes([.font: Metrics.hidden, .foregroundColor: NSColor.clear],
                                  range: NSRange(location: lineRange.location + r.lowerBound, length: r.count))
        }
        hide(0..<min(l.contentStart, lineRange.length))
        for span in stickyInlines(line, from: l.contentStart) {
            let r = NSRange(location: lineRange.location + span.range.lowerBound, length: span.range.count)
            switch span.kind {
            case .marker: hide(span.range)
            case .bold:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: r)
            case .italic:
                storage.addAttribute(.obliqueness, value: 0.18, range: r)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: Metrics.fontSize - 1, weight: .regular),
                                       .backgroundColor: NSColor.black.withAlphaComponent(0.07)], range: r)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            }
        }
    }

    // MARK: 편집

    /// 커서가 있는 줄: (줄 글자, 줄 시작 위치, 줄 안 커서)
    private func currentLine() -> (String, Int, Int)? {
        let sel = selectedRange()
        guard sel.length == 0, !hasMarkedText() else { return nil }
        let text = string as NSString
        var r = text.paragraphRange(for: NSRange(location: sel.location, length: 0))
        while r.length > 0, let c = Unicode.Scalar(text.character(at: NSMaxRange(r) - 1)), c == "\n" || c == "\r" { r.length -= 1 }
        guard sel.location <= NSMaxRange(r) else { return nil }
        return (text.substring(with: r), r.location, sel.location - r.location)
    }

    @discardableResult
    private func apply(_ e: StickyEdit?, lineStart: Int) -> Bool {
        guard let e else { return false }
        let r = NSRange(location: lineStart + e.range.lowerBound, length: e.range.count)
        guard shouldChangeText(in: r, replacementString: e.text) else { return false }
        textStorage?.replaceCharacters(in: r, with: e.text)
        didChangeText()
        setSelectedRange(NSRange(location: lineStart + e.cursor, length: 0))
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if let (line, start, cursor) = currentLine(), apply(stickyNewline(line, cursor: cursor), lineStart: start) { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if let (line, start, cursor) = currentLine(), apply(stickyIndent(line, cursor: cursor, deeper: true), lineStart: start) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let (line, start, cursor) = currentLine() { apply(stickyIndent(line, cursor: cursor, deeper: false), lineStart: start) }
    }

    override func deleteBackward(_ sender: Any?) {
        if let (line, start, cursor) = currentLine(), apply(stickyBackspaceAtContentStart(line, cursor: cursor), lineStart: start) { return }
        super.deleteBackward(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if let (line, start, cursor) = currentLine() { apply(stickyShortcut(line, cursor: cursor), lineStart: start) }
    }

    override func didChangeText() {
        super.didChangeText()
        restyleDirty()
        if !hasMarkedText() {
            if let p = pendingExternal { applyExternal(p) }
            onChange?()
        }
    }

    /// 체크박스 자리를 누르면 토글한다. 눌렀으면 true
    @discardableResult
    func toggleCheck(atCharacter index: Int) -> Bool {
        let text = string as NSString
        guard index <= text.length else { return false }
        var r = text.paragraphRange(for: NSRange(location: index, length: 0))
        while r.length > 0, let c = Unicode.Scalar(text.character(at: NSMaxRange(r) - 1)), c == "\n" || c == "\r" { r.length -= 1 }
        let sel = selectedRange()
        guard apply(stickyToggleCheck(text.substring(with: r)), lineStart: r.location) else { return false }
        setSelectedRange(sel)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let lm = layoutManager, let tc = textContainer else { return super.mouseDown(with: event) }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        let glyph = lm.glyphIndex(for: p, in: tc)
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let index = lm.characterIndexForGlyph(at: glyph)
        if p.y >= used.minY, p.y <= used.maxY, p.x >= used.minX - Metrics.marker, p.x < used.minX,
           let info = textStorage?.attribute(.stickyLine, at: min(index, max(0, (textStorage?.length ?? 1) - 1)), effectiveRange: nil) as? LineInfo,
           case .checkbox = info.line.kind, toggleCheck(atCharacter: index) {
            return
        }
        super.mouseDown(with: event)
    }
}
