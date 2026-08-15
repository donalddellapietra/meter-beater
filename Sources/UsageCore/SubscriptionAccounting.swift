import Foundation

public enum SubscriptionAccounting {
    public static func calendarDays(from startDate: Date, to endDate: Date, calendar: Calendar = .current) -> Int {
        let lower = Swift.min(startDate, endDate)
        let upper = Swift.max(startDate, endDate)
        let start = calendar.startOfDay(for: lower)
        let end = calendar.startOfDay(for: upper)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    public static func proratedCost(monthlyUSD: Double, startDate: Date, endDate: Date, calendar: Calendar = .current) -> Double {
        guard monthlyUSD.isFinite, monthlyUSD > 0 else { return 0 }
        let days = Double(calendarDays(from: startDate, to: endDate, calendar: calendar))
        let cost = monthlyUSD * days / 30
        return cost.isFinite ? cost : Double.greatestFiniteMagnitude
    }

    public static func valueMultiple(apiUSD: Double, subscriptionUSD: Double) -> Double? {
        guard apiUSD.isFinite, apiUSD >= 0, subscriptionUSD.isFinite, subscriptionUSD > 0 else { return nil }
        let multiple = apiUSD / subscriptionUSD
        return multiple.isFinite ? multiple : Double.greatestFiniteMagnitude
    }
}
