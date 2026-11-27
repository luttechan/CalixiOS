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
