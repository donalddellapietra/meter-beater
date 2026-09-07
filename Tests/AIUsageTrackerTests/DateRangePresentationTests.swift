import Foundation
import Testing
import UsageCore
@testable import AIUsageTracker

private func testCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.firstWeekday = 1
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 14))!
}

@Test("Date presets use full, unambiguous labels in both languages")
func fullDatePresetLabels() {
    let copy = AppCopy(language: .english)
    let calendar = testCalendar()
    #expect(copy.dateRangeLabel(.lastHours(24)) == "Last 24 hours")
    #expect(copy.dateRangeLabel(.lastDays(7)) == "Last 7 days")
    #expect(copy.dateRangeLabel(.lastDays(30)) == "Last 30 days")
    #expect(copy.dateRangeLabel(.currentWeek(startWeekday: 1), calendar: calendar) == "This week")
    #expect(copy.dateRangeLabel(.currentMonth(startDay: 1)) == "This month")
    #expect(copy.dateRangeLabel(.yearToDate) == "This year")
    let chinese = AppCopy(language: .simplifiedChinese)
    #expect(chinese.dateRangeLabel(.lastDays(7)) == "近 7 天")
    #expect(chinese.dateRangeLabel(.lastDays(30)) == "近 30 天")
    #expect(chinese.dateRangeLabel(.yearToDate) == "今年")
}

@Test("Custom renewal dates are labeled as cycles, not calendar periods")
func customCycleLabels() {
    let copy = AppCopy(language: .english)
    var calendar = testCalendar()
    #expect(copy.dateRangeLabel(.currentWeek(startWeekday: 2), calendar: calendar) == "Weekly cycle")
    calendar.firstWeekday = 2
    #expect(copy.dateRangeLabel(.currentWeek(startWeekday: 2), calendar: calendar) == "This week")
    #expect(copy.dateRangeLabel(.currentMonth(startDay: 15)) == "Monthly cycle")
    let chinese = AppCopy(language: .simplifiedChinese)
    #expect(chinese.dateRangeLabel(.currentMonth(startDay: 15)) == "每月周期")
}

@Test("Rolling and calendar presets show distinct timestamp boundaries")
func rollingAndCalendarDatesDiffer() throws {
    let copy = AppCopy(language: .english)
    let calendar = testCalendar()
    let now = date(2026, 9, 7, calendar: calendar)
    let rolling = UsageDateRange.lastDays(7)
    let week = UsageDateRange.currentWeek(startWeekday: 1)
    let month = UsageDateRange.currentMonth(startDay: 1)
    let rollingInterval = try #require(rolling.interval(now: now, calendar: calendar))
    #expect(rollingInterval.duration == 7 * 86_400)
    #expect(rollingInterval.end == now)
    #expect(calendar.component(.day, from: rollingInterval.start) == 31)
    #expect(calendar.component(.hour, from: rollingInterval.start) == 14)
    let weekInterval = try #require(week.interval(now: now, calendar: calendar))
    #expect(calendar.component(.day, from: weekInterval.start) == 6)
    #expect(copy.dateRangeDetail(rolling, now: now, calendar: calendar)
        != copy.dateRangeDetail(week, now: now, calendar: calendar))
    #expect(copy.dateRangeDetail(rolling, now: now, calendar: calendar)
        != copy.dateRangeDetail(month, now: now, calendar: calendar))
}

@Test("Cycle details end today rather than showing a future renewal")
func cycleDetailsStopToday() {
    let copy = AppCopy(language: .english)
    let calendar = testCalendar()
    let now = date(2026, 9, 7, calendar: calendar)
    let expected = UsageDateRange.custom(start: date(2026, 8, 15, calendar: calendar), end: now)
    #expect(copy.dateRangeDetail(.currentMonth(startDay: 15), now: now, calendar: calendar)
        == copy.dateRangeDetail(expected, now: now, calendar: calendar))
}

@Test("Today and all-time details do not imply a second independent filter")
func todayAndAllTimeDetails() {
    let copy = AppCopy(language: .english)
    let calendar = testCalendar()
    let now = date(2026, 9, 7, calendar: calendar)
    #expect(!copy.dateRangeDetail(.currentDay, now: now, calendar: calendar).contains(" – "))
    #expect(copy.dateRangeDetail(.allTime, now: now, calendar: calendar) == "All recorded usage")
}

@Test("Cross-year ranges include the year in their date labels")
func crossYearDetails() {
    let copy = AppCopy(language: .english)
    let calendar = testCalendar()
    let now = date(2026, 1, 2, calendar: calendar)
    let detail = copy.dateRangeDetail(.lastDays(7), now: now, calendar: calendar)
    #expect(detail.contains("2025"))
    #expect(detail.hasSuffix("Now"))
}

@Test("Last seven days remain an elapsed 168 hours over daylight saving")
func rollingDateDetailsAcrossDST() throws {
    let copy = AppCopy(language: .english)
    let calendar = testCalendar()
    let now = date(2026, 11, 2, calendar: calendar)
    let range = UsageDateRange.lastDays(7)
    let interval = try #require(range.interval(now: now, calendar: calendar))
    #expect(interval.duration == 168 * 60 * 60)
    let expected = UsageDateRange.custom(start: date(2026, 10, 27, calendar: calendar), end: now)
    #expect(copy.dateRangeDetail(range, now: now, calendar: calendar)
        != copy.dateRangeDetail(expected, now: now, calendar: calendar))
}

@Test("Rolling and Calendar modes contain only their own presets")
func dateRangeModeMembership() {
    let rolling = DateRangeMode.rolling.presets(weekStart: 1, monthStart: 1)
    let calendar = DateRangeMode.calendar.presets(weekStart: 1, monthStart: 1)
    #expect(rolling == [.lastHours(24), .lastDays(7), .lastDays(30)])
    #expect(calendar == [.currentDay, .currentWeek(startWeekday: 1), .currentMonth(startDay: 1), .yearToDate])
    #expect(Set(rolling).isDisjoint(with: Set(calendar)))
    #expect(!rolling.contains(.currentDay))
    #expect(!(rolling + calendar).contains(.allTime))
    for range in rolling { #expect(DateRangeMode(selection: range) == .rolling) }
    for range in calendar { #expect(DateRangeMode(selection: range) == .calendar) }
}
