import Foundation
import ModoitCore

// 메모 목록의 정렬과 묶음 (F-04 FR-05, FR-39, FR-47). 옮겨 온 곳: src/app/NoteList.tsx

public enum NoteSort: String, Sendable, CaseIterable {
    case modified, created, name
}

public struct NoteGroup: Equatable, Sendable, Identifiable {
    /// "즐겨찾기", "오늘", "어제", "지난 7일", "지난 30일", "2025년", "메모". 제목 없는 묶음은 ""
    public var title: String
    public var notes: [NoteMeta]
    public var id: String { title }
}

/// 빈 제목일 때 목록에 보이는 이름
public let emptyTitle = "새로운 메모"

public func displayTitle(_ n: NoteMeta) -> String { n.title.isEmpty ? emptyTitle : n.title }

/// 행의 날짜와 날짜 묶음은 정렬 기준 날짜를 따른다 (F-04 R-2)
public func sortDate(_ n: NoteMeta, _ sort: NoteSort) -> UInt64 { sort == .created ? n.created : n.modified }

private let day: UInt64 = 86_400_000

func dateGroup(_ ms: UInt64, today: UInt64, calendar: Calendar) -> String {
    if ms >= today { return "오늘" }
    if ms + day >= today { return "어제" }
    if ms + 7 * day >= today { return "지난 7일" }
    if ms + 30 * day >= today { return "지난 30일" }
    return "\(calendar.component(.year, from: Date(timeIntervalSince1970: Double(ms) / 1000)))년"
}

/// 즐겨찾기 묶음이 맨 위, 나머지는 날짜 묶음(이름순이면 묶음 없이)
public func groupNotes(_ notes: [NoteMeta], sort: NoteSort, now: Date = Date(), calendar: Calendar = .current) -> [NoteGroup] {
    let today = UInt64(max(0, calendar.startOfDay(for: now).timeIntervalSince1970 * 1000))
    let sorted = notes.sorted { a, b in
        if sort == .name {
            let (x, y) = (displayTitle(a), displayTitle(b))
            return x == y ? scalarLess(a.path, b.path) : nameOrder(x, y)
        }
        let (x, y) = (sortDate(a, sort), sortDate(b, sort))
        return x == y ? scalarLess(a.path, b.path) : x > y
    }
    let pinned = sorted.filter(\.pinned)
    var groups: [NoteGroup] = pinned.isEmpty ? [] : [NoteGroup(title: "즐겨찾기", notes: pinned)]
    for n in sorted where !n.pinned {
        let g = sort == .name ? (pinned.isEmpty ? "" : "메모") : dateGroup(sortDate(n, sort), today: today, calendar: calendar)
        if let last = groups.last, last.title == g, !(g == "즐겨찾기") {
            groups[groups.count - 1].notes.append(n)
        } else {
            groups.append(NoteGroup(title: g, notes: [n]))
        }
    }
    return groups
}

private func scalarLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}

/// 행에 보이는 짧은 날짜: 오늘이면 시각, 어제면 "어제", 그 밖에는 날짜
public func shortDate(_ ms: UInt64, now: Date = Date(), calendar: Calendar = .current) -> String {
    let today = UInt64(max(0, calendar.startOfDay(for: now).timeIntervalSince1970 * 1000))
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    if ms >= today {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "a h:mm"
        return f.string(from: d)
    }
    if ms + day >= today { return "어제" }
    let c = calendar.dateComponents([.year, .month, .day], from: d)
    return "\(c.year ?? 0). \(c.month ?? 0). \(c.day ?? 0)."
}

/// 사이드바에서 고른 범위 (F-04 R-1, R-7)
public enum NoteScope: Equatable, Sendable {
    case all
    /// 모든 폴더의 즐겨찾기
    case favorites
    /// 그 폴더 바로 안의 메모만
    case folder(String)
}

/// 범위와 검색어로 거른다. 검색 대상은 제목·미리보기·경로, 대소문자 무시 (F-09)
public func filterNotes(_ notes: [NoteMeta], scope: NoteScope, query: String = "") -> [NoteMeta] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return notes.filter { n in
        switch scope {
        case .all: break
        case .favorites: if !n.pinned { return false }
        case .folder(let f): if n.folder != f { return false }
        }
        if q.isEmpty { return true }
        return n.title.lowercased().contains(q) || n.preview.lowercased().contains(q) || n.path.lowercased().contains(q)
    }
}
