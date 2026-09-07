import Foundation
import UsageCore

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// The user's current locale with only the language (and script) replaced,
    /// so region conventions — 24-hour clock, date order, first weekday —
    /// survive the in-app language override.
    var locale: Locale {
        var components = Locale.Components(locale: .current)
        if resolved == .simplifiedChinese {
            components.languageComponents.languageCode = .chinese
            components.languageComponents.script = .hanSimplified
        } else {
            components.languageComponents.languageCode = .english
            components.languageComponents.script = nil
        }
        return Locale(components: components)
    }
}

/// Wool-party rank, judged by API-equivalent value ÷ subscription spend.
enum WoolTier {
    case philanthropist
    case freeRangeWallet
    case couponClipper
    case buffetStrategist
    case masterShearer
    case woolBaron
    case nightmare
    case walkingDataCenter
    case gpuReaper
    case nationalReserve

    static func tier(for multiplier: Double) -> WoolTier {
        switch multiplier {
        case ..<0.5: return .philanthropist
        case ..<1: return .freeRangeWallet
        case ..<2.5: return .couponClipper
        case ..<5: return .buffetStrategist
        case ..<10: return .masterShearer
        case ..<20: return .woolBaron
        case ..<40: return .nightmare
        case ..<80: return .walkingDataCenter
        case ..<160: return .gpuReaper
        default: return .nationalReserve
        }
    }
}

struct AppCopy {
    let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language.resolved
    }

    private var chinese: Bool { language == .simplifiedChinese }

    var appName: String { chinese ? "羊毛计" : "Meter Beater" }
    var loading: String { chinese ? "加载中…" : "Loading…" }
    var ready: String { chinese ? "就绪" : "Ready" }
    var grazing: String { chinese ? "吃草中" : "Grazing" }
    var shearing: String { chinese ? "薅羊毛中…" : "Shearing…" }
    var stillIndexing: String { chinese ? "还在索引中…" : "Still indexing…" }

    /// Token counts use the "tokens" loanword in both languages, matching the
    /// hero pill's zh copy (吃掉的 tokens).
    func tokenCount(_ formatted: String) -> String { "\(formatted) tokens" }
    var apiRateHeading: String { chinese ? "按公开 API 单价折算" : "AT PUBLIC API PRICES" }
    var tokenLabel: String { chinese ? "吃掉的 tokens" : "tokens munched" }
    var servingCostTitle: String { chinese ? "大厂大概烧了" : "Labs likely burned" }
    var servingCostHelp: String {
        chinese
            ? "按公开 API 推理毛利区间反推的服务成本；不含训练成本，也未扣除订阅费。"
            : "Serving cost inferred from public API margin estimates; excludes training and does not subtract subscription fees."
    }
    var pricingUsage: String { loading }
    var readingLedger: String { loading }
    var emptyState: String { chinese ? "还没薅到 · 数羊中…" : "No wool yet · counting sheep…" }
    var localOnly: String { chinese ? "只读本地" : "LOCAL ONLY" }
    var refreshHelp: String { chinese ? "刷新本地用量" : "Refresh local usage" }
    var localSources: String { chinese ? "本地来源" : "Local sources" }
    var detectSources: String { chinese ? "查找本地来源" : "Find local sources" }
    var addCodexFolder: String { chinese ? "添加 Codex 文件夹…" : "Add Codex folder…" }
    var addClaudeFolder: String { chinese ? "添加 Claude 文件夹…" : "Add Claude folder…" }
    var costEstimates: String { chinese ? "成本估算…" : "Cost estimates…" }
    /// Menu toggle showing the target language in its own script.
    var languageToggle: String { chinese ? "English" : "中文" }
    var settings: String { chinese ? "设置" : "Settings" }
    var sourcesAndSettings: String { chinese ? "本地来源与设置" : "Local sources and settings" }
    var staleSourceStatus: String { chinese ? "来源离线" : "Source offline" }
    var waitingStatus: String { chinese ? "等待数据" : "Waiting for data" }
    var dateRange: String { chinese ? "日期范围" : "Date range" }
    var rollingWindows: String { chinese ? "滚动" : "Rolling" }
    var calendarPeriods: String { chinese ? "日历" : "Calendar" }
    var rollingWindowsHelp: String { chinese ? "截至现在的连续时长，不在午夜重置。" : "Trailing time ending now; does not reset at midnight." }
    var calendarPeriodsHelp: String { chinese ? "从当前日历周期开始，累计至今。" : "From the start of the current calendar period." }
    var now: String { chinese ? "现在" : "Now" }
    var last24Hours: String { chinese ? "近 24 小时" : "Last 24 hours" }
    var today: String { chinese ? "今天" : "Today" }
    var thisWeek: String { chinese ? "本周" : "This week" }
    var thisMonth: String { chinese ? "本月" : "This month" }
    var weeklyCycle: String { chinese ? "每周周期" : "Weekly cycle" }
    var monthlyCycle: String { chinese ? "每月周期" : "Monthly cycle" }
    var cycleStarts: String { chinese ? "起始" : "Starts" }
    var allTime: String { chinese ? "全部" : "All time" }
    var yearToDate: String { chinese ? "今年" : "This year" }
    var last7Days: String { chinese ? "近 7 天" : "Last 7 days" }
    var last30Days: String { chinese ? "近 30 天" : "Last 30 days" }
    var allRecordedUsage: String { chinese ? "全部用量记录" : "All recorded usage" }
    var dateRangePresets: String { chinese ? "返回预设范围" : "Back to presets" }
    var customRange: String { chinese ? "自定义范围" : "Custom range" }
    var chooseStartDate: String { chinese ? "选择开始日期" : "Choose a start date" }
    var chooseEndDate: String { chinese ? "再选择结束日期" : "Choose an end date" }
    var clear: String { chinese ? "清除" : "Clear" }
    var apply: String { chinese ? "应用" : "Apply" }
    var previousMonth: String { chinese ? "上个月" : "Previous month" }
    var nextMonth: String { chinese ? "下个月" : "Next month" }
    var selected: String { chinese ? "已选择" : "Selected" }
    var apiCostBreakdown: String { chinese ? "API 成本构成" : "API cost breakdown" }
    var uncachedInput: String { chinese ? "未缓存输入" : "Uncached input" }
    var cachedInput: String { chinese ? "缓存输入" : "Cached input" }
    var outputTokens: String { chinese ? "输出" : "Output" }
    var total: String { chinese ? "总计" : "Total" }
    var apiCostBreakdownNote: String {
        chinese
            ? "按标准公开 API 单价折算；仅在请求计数明确时计入长上下文加价。缓存读取与服务商报告的缓存创建分别计价；不推测极速模式、工具调用或区域附加费。"
            : "Calculated from standard public API rates, including long-context premiums only when request counters prove they apply. Cache reads and reported cache creation are priced separately; fast-mode, tool-call, and regional surcharges are not inferred."
    }

    var costTitle: String { chinese ? "成本估算" : "Cost estimates" }
    var costDescription: String {
        chinese
            ? "设置模型服务成本占公开 API 价格的比例。"
            : "Set model serving cost as a percentage of public API prices."
    }
    var estimatedServingCost: String { chinese ? "推测模型服务成本" : "Estimated model serving cost" }
    var uncertaintyNote: String {
        chinese
            ? "区间会保留研究默认的不确定性宽度。默认值：OpenAI 45%，Anthropic 52.5%。"
            : "The range keeps the research-based uncertainty width. Defaults: OpenAI 45%, Anthropic 52.5%."
    }
    var viewResearch: String { chinese ? "查看研究依据" : "View research basis" }
    var restoreDefaults: String { chinese ? "恢复默认值" : "Restore defaults" }
    var useFolder: String { chinese ? "使用文件夹" : "Use Folder" }

    func chooseDataRoot(_ provider: Provider) -> String {
        chinese
            ? "选择只读的 \(provider.rawValue) 数据文件夹。"
            : "Choose the read-only \(provider.rawValue) data folder."
    }

    func quitTitle() -> String { chinese ? "退出\(appName)" : "Quit \(appName)" }

    var achievementGet: String { chinese ? "成就达成！" : "Achievement Get!" }
    var tierHelp: String { chinese ? "查看你的羊毛段位" : "Show your wool tier" }
    var spendPopoverTitle: String { chinese ? "订阅支出" : "Subscription spend" }
    var spendHelp: String { chinese ? "点击调整订阅支出" : "Click to adjust your subscription spend" }

    func tierName(_ tier: WoolTier) -> String {
        switch tier {
        case .philanthropist: return chinese ? "AI 慈善家" : "AI Philanthropist"
        case .freeRangeWallet: return chinese ? "韭菜本菜" : "Free-Range Wallet"
        case .couponClipper: return chinese ? "羊毛学徒" : "Coupon Clipper"
        case .buffetStrategist: return chinese ? "正牌羊毛党" : "Buffet Strategist"
        case .masterShearer: return chinese ? "薅毛大师" : "Master Shearer"
        case .woolBaron: return chinese ? "羊毛大亨" : "Wool Baron"
        case .nightmare: return chinese ? "大厂噩梦" : "The Labs' Nightmare"
        case .walkingDataCenter: return chinese ? "人形数据中心" : "Walking Data Center"
        case .gpuReaper: return chinese ? "GPU 收割机" : "GPU Reaper"
        case .nationalReserve: return chinese ? "国家羊毛储备" : "National Wool Reserve"
        }
    }

    func tierFlavors(_ tier: WoolTier) -> [String] {
        switch tier {
        case .philanthropist:
            return chinese
                ? ["羊毛没薅到，反倒被剪了一刀。", "大厂感谢你的慷慨捐赠。o7"]
                : ["You're not beating the meter. You ARE the meter.", "The labs thank you for your generous donation. o7"]
        case .freeRangeWallet:
            return chinese
                ? ["不是你在薅订阅，是订阅在薅你。", "有机散养，按月收割。"]
                : ["The subscription is farming you, actually.", "Organic, grass-fed, harvested monthly."]
        case .couponClipper:
            return chinese
                ? ["第一撮羊毛到手，羊群开始注意你了。", "咔嚓咔嚓，这是回本的声音。"]
                : ["Snip snip. Every coupon counts.", "First wool collected. The flock notices you."]
        case .buffetStrategist:
            return chinese
                ? ["羊毛党会员卡：100% 纯羊毛制作。", "文明薅毛，人人有责。"]
                : ["You arrived hungry and brought tupperware.", "Third plate. No shame. That's the strategy."]
        case .masterShearer:
            return chinese
                ? ["你的剪刀已经见过大世面了。", "羊群敬你，电表怕你。"]
                : ["Your scissors have seen things.", "Sheep respect you. Meters fear you."]
        case .woolBaron:
            return chinese
                ? ["整个牧场都是你的了。", "这不是订阅，是封地。"]
                : ["You own the pasture now.", "Subscription? More like a land grant."]
        case .nightmare:
            return chinese
                ? ["某处，一块 GPU 正在流泪。", "价目表申请了人身保护令。"]
                : ["Somewhere, a GPU weeps.", "The rate card has filed a restraining order."]
        case .walkingDataCenter:
            return chinese
                ? ["你不是在用云，你就是云。", "某位容量规划师突然坐直了。"]
                : ["You don't use the cloud. You ARE the cloud.", "Somewhere, a capacity planner just sat up straight."]
        case .gpuReaper:
            return chinese
                ? ["H100 之间流传着你的传说。", "你的上下文窗口自带引力场。"]
                : ["H100s whisper your name as a warning.", "Your context window has a gravitational pull."]
        case .nationalReserve:
            return chinese
                ? ["你的羊毛储量已列入国家战略。", "纯度 99.9% 的战略级羊毛。"]
                : ["Congress has questions about your token usage.", "Strategic reserves of government-grade wool."]
        }
    }

    func spendLabel(amount: Double, period: SpendPeriod) -> String {
        let value = "$" + amount.formatted(.number.precision(.fractionLength(0...2)))
        switch period {
        case .weekly: return chinese ? "\(value)/周" : "\(value)/wk"
        case .monthly: return chinese ? "\(value)/月" : "\(value)/mo"
        case .yearly: return chinese ? "\(value)/年" : "\(value)/yr"
        }
    }

    func spendPeriodTitle(_ period: SpendPeriod) -> String {
        switch period {
        case .weekly: return chinese ? "每周" : "Weekly"
        case .monthly: return chinese ? "每月" : "Monthly"
        case .yearly: return chinese ? "每年" : "Yearly"
        }
    }

    func spendOverRange(_ rangeLabel: String) -> String {
        chinese ? "预计支出 · \(rangeLabel)" : "Est. spend · \(rangeLabel)"
    }


    func providerTitle(_ provider: Provider) -> String {
        provider == .codex ? "OpenAI · Codex" : "Anthropic · Claude"
    }

    func showCostBreakdown(_ provider: Provider) -> String {
        chinese
            ? "查看\(providerTitle(provider))的 API 成本构成"
            : "Show \(providerTitle(provider)) API cost breakdown"
    }

    func weekdayTitle(_ weekday: Int) -> String {
        var calendar = UsageDateRange.gregorianCurrent
        calendar.locale = language.locale
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return symbols[min(max(weekday, 1), 7) - 1]
    }

    func monthDayTitle(_ day: Int) -> String {
        if chinese { return "\(day) 号" }
        let suffix: String
        switch day % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(day)\(suffix)"
    }

    func dateRangeLabel(_ range: UsageDateRange, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch range {
        case .allTime:
            return allTime
        case .currentDay:
            return today
        case let .lastHours(hours):
            if hours == 24 { return last24Hours }
            return chinese ? "近 \(hours) 小时" : "Last \(hours) hours"
        case let .currentWeek(startWeekday):
            return startWeekday == calendar.firstWeekday ? thisWeek : weeklyCycle
        case let .currentMonth(startDay):
            return startDay == 1 ? thisMonth : monthlyCycle
        case let .lastDays(days):
            if days == 7 { return last7Days }
            if days == 30 { return last30Days }
            return chinese ? "近 \(days) 天" : "Last \(days) days"
        case .yearToDate:
            return yearToDate
        case let .custom(first, second):
            let start = min(first, second)
            let end = max(first, second)
            if calendar.isDate(start, inSameDayAs: now), calendar.isDate(end, inSameDayAs: now) {
                return today
            }
            if calendar.isDate(start, inSameDayAs: end) {
                return shortDate(start)
            }
            return "\(shortDate(start)) – \(shortDate(end))"
        }
    }

    /// Rolling presets show the exact starting time; calendar presets show
    /// inclusive elapsed dates, not their future renewal date.
    func dateRangeDetail(
        _ range: UsageDateRange,
        now: Date = Date(),
        calendar: Calendar = UsageDateRange.gregorianCurrent
    ) -> String {
        guard let interval = range.interval(now: now, calendar: calendar) else { return allRecordedUsage }
        if range.isRolling {
            var style = Date.FormatStyle(
                locale: language.locale, calendar: calendar, timeZone: calendar.timeZone
            ).month(.abbreviated).day().hour().minute()
            if calendar.component(.year, from: interval.start) != calendar.component(.year, from: now) {
                style = style.year()
            }
            return "\(interval.start.formatted(style)) – \(self.now)"
        }
        guard let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return allRecordedUsage }
        let today = calendar.startOfDay(for: now)
        let end = min(lastDay, today)
        let thisYear = calendar.component(.year, from: today)
        let includesYear = calendar.component(.year, from: interval.start) != thisYear
            || calendar.component(.year, from: end) != thisYear
        var style = Date.FormatStyle(
            locale: language.locale, calendar: calendar, timeZone: calendar.timeZone
        ).month(.abbreviated).day()
        if includesYear { style = style.year() }
        let startLabel = interval.start.formatted(style)
        if calendar.isDate(interval.start, inSameDayAs: end) { return startLabel }
        return "\(startLabel) – \(end.formatted(style))"
    }

    func shortDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .month(.abbreviated)
                .day()
                .locale(language.locale)
        )
    }

    func fullDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .complete, time: .omitted)
                .locale(language.locale)
        )
    }
}
