import Foundation

/// Dashboard-level time windows. These are converted to half-open local-day
/// intervals before querying SQLite, so an inclusive end date remains stable
/// across daylight-saving transitions.
public enum UsageDateRange: Codable, Hashable, Sendable {
    case allTime
    case lastDays(Int)
    case yearToDate
    case custom(start: Date, end: Date)
    /// The current calendar day; the window rolls forward at midnight.
    case currentDay
    /// The current week of a cycle that renews on `startWeekday`
    /// (1 = Sunday … 7 = Saturday). Rolls forward when the next cycle starts.
    case currentWeek(startWeekday: Int)
    /// The current month of a billing cycle that renews on `startDay` of the
    /// month, clamped to short months. Rolls forward at the next renewal.
    case currentMonth(startDay: Int)

    public var isAllTime: Bool {
        if case .allTime = self { return true }
        return false
    }

    /// Billing-cycle and range math is pinned to the Gregorian calendar in the
    /// user's time zone, matching the index's Gregorian day keys. The system
    /// calendar (Buddhist, Islamic, …) only affects display formatting.
    public static var gregorianCurrent: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    public func interval(now: Date = Date(), calendar: Calendar = Self.gregorianCurrent) -> DateInterval? {
        switch self {
        case .allTime:
            return nil
        case let .lastDays(requestedDays):
            let endDay = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(max(1, requestedDays) - 1), to: endDay) ?? endDay
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? now
            return DateInterval(start: start, end: end)
        case .yearToDate:
            let today = calendar.startOfDay(for: now)
            let year = calendar.component(.year, from: today)
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            return DateInterval(start: start, end: end)
        case let .custom(first, second):
            let startDay = calendar.startOfDay(for: min(first, second))
            let endDay = calendar.startOfDay(for: max(first, second))
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: startDay, end: end)
        case .currentDay:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)
        case let .currentWeek(startWeekday):
            let start = Self.currentWeekStart(startWeekday: startWeekday, now: now, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
            return DateInterval(start: start, end: end)
        case let .currentMonth(startDay):
            let start = Self.currentMonthStart(startDay: startDay, now: now, calendar: calendar)
            let end = Self.nextMonthCycleStart(after: start, startDay: startDay, calendar: calendar)
            return DateInterval(start: start, end: end)
        }
    }

    /// Most recent day with the given weekday (1 = Sunday … 7 = Saturday) at
    /// or before `now`.
    public static func currentWeekStart(startWeekday: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let normalized = min(max(startWeekday, 1), 7)
        let weekday = calendar.component(.weekday, from: today)
        let daysBack = (weekday - normalized + 7) % 7
        return calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
    }

    /// Most recent renewal at or before `now` for a cycle that renews on
    /// `startDay` of the month. A renewal day past a month's end lands on that
    /// month's final day, matching subscription billing.
    public static func currentMonthStart(startDay: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let normalized = min(max(startDay, 1), 31)
        var components = calendar.dateComponents([.year, .month], from: today)
        if calendar.component(.day, from: today) < clampedDay(normalized, in: components, calendar: calendar),
           let previousMonth = calendar.date(byAdding: .month, value: -1, to: today) {
            components = calendar.dateComponents([.year, .month], from: previousMonth)
        }
        components.day = clampedDay(normalized, in: components, calendar: calendar)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? today
    }

    private static func nextMonthCycleStart(after start: Date, startDay: Int, calendar: Calendar) -> Date {
        let normalized = min(max(startDay, 1), 31)
        let anchor = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        var components = calendar.dateComponents([.year, .month], from: anchor)
        components.day = clampedDay(normalized, in: components, calendar: calendar)
        return calendar.date(from: components) ?? anchor
    }

    private static func clampedDay(_ day: Int, in components: DateComponents, calendar: Calendar) -> Int {
        var probe = components
        probe.day = 1
        guard let monthStart = calendar.date(from: probe),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else { return day }
        return min(day, range.count)
    }
}
