import Foundation

enum DeadlineGroup: String, CaseIterable, Identifiable {
    case overdue = "기한 경과"
    case today = "오늘"
    case week = "7일 이내"
    case later = "이후"
    case undated = "기한 없음"
    case unconfirmed = "기한 미확인"

    var id: Self { self }

    static func classify(_ dueAt: Date?, now: Date, calendar: Calendar = .current, unconfirmed: Bool = false) -> Self {
        guard let dueAt else { return unconfirmed ? .unconfirmed : .undated }
        if dueAt <= now { return .overdue }
        if calendar.isDate(dueAt, inSameDayAs: now) { return .today }
        guard let limit = calendar.date(byAdding: .day, value: 7, to: now) else { return .later }
        return dueAt <= limit ? .week : .later
    }
}

enum DeadlineCountdown: Equatable {
    case overdue
    case underMinute
    case remaining(minutes: Int)

    init(due: Date, now: Date) {
        let interval = due.timeIntervalSince(now)
        if interval <= 0 { self = .overdue }
        else if interval < 60 { self = .underMinute }
        else { self = .remaining(minutes: Int(interval / 60)) }
    }

    static func duration(minutes: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(minutes) * 60) ?? minutes.formatted(.number.locale(locale))
    }
}

struct CalendarMonth {
    let days: [Date]
    let leadingDays: Int
    let markedDays: Set<Date>

    init(date: Date, events: [CalixEvent], calendar: Calendar = .current) {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let count = calendar.range(of: .day, in: .month, for: date)?.count ?? 1
        days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start).map(calendar.startOfDay(for:)) }
        leadingDays = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let last = days.last ?? start
        var marked = Set<Date>()
        for event in events {
            guard let due = event.due else { continue }
            let end = min(calendar.startOfDay(for: due), last)
            var day = max(event.starts.map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: due), start)
            while day <= end {
                marked.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = calendar.startOfDay(for: next)
            }
        }
        markedDays = marked
    }
}

struct TimetableGridLayout {
    static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    struct Slot: Identifiable {
        let lesson: CalixLesson
        let lane: Int
        var lanes: Int
        var id: UUID { lesson.id }
    }

    let days: [Int]
    let start: Int
    let end: Int
    let slots: [Int: [Slot]]

    init(lessons: [CalixLesson], offDays: Set<Int>) {
        let timed = lessons.filter { !$0.online && (1...7).contains($0.weekday) &&
            $0.start >= 0 && $0.end <= 1440 && $0.start < $0.end }
        days = timed.contains { $0.weekday == 7 || $0.weekday == 1 } || !offDays.isDisjoint(with: [7, 1])
            ? Self.weekdays : Array(Self.weekdays.prefix(5))
        let visible = timed.filter { !offDays.contains($0.weekday) }
        start = min(8 * 60, (visible.map(\.start).min() ?? 8 * 60) / 60 * 60)
        end = max(19 * 60, ((visible.map(\.end).max() ?? 19 * 60) + 59) / 60 * 60)
        slots = Dictionary(grouping: visible, by: \.weekday).mapValues(Self.place)
    }

    private static func place(_ lessons: [CalixLesson]) -> [Slot] {
        var slots: [Slot] = []
        var laneEnds: [Int] = []
        var groupStart = 0
        for lesson in lessons.sorted(by: { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }) {
            if !laneEnds.isEmpty, laneEnds.allSatisfy({ $0 <= lesson.start }) {
                for index in groupStart..<slots.count { slots[index].lanes = laneEnds.count }
                laneEnds.removeAll(keepingCapacity: true)
                groupStart = slots.count
            }
            let lane = laneEnds.firstIndex { $0 <= lesson.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(lesson.end) }
            else { laneEnds[lane] = lesson.end }
            slots.append(Slot(lesson: lesson, lane: lane, lanes: 1))
        }
        for index in groupStart..<slots.count { slots[index].lanes = laneEnds.count }
        return slots
    }
}
