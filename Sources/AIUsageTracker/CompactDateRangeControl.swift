import SwiftUI
import UsageCore

struct CompactDateRangeControl: View {
    @Bindable var model: WoolModel
    let allowsAnimatedActivity: Bool
    @State private var isPresented = false

    private var selection: UsageDateRange { model.dateRange }
    private var isLoading: Bool { model.isDateQuerying }
    private var language: AppLanguage { model.appLanguage }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text(copy.dateRangeLabel(selection, calendar: localizedCalendar))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if isLoading && allowsAnimatedActivity {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(WoolPalette.charcoal.opacity(0.45))
                }
            }
            // The control always sits on the cream wool card, so its chrome is
            // fixed charcoal rather than scheme-adaptive primary.
            .foregroundStyle(WoolPalette.charcoal)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(WoolPalette.charcoal.opacity(0.07), in: Capsule())
        .overlay {
            Capsule().stroke(WoolPalette.charcoal.opacity(0.10), lineWidth: 1)
        }
        .accessibilityLabel(copy.dateRange)
        .accessibilityValue(copy.dateRangeLabel(selection, calendar: localizedCalendar))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            CompactDateRangePicker(model: model) { range in
                model.setDateRange(range)
                isPresented = false
            }
        }
    }

    private var copy: AppCopy { AppCopy(language: language) }

    private var localizedCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = language.locale
        // Assigning a locale resets firstWeekday; keep the user's setting.
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }
}

struct CompactDateRangePicker: View {
    @Bindable var model: WoolModel
    let onSelect: (UsageDateRange) -> Void

    @State private var draftStart: Date?
    @State private var draftEnd: Date?
    @State private var visibleMonth: Date
    @State private var showsCustomCalendar: Bool

    private let selection: UsageDateRange
    private let language: AppLanguage
    private let calendar: Calendar
    private let today: Date
    private let columns = Array(repeating: GridItem(.flexible(minimum: 34), spacing: 3), count: 7)

    init(model: WoolModel, onSelect: @escaping (UsageDateRange) -> Void) {
        self.model = model
        self.onSelect = onSelect
        let selection = model.dateRange
        self.selection = selection
        self.language = model.appLanguage

        var calendar = Calendar.current
        calendar.locale = model.appLanguage.locale
        // Assigning a locale resets firstWeekday; keep the user's setting.
        calendar.firstWeekday = Calendar.current.firstWeekday
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        self.today = today

        let interval = selection.interval(now: today, calendar: calendar)
        let start = interval?.start
        let end = interval.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
        _draftStart = State(initialValue: start)
        _draftEnd = State(initialValue: end)
        _visibleMonth = State(initialValue: Self.monthStart(end ?? today, calendar: calendar))
        if case .custom = selection {
            _showsCustomCalendar = State(initialValue: true)
        } else {
            _showsCustomCalendar = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(spacing: 13) {
            pickerHeader
            cycleRow
            cycleStartConfig
            presetRow
            Divider()
            if showsCustomCalendar {
                calendarHeader
                calendarGrid
                Divider()
                selectionFooter
            } else {
                customRangeButton
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(.regularMaterial)
    }

    private var pickerHeader: some View {
        HStack {
            Text(copy.dateRange)
                .font(.headline)
            Spacer()
        }
    }

    /// Rolling windows: today, the current week/month cycle, and everything.
    /// The cycles renew on the configured start day, like a subscription.
    private var cycleRow: some View {
        HStack(spacing: 6) {
            preset(copy.today, .currentDay)
            preset(copy.thisWeek, .currentWeek(startWeekday: model.cycleWeekStart))
            preset(copy.thisMonth, .currentMonth(startDay: model.cycleMonthStart))
            preset(copy.allTime, .allTime)
        }
    }

    /// Shown only while a cycle preset is active: which day the cycle renews.
    @ViewBuilder
    private var cycleStartConfig: some View {
        switch selection {
        case .currentWeek:
            cycleStartPicker(
                selectionBinding: Binding(
                    get: { model.cycleWeekStart },
                    set: { model.setCycleWeekStart($0) }
                ),
                values: Array(1...7),
                title: copy.weekdayTitle
            )
        case .currentMonth:
            cycleStartPicker(
                selectionBinding: Binding(
                    get: { model.cycleMonthStart },
                    set: { model.setCycleMonthStart($0) }
                ),
                values: Array(1...31),
                title: copy.monthDayTitle
            )
        default:
            EmptyView()
        }
    }

    private func cycleStartPicker(
        selectionBinding: Binding<Int>,
        values: [Int],
        title: @escaping (Int) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(copy.cycleStarts)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(copy.cycleStarts, selection: selectionBinding) {
                ForEach(values, id: \.self) { value in
                    Text(title(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            preset(copy.short7Days, .lastDays(7))
            preset(copy.short30Days, .lastDays(30))
            preset(copy.yearToDate, .yearToDate)
        }
    }

    private var customRangeButton: some View {
        Button {
            showsCustomCalendar = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(copy.customRange)…")
                    .font(.caption.weight(.medium))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func preset(_ title: String, _ range: UsageDateRange) -> some View {
        let isSelected = selection == range
        return Button {
            onSelect(range)
        } label: {
            Text(title)
                .font(.caption2.weight(isSelected ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            isSelected ? WoolPalette.dateAccent : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityValue(isSelected ? copy.selected : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var calendarHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityLabel(copy.previousMonth)

            Spacer()

            Text(monthTitle)
                .font(.subheadline.weight(.semibold))

            Spacer()

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .disabled(!canAdvance)
            .accessibilityLabel(copy.nextMonth)
        }
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: 18)
            }

            ForEach(0..<leadingBlankCount, id: \.self) { _ in
                Color.clear.frame(height: 34)
            }

            ForEach(days, id: \.self) { date in
                dayButton(date)
            }
        }
        .frame(height: calendarGridHeight, alignment: .top)
    }

    private func dayButton(_ date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let isStart = draftStart.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isEnd = draftEnd.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isEndpoint = isStart || isEnd
        let isInside = draftStart.map { day >= calendar.startOfDay(for: $0) } == true
            && draftEnd.map { day <= calendar.startOfDay(for: $0) } == true
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isFuture = day > today

        return Button {
            selectDay(day)
        } label: {
            ZStack {
                if isInside {
                    RoundedRectangle(cornerRadius: isEndpoint ? 9 : 5, style: .continuous)
                        .fill(isEndpoint ? WoolPalette.dateAccent : WoolPalette.dateAccent.opacity(0.13))
                } else if isToday {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(WoolPalette.dateAccent.opacity(0.55), lineWidth: 1)
                }

                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 11, weight: isEndpoint || isToday ? .semibold : .regular))
                    .foregroundStyle(isEndpoint ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .opacity(isFuture ? 0.24 : 1)
        .accessibilityLabel(copy.fullDate(day))
        .accessibilityValue(isEndpoint ? copy.selected : "")
        .accessibilityAddTraits(isEndpoint ? .isSelected : [])
    }

    private var selectionFooter: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.customRange)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(draftLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)

            Button(copy.clear) {
                draftStart = nil
                draftEnd = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(draftStart == nil && draftEnd == nil)

            Button(copy.apply) {
                guard let draftStart, let draftEnd else { return }
                onSelect(.custom(start: draftStart, end: draftEnd))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(WoolPalette.dateAccent)
            .disabled(draftStart == nil || draftEnd == nil)
        }
    }

    private var copy: AppCopy { AppCopy(language: language) }

    private var monthTitle: String {
        visibleMonth.formatted(
            Date.FormatStyle()
                .month(.wide)
                .year()
                .locale(language.locale)
        )
    }

    private var draftLabel: String {
        guard let draftStart else { return copy.chooseStartDate }
        guard let draftEnd else { return "\(copy.shortDate(draftStart)) · \(copy.chooseEndDate)" }
        return copy.dateRangeLabel(
            .custom(start: draftStart, end: draftEnd),
            calendar: calendar
        )
    }

    private var canAdvance: Bool {
        visibleMonth < Self.monthStart(today, calendar: calendar)
    }

    private var days: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        return range.compactMap { day in
            calendar.date(bySetting: .day, value: day, of: visibleMonth)
        }
    }

    private var leadingBlankCount: Int {
        let weekday = calendar.component(.weekday, from: visibleMonth)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private var calendarGridHeight: CGFloat {
        let rows = (leadingBlankCount + days.count + 6) / 7
        let weekdayHeight: CGFloat = 18
        let rowHeight: CGFloat = 34
        let spacing: CGFloat = 3
        return weekdayHeight + spacing + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * spacing
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func shiftMonth(_ offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: visibleMonth) else { return }
        visibleMonth = min(next, Self.monthStart(today, calendar: calendar))
    }

    private func selectDay(_ day: Date) {
        if draftStart == nil || draftEnd != nil {
            draftStart = day
            draftEnd = nil
        } else if let draftStart, day < draftStart {
            self.draftStart = day
            draftEnd = nil
        } else {
            draftEnd = day
        }
    }

    private static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            ?? calendar.startOfDay(for: date)
    }
}

#if DEBUG
struct DateRangeCaptureView: View {
    let model: WoolModel

    var body: some View {
        CompactDateRangePicker(model: model) { _ in }
    }
}
#endif
