import AppKit
import SwiftUI
import UsageCore

struct WoolPanel: View {
    @Bindable var model: WoolModel
    var forceLoading = false
    @State private var breakdownProvider: Provider?
    @State private var spendEditorProvider: Provider?
    @State private var showsAchievement = false
    @State private var achievementClicks = 0
    @State private var shearBurst = 0
    @State private var confettiBurst = 0
    @State private var meterArmed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                hero
                servingCostRow
                providerList
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            footer
        }
        .frame(width: 388)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [WoolPalette.pastureNightHigh, WoolPalette.pastureNightLow]
                        : [WoolPalette.pastureHigh, WoolPalette.pastureLow],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(colorScheme == .dark ? 0.5 : 0.38)
            }
        }
        .onAppear {
            celebrateWoolMilestone()
            if !reduceMotion { shearBurst += 1 }
        }
        .task {
            guard !meterArmed else { return }
            guard !reduceMotion else {
                meterArmed = true
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.smooth(duration: 0.9)) { meterArmed = true }
        }
        .onChange(of: model.summary.apiUSD) { _, _ in celebrateWoolMilestone() }
        .onChange(of: model.isRefreshing) { _, isRefreshing in
            if isRefreshing, !reduceMotion { shearBurst += 1 }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            SheepFaceBadge(wiggleTrigger: shearBurst)
                .overlay { WoolPuffBurst(trigger: shearBurst) }

            Text(copy.appName)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .layoutPriority(1)

            Spacer()

            liveIndicator
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    private var liveIndicator: some View {
        HStack(spacing: 6) {
            if showsLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(WoolPalette.live)
                    .frame(width: 6, height: 6)
            }
            Text(showsLoading ? copy.shearing : copy.grazing)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(copy.apiRateHeading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WoolPalette.charcoal.opacity(0.7))
                Spacer(minLength: 4)
                CompactDateRangeControl(model: model)
            }

            meterDisplay

            HStack(spacing: 8) {
                valuePill(
                    WoolFormat.compactTokens(model.summary.usage.totalTokens),
                    label: copy.tokenLabel
                )
                Spacer(minLength: 4)
                tierBadge
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { WoolCard(cornerRadius: 20) }
        .overlay { WoolConfetti(trigger: confettiBurst) }
    }

    /// The fleece meter from the icon: green digits on a dark display, rolling
    /// from $0 to the value on every panel open.
    private var meterDisplay: some View {
        Text(meterArmed ? WoolFormat.heroValue(model.summary) : "$0")
            .font(.system(size: 34, weight: .bold, design: .monospaced))
            .foregroundStyle(WoolPalette.lcdGlow)
            .shadow(color: WoolPalette.lcdGlow.opacity(0.55), radius: 5)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText(value: model.summary.apiUSD))
            .animation(reduceMotion ? nil : .smooth(duration: 0.65), value: WoolFormat.heroValue(model.summary))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WoolPalette.lcdBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.5), lineWidth: 2)
                    }
            }
    }

    /// Multiplier chip plus wool-tier rank; clicking pops a Minecraft-style
    /// achievement toast for the current tier.
    @ViewBuilder
    private var tierBadge: some View {
        if let multiplier = woolMultiplier {
            let tier = WoolTier.tier(for: multiplier)
            let flavors = copy.tierFlavors(tier)
            Button {
                achievementClicks += 1
                showsAchievement = true
            } label: {
                HStack(spacing: 6) {
                    Text(WoolFormat.multiplier(multiplier))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(WoolPalette.lcdGlow)
                        .contentTransition(.numericText(value: multiplier))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: multiplier)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(WoolPalette.lcdBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(copy.tierName(tier))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WoolPalette.charcoal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(WoolPalette.charcoal.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(copy.tierHelp)
            .accessibilityLabel(copy.tierHelp)
            .accessibilityValue("\(WoolFormat.multiplier(multiplier)) \(copy.tierName(tier))")
            .popover(isPresented: $showsAchievement, arrowEdge: .bottom) {
                MinecraftAchievementToast(
                    heading: copy.achievementGet,
                    title: copy.tierName(tier),
                    flavor: flavors[achievementClicks % max(flavors.count, 1)]
                )
            }
        }
    }

    private func valuePill(_ value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(WoolPalette.charcoal)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: value)
            Text(label)
                .font(.caption2)
                .foregroundStyle(WoolPalette.charcoal.opacity(0.7))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(WoolPalette.charcoal.opacity(0.07), in: Capsule())
    }

    @ViewBuilder
    private var servingCostRow: some View {
        if let estimate = servingCostEstimate {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WoolPalette.burn)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                    .frame(width: 28, height: 28)
                    .background(WoolPalette.burn.opacity(0.12), in: Circle())

                Text(copy.servingCostTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WoolPalette.charcoal)

                Button {
                    openCostSettings()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WoolPalette.charcoal.opacity(0.62))
                .help(copy.servingCostHelp)
                .accessibilityLabel(copy.costEstimates)

                Spacer()

                Text("≈ \(WoolFormat.compactDollars(estimate.midpointUSD))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WoolPalette.burnGlow)
                    .contentTransition(.numericText(value: estimate.midpointUSD))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: estimate.midpointUSD)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WoolPalette.lcdBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { WoolCard() }
            .help(copy.servingCostHelp)
        }
    }

    @ViewBuilder
    private var providerList: some View {
        let rows = providerRows
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.provider) { index, row in
                    if index > 0 {
                        Divider()
                            .overlay(WoolPalette.charcoal.opacity(0.08))
                            .padding(.leading, 32)
                    }
                    providerRow(row)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .background { WoolCard() }
        } else if !model.hasLoadedSummary || model.summary.usage.totalTokens > 0 {
            HStack(spacing: 9) {
                ProgressView().controlSize(.mini)
                Text(model.hasLoadedSummary ? copy.pricingUsage : copy.readingLedger)
                    .font(.caption)
                    .foregroundStyle(WoolPalette.charcoal.opacity(0.72))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background { WoolCard() }
        } else {
            HStack(spacing: 9) {
                Text("🐑")
                    .font(.system(size: 13))
                Image(systemName: "zzz")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion)
                    .foregroundStyle(WoolPalette.charcoal.opacity(0.72))
                Text(copy.emptyState)
                    .font(.caption)
                    .foregroundStyle(WoolPalette.charcoal.opacity(0.72))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background { WoolCard() }
        }
    }

    private func providerRow(_ row: ProviderWool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.provider == .codex ? WoolPalette.codex : WoolPalette.claude)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(copy.providerTitle(row.provider))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(WoolPalette.charcoal)

                    Button {
                        breakdownProvider = breakdownProvider == row.provider ? nil : row.provider
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WoolPalette.charcoal.opacity(0.62))
                    .help(copy.showCostBreakdown(row.provider))
                    .accessibilityLabel(copy.showCostBreakdown(row.provider))
                    .popover(isPresented: breakdownBinding(for: row.provider), arrowEdge: .top) {
                        ProviderBreakdownPopover(row: row, copy: copy)
                    }
                }

                spendButton(for: row.provider)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(WoolFormat.compactDollars(row.apiUSD))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WoolPalette.lcdGlow)
                    .contentTransition(.numericText(value: row.apiUSD))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: row.apiUSD)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WoolPalette.lcdBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(copy.tokenCount(WoolFormat.compactTokens(row.tokens)))
                    .font(.caption2)
                    .foregroundStyle(WoolPalette.charcoal.opacity(0.7))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: row.tokens)
            }
        }
        .padding(.vertical, 9)
    }

    /// The assumed subscription spend, shown under the provider name. Clicking
    /// opens the editor that feeds the multiplier and tier.
    private func spendButton(for provider: Provider) -> some View {
        Button {
            spendEditorProvider = spendEditorProvider == provider ? nil : provider
        } label: {
            Text(copy.spendLabel(amount: model.spendAmount(for: provider), period: model.spendPeriod(for: provider)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WoolPalette.pastureText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copy.spendHelp)
        .accessibilityLabel(copy.spendHelp)
        .accessibilityValue(copy.spendLabel(amount: model.spendAmount(for: provider), period: model.spendPeriod(for: provider)))
        .popover(isPresented: spendBinding(for: provider), arrowEdge: .bottom) {
            SpendEditorPopover(
                provider: provider,
                model: model,
                copy: copy,
                rangeLabel: copy.dateRangeLabel(model.dateRange),
                rangeExpenditure: rangeExpenditure,
                multiplier: woolMultiplier
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(copy.localOnly)
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
            Text(footerStatus)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .layoutPriority(1)

            Spacer(minLength: 4)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: showsRefreshLoading && !reduceMotion)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(showsRefreshLoading)
            .help(copy.refreshHelp)
            .accessibilityLabel(copy.refreshHelp)

            settingsMenu
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(WoolPalette.pasture.opacity(colorScheme == .dark ? 0.18 : 0.10))
    }

    private var settingsMenu: some View {
        Menu {
            Section(copy.localSources) {
                ForEach(model.sources) { source in
                    Toggle(isOn: Binding(
                        get: { model.sources.first(where: { $0.id == source.id })?.enabled ?? false },
                        set: { model.setSourceEnabled(source.id, enabled: $0) }
                    )) {
                        Text(copy.providerTitle(source.provider))
                    }
                }
            }

            Divider()

            Button(copy.detectSources) { model.detectSources() }
            Button(copy.addCodexFolder) { model.addSource(provider: .codex) }
            Button(copy.addClaudeFolder) { model.addSource(provider: .claude) }

            Divider()

            Button(copy.costEstimates) { openCostSettings() }
            Button(copy.languageToggle) {
                model.setAppLanguage(
                    model.appLanguage.resolved == .simplifiedChinese ? .english : .simplifiedChinese
                )
            }

            Divider()

            Button(copy.quitTitle()) { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(copy.settings)
        .accessibilityLabel(copy.sourcesAndSettings)
    }

    private var footerStatus: String {
        if showsRefreshLoading { return copy.shearing }
        if model.isIndexIncomplete { return copy.stillIndexing }
        if !model.staleSourceIDs.isEmpty { return copy.staleSourceStatus }
        if let lastRefresh = model.lastRefresh {
            return WoolFormat.time(lastRefresh, language: model.appLanguage)
        }
        return copy.waitingStatus
    }

    private var showsLoading: Bool {
        forceLoading || model.isRefreshing || !model.hasLoadedSummary
    }

    private var showsRefreshLoading: Bool {
        forceLoading || model.isRefreshing
    }

    /// The Settings window of an LSUIElement app opens behind the frontmost
    /// app unless we activate first, which reads as "the button is broken."
    private func openCostSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }

    private var servingCostEstimate: ServingCostEstimate? {
        let estimate = model.summary.accounts.reduce(into: ServingCostEstimate()) { total, account in
            total = total + ServingCostCatalog.estimate(
                apiUSD: account.apiUSD,
                provider: account.provider,
                midpointRatio: model.servingCostRatio(for: account.provider)
            )
        }
        return estimate.midpointUSD > 0 ? estimate : nil
    }

    private var providerRows: [ProviderWool] {
        var values: [Provider: ProviderWool] = [:]
        for account in model.summary.accounts {
            var value = values[account.provider] ?? ProviderWool(provider: account.provider)
            value.usage = value.usage + account.usage
            value.apiUSD += account.apiUSD
            if let apiCosts = account.apiCostBreakdown {
                value.apiCostBreakdown = (value.apiCostBreakdown ?? APIUsageCostBreakdown()) + apiCosts
            }
            values[account.provider] = value
        }
        return Provider.allCases.compactMap { values[$0] }
    }

    private func breakdownBinding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { breakdownProvider == provider },
            set: { isPresented in
                if isPresented { breakdownProvider = provider }
                else if breakdownProvider == provider { breakdownProvider = nil }
            }
        )
    }

    private func spendBinding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { spendEditorProvider == provider },
            set: { isPresented in
                if isPresented { spendEditorProvider = provider }
                else if spendEditorProvider == provider { spendEditorProvider = nil }
            }
        )
    }

    /// Whole days covered by the selected range; all-time spans from the
    /// earliest indexed usage day.
    private var rangeDayCount: Double? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch model.dateRange {
        case .currentDay:
            return 1
        case .currentWeek, .currentMonth:
            // Elapsed days of the running cycle, so mid-cycle usage compares
            // against the spend amortized over the same elapsed days.
            guard let interval = model.dateRange.interval() else { return nil }
            let start = calendar.startOfDay(for: interval.start)
            let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            return Double(days + 1)
        case let .lastDays(days):
            return Double(max(days, 1))
        case .yearToDate:
            let yearStart = calendar.date(from: calendar.dateComponents([.year], from: today)) ?? today
            let days = calendar.dateComponents([.day], from: yearStart, to: today).day ?? 0
            return Double(days + 1)
        case let .custom(first, second):
            let start = calendar.startOfDay(for: min(first, second))
            let end = calendar.startOfDay(for: max(first, second))
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            return Double(days + 1)
        case .allTime:
            guard let firstDay = model.earliestUsageDay else { return nil }
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: firstDay),
                to: today
            ).day ?? 0
            return Double(days + 1)
        }
    }

    /// Assumed subscription spend over the selected range, both providers.
    private var rangeExpenditure: Double? {
        guard let days = rangeDayCount, days > 0 else { return nil }
        let daily = model.dailySpendTotal
        guard daily > 0 else { return nil }
        return daily * days
    }

    /// API-equivalent value ÷ subscription spend for the selected range.
    private var woolMultiplier: Double? {
        guard let expenditure = rangeExpenditure, expenditure > 0,
              model.summary.apiUSD > 0 else { return nil }
        return model.summary.apiUSD / expenditure
    }

    /// Fires a wool confetti burst when the displayed value crosses another
    /// $100 for the same preset range. The last celebrated floor persists per
    /// range so relaunches only celebrate growth, never the same milestone.
    private func celebrateWoolMilestone() {
        guard model.hasLoadedSummary, !forceLoading, let key = milestoneKey(model.dateRange) else { return }
        let floor = Int(model.summary.apiUSD / 100)
        let defaults = UserDefaults.standard
        let defaultsKey = "MeterBeater.woolFloor.\(key)"
        guard defaults.object(forKey: defaultsKey) != nil else {
            defaults.set(floor, forKey: defaultsKey)
            return
        }
        let stored = defaults.integer(forKey: defaultsKey)
        if floor != stored { defaults.set(floor, forKey: defaultsKey) }
        if floor > stored, !reduceMotion { confettiBurst += 1 }
    }

    private func milestoneKey(_ range: UsageDateRange) -> String? {
        switch range {
        case .allTime: return "all"
        case .yearToDate: return "ytd"
        case let .lastDays(days): return "last\(days)"
        case .currentDay: return "day"
        case .currentWeek: return "week"
        case .currentMonth: return "month"
        case .custom: return nil
        }
    }

    private var copy: AppCopy { model.copy }
}

/// The icon's sheep face rebuilt in SwiftUI shapes: charcoal head, wool cap,
/// ears, and eyes on a soft pasture disc.
private struct SheepFace: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(WoolPalette.pastureDisc)
                .overlay { Circle().stroke(WoolPalette.charcoal.opacity(0.12), lineWidth: 1) }
            Ellipse()
                .fill(WoolPalette.charcoal)
                .frame(width: 12, height: 5.5)
                .rotationEffect(.degrees(-24))
                .offset(x: -11, y: 1)
            Ellipse()
                .fill(WoolPalette.charcoal)
                .frame(width: 12, height: 5.5)
                .rotationEffect(.degrees(24))
                .offset(x: 11, y: 1)
            Circle()
                .fill(WoolPalette.charcoal)
                .frame(width: 19, height: 19)
                .offset(y: 2.5)
            Circle().fill(WoolPalette.wool).frame(width: 9, height: 9).offset(x: -5.5, y: -7.5)
            Circle().fill(WoolPalette.wool).frame(width: 10.5, height: 10.5).offset(y: -9)
            Circle().fill(WoolPalette.wool).frame(width: 9, height: 9).offset(x: 5.5, y: -7.5)
            Ellipse().fill(WoolPalette.eye).frame(width: 3.6, height: 5).offset(x: -3.6, y: 1.5)
            Ellipse().fill(WoolPalette.eye).frame(width: 3.6, height: 5).offset(x: 3.6, y: 1.5)
            Circle().fill(WoolPalette.lcdBackground).frame(width: 1.8, height: 1.8).offset(x: -3.6, y: 2.6)
            Circle().fill(WoolPalette.lcdBackground).frame(width: 1.8, height: 1.8).offset(x: 3.6, y: 2.6)
        }
        .frame(width: 36, height: 36)
    }
}

/// Header badge: the sheep face with a one-shot head waggle whenever the panel
/// opens or a shear (refresh) starts.
private struct SheepFaceBadge: View {
    let wiggleTrigger: Int

    var body: some View {
        SheepFace()
            .phaseAnimator([0.0, -11, 9, -5, 0], trigger: wiggleTrigger) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: 0.9))
            } animation: { _ in .easeInOut(duration: 0.13) }
    }
}

/// Editor for the assumed subscription spend that feeds the multiplier: an
/// amount, a billing period, and the derived total over the selected range.
private struct SpendEditorPopover: View {
    let provider: Provider
    let model: WoolModel
    let copy: AppCopy
    let rangeLabel: String
    let rangeExpenditure: Double?
    let multiplier: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.spendPopoverTitle)
                    .font(.subheadline.weight(.semibold))
                Text(copy.providerTitle(provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("$")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("", value: amountBinding, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 74)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(copy.spendPopoverTitle)
                Picker("", selection: periodBinding) {
                    ForEach(SpendPeriod.allCases) { period in
                        Text(copy.spendPeriodTitle(period)).tag(period)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .accessibilityLabel(copy.spendPopoverTitle)
            }

            Divider()

            HStack {
                Text(copy.spendOverRange(rangeLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Text(rangeExpenditure.map(WoolFormat.dollars) ?? "—")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    if let multiplier {
                        Text(WoolFormat.multiplier(multiplier))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WoolPalette.lcdGlow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(WoolPalette.lcdBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            }

            HStack {
                Spacer()
                Button(copy.restoreDefaults) { model.resetSpend(for: provider) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(.regularMaterial)
    }

    private var amountBinding: Binding<Double> {
        Binding(
            get: { model.spendAmount(for: provider) },
            set: { model.setSpend(amount: $0, period: model.spendPeriod(for: provider), for: provider) }
        )
    }

    private var periodBinding: Binding<SpendPeriod> {
        Binding(
            get: { model.spendPeriod(for: provider) },
            set: { model.setSpend(amount: model.spendAmount(for: provider), period: $0, for: provider) }
        )
    }
}

/// A Minecraft-style achievement toast: item slot, yellow heading, and a
/// flavor line for the current wool tier.
private struct MinecraftAchievementToast: View {
    let heading: String
    let title: String
    let flavor: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("🐑")
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(Color(white: 0.55).opacity(0.30), in: RoundedRectangle(cornerRadius: 3))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(white: 0.55), lineWidth: 2)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 1.0, blue: 0.33))
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(flavor)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Color(red: 0.129, green: 0.129, blue: 0.129))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(white: 0.35), lineWidth: 2)
        }
    }
}

/// Shared wool-cream card surface for every panel section.
private struct WoolCard: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(WoolPalette.wool)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(WoolPalette.charcoal.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.10), radius: 5, y: 1)
    }
}

/// A one-shot puff of shorn wool released from the sheep badge whenever the
/// panel opens or a refresh starts. Purely decorative; re-created per trigger
/// and never ticks.
private struct WoolPuffBurst: View {
    let trigger: Int

    var body: some View {
        ZStack {
            if trigger > 0 {
                PuffCloud().id(trigger)
            }
        }
        .allowsHitTesting(false)
    }

    private struct PuffCloud: View {
        @State private var flying = false

        private static let puffs: [(dx: CGFloat, dy: CGFloat, size: CGFloat, delay: Double)] = [
            (-17, -21, 7, 0.00),
            (15, -25, 5, 0.06),
            (-5, -31, 6, 0.12),
            (21, -11, 4, 0.16),
            (-23, -7, 5, 0.09)
        ]

        var body: some View {
            ZStack {
                ForEach(Array(Self.puffs.enumerated()), id: \.offset) { _, puff in
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: puff.size, height: puff.size)
                        .scaleEffect(flying ? 1.3 : 0.3)
                        .offset(x: flying ? puff.dx : 0, y: flying ? puff.dy : 3)
                        .opacity(flying ? 0 : 0.9)
                        .animation(.easeOut(duration: 0.9).delay(puff.delay), value: flying)
                }
            }
            .onAppear { flying = true }
        }
    }
}

/// A radial burst of sheep, scissors, and wool tufts over the value card when
/// another $100 of fleece is confirmed. One shot per trigger, then invisible.
private struct WoolConfetti: View {
    let trigger: Int

    var body: some View {
        ZStack {
            if trigger > 0 {
                Burst().id(trigger)
            }
        }
        .allowsHitTesting(false)
    }

    private struct Burst: View {
        @State private var flying = false

        private struct Particle {
            let emoji: String?
            let dx: CGFloat
            let dy: CGFloat
            let size: CGFloat
            let spin: Double
            let delay: Double
        }

        private static let particles: [Particle] = {
            let emojis = ["🐑", "✂️", "🐑", "💸", "🧶", "🐑"]
            return (0..<14).map { index in
                let angle = Double(index) / 14 * 2 * .pi
                let radius: CGFloat = index.isMultiple(of: 2) ? 122 : 86
                return Particle(
                    emoji: index < emojis.count ? emojis[index] : nil,
                    dx: CGFloat(cos(angle)) * radius,
                    dy: CGFloat(sin(angle)) * radius * 0.7 - 26,
                    size: index.isMultiple(of: 3) ? 16 : 10,
                    spin: index.isMultiple(of: 2) ? 260 : -220,
                    delay: Double(index % 5) * 0.035
                )
            }
        }()

        var body: some View {
            ZStack {
                ForEach(Array(Self.particles.enumerated()), id: \.offset) { _, particle in
                    Group {
                        if let emoji = particle.emoji {
                            Text(emoji).font(.system(size: particle.size))
                        } else {
                            Circle()
                                .fill(.white.opacity(0.9))
                                .frame(width: particle.size * 0.65, height: particle.size * 0.65)
                        }
                    }
                    .rotationEffect(.degrees(flying ? particle.spin : 0))
                    .scaleEffect(flying ? 1 : 0.2)
                    .offset(x: flying ? particle.dx : 0, y: flying ? particle.dy : 0)
                    .opacity(flying ? 0 : 1)
                    .animation(.easeOut(duration: 1.15).delay(particle.delay), value: flying)
                }
            }
            .onAppear { flying = true }
        }
    }
}

private struct ProviderWool {
    let provider: Provider
    var usage = TokenUsage()
    var apiUSD: Double = 0
    var apiCostBreakdown: APIUsageCostBreakdown?

    var tokens: Int64 { usage.totalTokens }
    var uncachedInput: Int64 { usage.inputTokens }
    var cachedInput: Int64 {
        usage.cachedInputTokens + usage.cacheWrite5mInputTokens + usage.cacheWrite1hInputTokens
    }
    var output: Int64 { usage.outputTokens }
}

private struct ProviderBreakdownPopover: View {
    let row: ProviderWool
    let copy: AppCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(row.provider == .codex ? WoolPalette.codex : WoolPalette.claude)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.providerTitle(row.provider))
                        .font(.subheadline.weight(.semibold))
                    Text(copy.apiCostBreakdown)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 9) {
                breakdownRow(
                    copy.uncachedInput,
                    tokens: row.uncachedInput,
                    cost: row.apiCostBreakdown?.uncachedInputUSD,
                    color: WoolPalette.uncached
                )
                breakdownRow(
                    copy.cachedInput,
                    tokens: row.cachedInput,
                    cost: row.apiCostBreakdown?.cachedInputUSD,
                    color: WoolPalette.cached
                )
                breakdownRow(
                    copy.outputTokens,
                    tokens: row.output,
                    cost: row.apiCostBreakdown?.outputUSD,
                    color: WoolPalette.output
                )
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.total)
                        .font(.caption.weight(.medium))
                    Text(copy.tokenCount(WoolFormat.compactTokens(row.tokens)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text(WoolFormat.dollars(row.apiUSD))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            Text(copy.apiCostBreakdownNote)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 290)
        .background(.regularMaterial)
    }

    private func breakdownRow(_ title: String, tokens: Int64, cost: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(cost.map(WoolFormat.dollars) ?? "—")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(copy.tokenCount(WoolFormat.compactTokens(tokens)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .help(breakdownHelp(tokens: tokens, cost: cost))
    }

    private func breakdownHelp(tokens: Int64, cost: Double?) -> String {
        let tokenText = copy.tokenCount(WoolFormat.exactTokens(tokens, language: copy.language))
        guard let cost else { return tokenText }
        return "\(WoolFormat.dollars(cost)) · \(tokenText)"
    }
}

enum WoolFormat {
    /// Money and compact counts are deliberately pinned to en_US digits and
    /// separators: the unit is USD, the display is the LCD meter, and pinning
    /// keeps every money string consistent regardless of system region.
    private static let numberLocale = Locale(identifier: "en_US")

    static func multiplier(_ value: Double) -> String {
        guard value.isFinite else { return "0×" }
        if value >= 100 { return "\(Int(value.rounded()))×" }
        return value.formatted(.number.precision(.fractionLength(value >= 10 ? 0 : 1)).locale(Self.numberLocale)) + "×"
    }

    static func menuValue(_ summary: UsageSummary) -> String {
        summary.apiUSD > 0
            ? compactDollars(summary.apiUSD)
            : compactTokens(summary.usage.totalTokens)
    }

    static func heroValue(_ summary: UsageSummary) -> String {
        if summary.apiUSD > 0 { return dollars(summary.apiUSD) }
        if summary.usage.totalTokens > 0 { return compactTokens(summary.usage.totalTokens) }
        return "$0"
    }

    static func dollars(_ value: Double) -> String {
        value.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(value >= 1_000 ? 0 : 2))
                .locale(Self.numberLocale)
        )
    }

    static func compactDollars(_ value: Double) -> String {
        guard value.isFinite else { return "$0" }
        switch abs(value) {
        case 1_000_000...:
            return "$\(trimmed(value / 1_000_000))M"
        case 1_000...:
            return "$\(trimmed(value / 1_000))K"
        default:
            return "$\(Int(value.rounded()))"
        }
    }

    static func compactTokens(_ value: Int64) -> String {
        switch abs(value) {
        case 1_000_000_000...:
            return "\(trimmed(Double(value) / 1_000_000_000))B"
        case 1_000_000...:
            return "\(trimmed(Double(value) / 1_000_000))M"
        case 1_000...:
            return "\(trimmed(Double(value) / 1_000))K"
        default:
            return "\(value)"
        }
    }

    static func time(_ date: Date, language: AppLanguage) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(language.locale)
        )
    }

    static func exactTokens(_ value: Int64, language: AppLanguage) -> String {
        value.formatted(
            .number
                .grouping(.automatic)
                .locale(language.locale)
        )
    }

    private static func trimmed(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(value >= 100 ? 0 : value >= 10 ? 1 : 2))
                .locale(Self.numberLocale)
        )
    }
}

/// The icon's exact design language: pasture greens, wool cream, charcoal
/// face, and the green-on-black fleece meter.
enum WoolPalette {
    static let pastureHigh = Color(red: 0.475, green: 0.788, blue: 0.341)
    static let pastureLow = Color(red: 0.180, green: 0.545, blue: 0.267)
    static let pastureNightHigh = Color(red: 0.118, green: 0.271, blue: 0.157)
    static let pastureNightLow = Color(red: 0.043, green: 0.129, blue: 0.075)
    static let pasture = Color(red: 0.216, green: 0.588, blue: 0.302)
    /// Darker pasture for text on the cream cards (WCAG AA at caption sizes).
    static let pastureText = Color(red: 0.110, green: 0.361, blue: 0.180)
    static let pastureDisc = Color(red: 0.831, green: 0.925, blue: 0.788)
    static let wool = Color(red: 0.980, green: 0.969, blue: 0.941)
    static let charcoal = Color(red: 0.200, green: 0.188, blue: 0.173)
    static let eye = Color(red: 0.965, green: 0.949, blue: 0.910)
    static let lcdBackground = Color(red: 0.063, green: 0.098, blue: 0.059)
    static let lcdGlow = Color(red: 0.443, green: 0.925, blue: 0.478)
    static let burnGlow = Color(red: 1.0, green: 0.722, blue: 0.302)
    static let live = Color(red: 0.22, green: 0.62, blue: 0.38)
    static let codex = Color(red: 0.18, green: 0.47, blue: 0.92)
    static let claude = Color(red: 0.78, green: 0.37, blue: 0.14)
    static let burn = Color(red: 0.88, green: 0.36, blue: 0.16)
    static let dateAccent = Color(red: 0.180, green: 0.545, blue: 0.267)
    static let uncached = Color(red: 0.25, green: 0.49, blue: 0.88)
    static let cached = Color(red: 0.47, green: 0.34, blue: 0.78)
    static let output = Color(red: 0.20, green: 0.61, blue: 0.39)
}

#if DEBUG
struct AchievementCaptureView: View {
    let model: WoolModel

    var body: some View {
        let copy = model.copy
        let tier = WoolTier.tier(for: 124)
        MinecraftAchievementToast(
            heading: copy.achievementGet,
            title: copy.tierName(tier),
            flavor: copy.tierFlavors(tier).first ?? ""
        )
        .padding(20)
    }
}

struct SpendEditorCaptureView: View {
    let model: WoolModel

    var body: some View {
        SpendEditorPopover(
            provider: .codex,
            model: model,
            copy: model.copy,
            rangeLabel: model.copy.dateRangeLabel(model.dateRange),
            rangeExpenditure: 3450,
            multiplier: 15
        )
    }
}

struct ProviderBreakdownCaptureView: View {
    let model: WoolModel

    var body: some View {
        if let row = firstRow {
            ProviderBreakdownPopover(row: row, copy: model.copy)
        }
    }

    private var firstRow: ProviderWool? {
        guard let provider = Provider.allCases.first(where: { candidate in
            model.summary.accounts.contains(where: { $0.provider == candidate })
        }) else { return nil }
        var row = ProviderWool(provider: provider)
        for account in model.summary.accounts where account.provider == provider {
            row.usage = row.usage + account.usage
            row.apiUSD += account.apiUSD
            if let apiCosts = account.apiCostBreakdown {
                row.apiCostBreakdown = (row.apiCostBreakdown ?? APIUsageCostBreakdown()) + apiCosts
            }
        }
        return row
    }
}
#endif
