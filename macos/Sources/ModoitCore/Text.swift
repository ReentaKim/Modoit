import Foundation

// Rust 코드는 `char`(유니코드 스칼라)와 바이트 단위로 글자를 다룬다. Swift의 `Character`는
// "\r\n"이나 결합 문자를 한 글자로 묶고, `String ==`는 NFC/NFD를 같다고 본다.
// 규칙이 달라지지 않도록 코어의 글자 처리는 스칼라 배열과 UTF-8 바이트로 한다.

typealias Scalars = ArraySlice<Unicode.Scalar>

extension Unicode.Scalar {
    /// Rust `char::is_whitespace`
    var isWS: Bool { properties.isWhitespace }
    /// Rust `char::is_alphanumeric`
    var isAlnum: Bool {
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
    /// Rust `char::is_ascii_punctuation`
    var isASCIIPunct: Bool {
        switch value {
        case 33...47, 58...64, 91...96, 123...126: return true
        default: return false
        }
    }
    var isASCIIDigit: Bool { (48...57).contains(value) }
    var isASCIIAlpha: Bool { (65...90).contains(value) || (97...122).contains(value) }
}

extension String {
    var scalars: Scalars { ArraySlice(unicodeScalars) }

    init(_ s: Scalars) {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        self.init(v)
    }

    /// 바이트가 같은가. `==`와 달리 NFC와 NFD를 다르게 본다 (Rust `str ==`)
    public func sameBytes(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }

    /// Rust `str::starts_with` (바이트 접두사)
    public func bytesHasPrefix(_ p: String) -> Bool { utf8.starts(with: p.utf8) }

    /// 앞에서 바이트 n개를 뗀 나머지. n은 글자 경계여야 한다
    public func droppingBytes(_ n: Int) -> String { String(decoding: utf8.dropFirst(n), as: UTF8.self) }

    /// "/"로 나눈다. 빈 조각은 버린다
    var pathSegments: [String] {
        utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }
}

extension ArraySlice where Element == Unicode.Scalar {
    func trimmedStart() -> Scalars { drop(while: \.isWS) }
    func trimmedEnd() -> Scalars {
        var s = self
        while let l = s.last, l.isWS { s = s.dropLast() }
        return s
    }
    func trimmed() -> Scalars { trimmedStart().trimmedEnd() }

    func hasPrefix(_ p: String) -> Bool { starts(with: p.unicodeScalars) }

    func stripPrefix(_ p: String) -> Scalars? {
        hasPrefix(p) ? dropFirst(p.unicodeScalars.count) : nil
    }

    /// Rust `str::lines`: "\n"으로 나누고 줄 끝 "\r"을 뗀다. 마지막 빈 줄은 없다
    func lines() -> [Scalars] {
        var out: [Scalars] = []
        var start = startIndex
        for i in indices where self[i] == "\n" {
            out.append(self[start..<i])
            start = i + 1
        }
        if start < endIndex { out.append(self[start..<endIndex]) }
        return out.map { $0.last == "\r" ? $0.dropLast() : $0 }
    }

    /// Rust `str::split_inclusive('\n')`: 줄바꿈을 포함한 줄들
    func linesInclusive() -> [Scalars] {
        var out: [Scalars] = []
        var start = startIndex
        for i in indices where self[i] == "\n" {
            out.append(self[start...i])
            start = i + 1
        }
        if start < endIndex { out.append(self[start..<endIndex]) }
        return out
    }

    func firstRange(of needle: String) -> Range<Int>? {
        let n = Array(needle.unicodeScalars)
        guard !n.isEmpty, count >= n.count else { return nil }
        var i = startIndex
        while i + n.count <= endIndex {
            if self[i] == n[0], self[i..<(i + n.count)].elementsEqual(n) { return i..<(i + n.count) }
            i += 1
        }
        return nil
    }
}
