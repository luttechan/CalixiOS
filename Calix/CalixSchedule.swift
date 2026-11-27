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
