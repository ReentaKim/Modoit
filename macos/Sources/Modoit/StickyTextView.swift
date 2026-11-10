import AppKit
import ModoitCore

// 네이티브 스티키 화면 (F-08 FR-51, 아키텍처 V2-10·V2-11). 스파이크 spike/sticky-editor에서 옮겼다.
// Markdown 원문을 그대로 담은 NSTextView. 글자는 바꾸지 않고 속성만 입혀 꾸민다.
// 보기 전용이다. 체크박스만 눌러 바꿀 수 있고 편집은 메인 창에서 한다 (D-25).
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

/// 스티키는 다크 모드에서도 밝은 종이다. 글자색은 고정한다 (v0.x sticky.css)
enum StickyInk {
    static var text: NSColor { NSColor(srgbRed: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255, alpha: 1) }
    static var soft: NSColor { .black.withAlphaComponent(0.4) }
    static var faint: NSColor { .black.withAlphaComponent(0.25) }
}

/// 크기와 글꼴. 메인 편집기의 스티키용 스타일(src/editor/editor.css `.compact`)과 같은 값이다 (F-08 R-6)
enum Metrics {
    /// 설정의 글자 크기와 글꼴 (F-10). 메인 스레드에서만 읽고 쓴다(그리기도 메인 스레드다)
    nonisolated(unsafe) static var base: CGFloat = 17
    nonisolated(unsafe) static var family = "system"
    nonisolated(unsafe) static var custom = ""

    static func use(_ p: Prefs) {
        base = CGFloat(p.fontSize)
        family = p.fontFamily
        custom = p.customFont.trimmingCharacters(in: .whitespaces)
    }

    static var fontSize: CGFloat { base - 1 }
    static let check: CGFloat = 18       // 체크박스 지름
    static let marker: CGFloat = 26      // 점·체크박스 자리(체크박스 + 간격 8)
    static let level: CGFloat = 24       // 목록 한 단계
    static let quote: CGFloat = 15       // 인용 한 겹
    static var hidden: NSFont { .systemFont(ofSize: 0.01) }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let name: String? = switch family {
        case "serif": "AppleMyungjo"
        case "pretendard": "Pretendard Variable"
        case "custom": custom.isEmpty ? nil : custom
        case "mono": nil
        default: nil
        }
        if family == "mono" { return .monospacedSystemFont(ofSize: size, weight: weight) }
        guard let name, let f = NSFont(name: name, size: size) else { return system }
        return weight == .regular ? f : NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
    }
    static func body() -> NSFont { font(fontSize) }
    static func heading(_ level: Int) -> NSFont {
        let l = min(max(level, 1), 3)
        return font(base + [9, 4, 1][l - 1], l == 3 ? .semibold : .bold)
    }
    /// 줄 높이는 글자 크기의 1.5배
    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.pointSize * 1.5) }
}

final class MarkupLayoutManager: NSLayoutManager {
    /// 체크 표시 색(스티키 색에 맞춘다)
    var accent: NSColor?

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
                (self.accent ?? StickyInk.faint).setFill()
                NSRect(x: origin.x + rect.minX + CGFloat(q) * Metrics.quote + 5, y: y, width: 3, height: rect.height).fill()
            }
            guard isFirst else { return }
            // used.minX는 줄 여백(5)을 뺀 값이다. 글자가 실제로 시작하는 곳에 맞춘다
            let contentX = origin.x + used.minX + (self.textContainers.first?.lineFragmentPadding ?? 0)
            let d = Metrics.check
            let box = NSRect(x: contentX - Metrics.marker, y: y + (rect.height - d) / 2, width: d, height: d)
            switch l.kind {
            case .bullet:
                StickyInk.soft.setFill()
                NSBezierPath(ovalIn: NSRect(x: box.midX - 2.5, y: box.midY - 2.5, width: 5, height: 5)).fill()
            case .ordered(let n):
                let s = NSAttributedString(string: "\(n).", attributes: [.font: Metrics.body(), .foregroundColor: StickyInk.soft])
                s.draw(at: NSPoint(x: contentX - s.size().width - 4, y: y + (rect.height - s.size().height) / 2))
            case .checkbox(let checked):
                // 메인 편집기와 같은 둥근 체크박스
                if checked {
                    let p = NSBezierPath(ovalIn: box)
                    (self.accent ?? StickyInk.text).setFill()
                    p.fill()
                    let c = NSBezierPath()
                    c.move(to: NSPoint(x: box.minX + 5, y: box.midY + 0.5))
                    c.line(to: NSPoint(x: box.minX + 8, y: box.maxY - 5.5))
                    c.line(to: NSPoint(x: box.maxX - 5, y: box.minY + 5.5))
                    c.lineWidth = 2
                    c.lineCapStyle = .round
                    NSColor.white.setStroke()
                    c.stroke()
                } else {
                    let p = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
                    NSColor.black.withAlphaComponent(0.35).setStroke()
                    p.lineWidth = 1.5
                    p.stroke()
                }
            case .rule:
                StickyInk.faint.setFill()
                NSRect(x: origin.x + rect.minX + 4, y: y + rect.height / 2, width: rect.width - 8, height: 1).fill()
            default: break
            }
        }
    }
}

final class MarkupTextView: NSTextView {
    /// 체크박스를 눌러 본문이 바뀌었다
    var onChange: (() -> Void)?
    /// 두 번 눌렀다
    var onOpen: (() -> Void)?
    /// 체크 표시·링크 색
    var accent: NSColor? {
        didSet {
            (layoutManager as? MarkupLayoutManager)?.accent = accent
            restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
        }
    }

    /// 글꼴 설정이 바뀌었다
    func refont() { restyle(NSRange(location: 0, length: textStorage?.length ?? 0)) }

    static func make(frame: NSRect) -> MarkupTextView {
        let storage = NSTextStorage()
        let lm = MarkupLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        let tv = MarkupTextView(frame: frame, textContainer: container)
        tv.isRichText = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = Metrics.body()
        tv.textContainerInset = NSSize(width: 11, height: 8)   // 줄 여백 5와 합쳐 좌우 16
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        return tv
    }

    /// 본문을 바꾼다(열기, 다른 쪽에서 고침). 바뀐 가운데 부분만 바꿔 스크롤 위치를 지킨다
    func show(_ markdown: String) {
        guard let storage = textStorage, markdown != string else { return }
        let a = Array(string.utf16), b = Array(markdown.utf16)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let new = String(utf16CodeUnits: Array(b[pre..<(b.count - suf)]), count: b.count - pre - suf)
        storage.replaceCharacters(in: NSRange(location: pre, length: a.count - pre - suf), with: new)
        restyle(NSRange(location: pre, length: (new as NSString).length))
        setSelectedRange(NSRange(location: min(selectedRange().location, storage.length), length: 0))
    }

    // MARK: 꾸미기

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
        var indent = CGFloat(l.quoteDepth) * Metrics.quote
        var font = Metrics.body()
        var color = StickyInk.text
        switch l.kind {
        case .bullet, .ordered, .checkbox:
            indent += CGFloat(l.depth) * Metrics.level + Metrics.marker
            if case .checkbox(true) = l.kind { color = StickyInk.soft }
        case .heading(let level):
            font = Metrics.heading(level)
            // 메인 편집기의 제목 위아래 여백 (editor.css h1~h3)
            ps.paragraphSpacingBefore = ceil(font.pointSize * 0.5)
            ps.paragraphSpacing = ceil(font.pointSize * 0.15)
        case .rule, .blank: break
        case .paragraph: break
        }
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent
        if l.quoteDepth > 0 { color = StickyInk.soft }
        // 기호만 있는 줄(`- [ ] `)도 한 줄 높이를 지킨다. 글자는 줄 가운데에 둔다
        // 빈 줄은 Markdown에서 문단을 나누는 표시일 뿐이다. 메인 편집기처럼 좁은 틈으로만 보인다.
        // 빈 줄을 일부러 남긴 것은 `&nbsp;` 줄(.blank)이라 한 줄 높이를 지킨다
        let isGap = lineRange.length == 0
        let lh = isGap ? 3 : Metrics.lineHeight(font)
        if isGap { font = Metrics.hidden }
        ps.minimumLineHeight = lh
        ps.maximumLineHeight = lh
        let lift = isGap ? 0 : (lh - (font.ascender - font.descender)) / 2
        storage.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: ps, .stickyLine: LineInfo(l),
                               .baselineOffset: lift], range: para)
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
                storage.addAttributes([.foregroundColor: (accent ?? NSColor.linkColor), .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            }
        }
    }

    // MARK: 누르기 (보기 전용: 체크박스만 바꿀 수 있다, D-25)

    /// 그 글자가 있는 줄의 체크박스를 토글한다. 한 글자만 바뀐다 (F-08 R-9). 바꿨으면 true
    @discardableResult
    func toggleCheck(atCharacter index: Int) -> Bool {
        let text = string as NSString
        guard index <= text.length, let storage = textStorage else { return false }
        var r = text.paragraphRange(for: NSRange(location: index, length: 0))
        while r.length > 0, let c = Unicode.Scalar(text.character(at: NSMaxRange(r) - 1)), c == "\n" || c == "\r" { r.length -= 1 }
        guard let e = stickyToggleCheck(text.substring(with: r)) else { return false }
        let at = NSRange(location: r.location + e.range.lowerBound, length: e.range.count)
        storage.replaceCharacters(in: at, with: e.text)
        restyle(at)
        onChange?()
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
        // 두 번 누르면 메인 창에서 그 메모를 연다(편집은 메인 창에서)
        if event.clickCount == 2 {
            onOpen?()
            return
        }
        super.mouseDown(with: event)
    }
}
