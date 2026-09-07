import Foundation
import FastScanner

public struct ScanResult: Sendable {
    public var events: [UsageEvent]
    public var warnings: [String]
    public var filesScanned: Int
    public var bytesRead: Int64
    /// Internal checkpoint data used by the incremental Codex indexer.
    public var lastCodexSnapshot: [String: Int64]?
    /// Model active at the Codex file cursor. Incremental tails must resume
    /// this state instead of guessing from mutable thread metadata.
    public var lastCodexModel: String?
    public var endOffset: Int64?
    public var accounting: AccountingDiagnostics

    public init(events: [UsageEvent] = [], warnings: [String] = [], filesScanned: Int = 0, bytesRead: Int64 = 0, lastCodexSnapshot: [String: Int64]? = nil, lastCodexModel: String? = nil, endOffset: Int64? = nil, accounting: AccountingDiagnostics = AccountingDiagnostics()) {
        self.events = events
        self.warnings = warnings
        self.filesScanned = filesScanned
        self.bytesRead = bytesRead
        self.lastCodexSnapshot = lastCodexSnapshot
        self.lastCodexModel = lastCodexModel
        self.endOffset = endOffset
        self.accounting = accounting
    }
}

struct EventRollupAccumulator {
    private struct Key: Hashable {
        let provider: Provider
        let sourceID: String
        let accountID: String
        let currentAuthAccountID: String?
        let attributionConfidence: AttributionConfidence
        let attributionBasis: AttributionBasis
        let sessionID: String
        let parentSessionID: String?
        let day: Date
        let model: String
        let sourcePath: String
        let isSubagent: Bool

        /// Preserve the on-disk rollup identity used by earlier index builds.
        /// Constructing this once per aggregate is cheap; constructing it for
        /// every source event was a major cost on multi-million-event archives.
        var storageID: String {
            let value = [
                sourceID,
                sourcePath,
                provider.rawValue,
                accountID,
                currentAuthAccountID ?? "",
                attributionConfidence.rawValue,
                attributionBasis.rawValue,
                sessionID,
                parentSessionID ?? "",
                model,
                isSubagent ? "1" : "0",
                String(day.timeIntervalSince1970)
            ].joined(separator: "\u{1F}")
            return "rollup:\(value)"
        }
    }

    private struct Aggregate {
        let key: Key
        var eventCount: Int
        var usage: TokenUsage
        var pricingContext: APIPricingContext
    }

    private var positions: [Key: Int] = [:]
    private var aggregates: [Aggregate] = []
    private var calendar: Calendar
    private var cachedDayInterval: DateInterval?

    init(calendar: Calendar = .current) {
        var calendar = calendar
        calendar.timeZone = .current
        self.calendar = calendar
    }

    var values: [UsageEvent] {
        aggregates.map { aggregate in
            let key = aggregate.key
            return UsageEvent(
                id: key.storageID,
                provider: key.provider,
                sourceID: key.sourceID,
                accountID: key.accountID,
                currentAuthAccountID: key.currentAuthAccountID,
                attributionConfidence: key.attributionConfidence,
                attributionBasis: key.attributionBasis,
                sessionID: key.sessionID,
                parentSessionID: key.parentSessionID,
                timestamp: key.day,
                model: key.model,
                sourcePath: key.sourcePath,
                byteOffset: 0,
                isSubagent: key.isSubagent,
                eventCount: aggregate.eventCount,
                usage: aggregate.usage,
                pricingContext: aggregate.pricingContext
            )
        }
    }

    mutating func append(_ event: UsageEvent) {
        append(provider: event.provider, sourceID: event.sourceID, accountID: event.accountID, currentAuthAccountID: event.currentAuthAccountID, attributionConfidence: event.attributionConfidence, attributionBasis: event.attributionBasis, sessionID: event.sessionID, parentSessionID: event.parentSessionID, timestamp: event.timestamp, model: event.model, sourcePath: event.sourcePath, isSubagent: event.isSubagent, eventCount: event.eventCount, usage: event.usage, pricingContext: event.pricingContext)
    }

    mutating func append(
        provider: Provider,
        sourceID: String,
        accountID: String,
        currentAuthAccountID: String?,
        attributionConfidence: AttributionConfidence,
        attributionBasis: AttributionBasis,
        sessionID: String,
        parentSessionID: String?,
        timestamp: Date,
        model: String,
        sourcePath: String,
        isSubagent: Bool,
        eventCount: Int = 1,
        usage: TokenUsage,
        pricingContext: APIPricingContext = APIPricingContext()
    ) {
        // A local calendar day can span a UTC pricing boundary. Split there
        // before adding tokens so historical rates survive compact storage.
        let day = max(day(containing: timestamp), PricingCatalog.pricingPeriodStart(at: timestamp))
        let key = Key(
            provider: provider,
            sourceID: sourceID,
            accountID: accountID,
            currentAuthAccountID: currentAuthAccountID,
            attributionConfidence: attributionConfidence,
            attributionBasis: attributionBasis,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            day: day,
            model: model,
            sourcePath: sourcePath,
            isSubagent: isSubagent
        )
        if let position = positions[key] {
            aggregates[position].eventCount += eventCount
            aggregates[position].usage.inputTokens += usage.inputTokens
            aggregates[position].usage.cachedInputTokens += usage.cachedInputTokens
            aggregates[position].usage.cacheWrite5mInputTokens += usage.cacheWrite5mInputTokens
            aggregates[position].usage.cacheWrite1hInputTokens += usage.cacheWrite1hInputTokens
            aggregates[position].usage.outputTokens += usage.outputTokens
            aggregates[position].usage.reasoningOutputTokens += usage.reasoningOutputTokens
            aggregates[position].pricingContext = aggregates[position].pricingContext + pricingContext
        } else {
            positions[key] = aggregates.count
            aggregates.append(Aggregate(key: key, eventCount: eventCount, usage: usage, pricingContext: pricingContext))
        }
    }

    private mutating func day(containing timestamp: Date) -> Date {
        if let cachedDayInterval, cachedDayInterval.contains(timestamp) {
            return cachedDayInterval.start
        }
        let start = calendar.startOfDay(for: timestamp)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        cachedDayInterval = DateInterval(start: start, end: end)
        return start
    }
}

public enum UsageScanner {
    public static func scan(source: UsageSource, interval: DateInterval? = nil, maxFiles: Int? = nil) -> ScanResult {
        switch source.provider {
        case .codex:
            return CodexScanner.scan(source: source, interval: interval, maxFiles: maxFiles)
        case .claude:
            return ClaudeCodeScanner.scan(source: source, interval: interval, maxFiles: maxFiles)
        }
    }
}

enum JSONValue {
    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func string(_ dict: [String: Any], _ key: String) -> String? { dict[key] as? String }
    static func int64(_ dict: [String: Any], _ key: String) -> Int64? {
        if let number = dict[key] as? NSNumber { return number.int64Value }
        if let string = dict[key] as? String { return Int64(string) }
        return nil
    }
    static func bool(_ dict: [String: Any], _ key: String) -> Bool { (dict[key] as? Bool) ?? false }
}

/// Read-only, mmap-backed JSONL traversal. The old implementation repeatedly
/// appended to a `Data` buffer and copied every line before parsing it. Large
/// Codex rollouts contain millions of lines, so those copies dominated the
/// scan even when the line was unrelated to usage accounting.
enum StreamLines {
    private final class CallbackBox {
        let body: (UnsafeRawBufferPointer, Int64) -> Void

        init(body: @escaping (UnsafeRawBufferPointer, Int64) -> Void) {
            self.body = body
        }
    }

    private typealias CCallback = @convention(c) (UnsafePointer<UInt8>?, Int, Int64, UnsafeMutableRawPointer?) -> Void
    private static let callback: CCallback = { line, length, offset, context in
        guard let line, let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.body(UnsafeRawBufferPointer(start: line, count: length), offset)
    }

    static func forEachLine(in url: URL, startOffset: Int64 = 0, candidate: [UInt8], body: @escaping (UnsafeRawBufferPointer, Int64) -> Void) -> (bytes: Int64, completeBytes: Int64, warnings: [String]) {
        let box = CallbackBox(body: body)
        var fileSize: Int64 = 0
        var completeOffset: Int64 = startOffset
        var invalidUTF8Tail: Int32 = 0
        let status = candidate.withUnsafeBufferPointer { needle in
            ai_scan_jsonl_file(url.path, startOffset, needle.baseAddress, needle.count, callback, Unmanaged.passUnretained(box).toOpaque(), &fileSize, &completeOffset, &invalidUTF8Tail)
        }
        guard status == 0 else {
            return (fileSize, completeOffset, ["Could not scan \(url.path)"])
        }
        return (fileSize, completeOffset, invalidUTF8Tail != 0 ? ["Invalid UTF-8 in trailing bytes: \(url.path)"] : [])
    }

    static func forEachLine(in url: URL, startOffset: Int64 = 0, firstCandidate: [UInt8], secondCandidate: [UInt8], body: @escaping (UnsafeRawBufferPointer, Int64) -> Void) -> (bytes: Int64, completeBytes: Int64, warnings: [String]) {
        let box = CallbackBox(body: body)
        var fileSize: Int64 = 0
        var completeOffset: Int64 = startOffset
        var invalidUTF8Tail: Int32 = 0
        let status = firstCandidate.withUnsafeBufferPointer { first in
            secondCandidate.withUnsafeBufferPointer { second in
                ai_scan_jsonl_file2(
                    url.path,
                    startOffset,
                    first.baseAddress,
                    first.count,
                    second.baseAddress,
                    second.count,
                    callback,
                    Unmanaged.passUnretained(box).toOpaque(),
                    &fileSize,
                    &completeOffset,
                    &invalidUTF8Tail
                )
            }
        }
        guard status == 0 else {
            return (fileSize, completeOffset, ["Could not scan \(url.path)"])
        }
        return (fileSize, completeOffset, invalidUTF8Tail != 0 ? ["Invalid UTF-8 in trailing bytes: \(url.path)"] : [])
    }
}

/// Targeted, allocation-free accessors for the scalar fields needed by the
/// provider adapters. Escaped strings fall back to Foundation for correctness.
struct FastJSONLine {
    let bytes: UnsafeRawBufferPointer

    func contains(_ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, pattern.count <= bytes.count else { return false }
        return pattern.withUnsafeBytes { patternBytes in
            memmem(bytes.baseAddress, bytes.count, patternBytes.baseAddress, patternBytes.count) != nil
        }
    }

    func containsKeyValue(_ key: [UInt8], value: [UInt8]) -> Bool {
        var searchOffset = 0
        while let start = valueStart(forKey: key, from: searchOffset) {
            guard bytes[start] == 0x22 else { return false }
            let contentStart = start + 1
            let end = contentStart + value.count
            if end < bytes.count, bytes[end] == 0x22,
               value.indices.allSatisfy({ bytes[contentStart + $0] == value[$0] }) {
                return true
            }
            searchOffset = start + 1
        }
        return false
    }

    func string(forKey key: [UInt8], from offset: Int = 0) -> String? {
        guard let start = valueStart(forKey: key, from: offset), bytes[start] == 0x22 else { return nil }
        let contentStart = start + 1
        var cursor = contentStart
        var escaped = false
        while cursor < bytes.count {
            switch bytes[cursor] {
            case 0x5C:
                escaped = true
                cursor += 2
            case 0x22:
                if !escaped {
                    return String(bytes: bytes[contentStart..<cursor], encoding: .utf8)
                }
                let data = Data(bytes: bytes.baseAddress!.advanced(by: start), count: cursor - start + 1)
                return (try? JSONSerialization.jsonObject(with: data)) as? String
            default:
                cursor += 1
            }
        }
        return nil
    }

    func date(forKey key: [UInt8], from offset: Int = 0) -> Date? {
        guard let start = valueStart(forKey: key, from: offset), bytes[start] == 0x22 else { return nil }
        let contentStart = start + 1
        var cursor = contentStart
        while cursor < bytes.count {
            if bytes[cursor] == 0x22 {
                guard let rawBaseAddress = bytes.baseAddress else { return nil }
                let baseAddress = rawBaseAddress.assumingMemoryBound(to: UInt8.self)
                let value = UnsafeBufferPointer(start: baseAddress.advanced(by: contentStart), count: cursor - contentStart)
                if let date = DateParsing.parse(value) { return date }
                return DateParsing.parse(String(decoding: value, as: UTF8.self))
            }
            if bytes[cursor] == 0x5C { cursor += 2 } else { cursor += 1 }
        }
        return nil
    }

    func int64(forKey key: [UInt8], from offset: Int = 0) -> Int64? {
        guard let start = valueStart(forKey: key, from: offset) else { return nil }
        var cursor = start
        var negative = false
        if bytes[cursor] == 0x2D {
            negative = true
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 else { return nil }
        var value: Int64 = 0
        while cursor < bytes.count {
            let digit = bytes[cursor]
            guard digit >= 0x30, digit <= 0x39 else { break }
            value = value &* 10 &+ Int64(digit - 0x30)
            cursor += 1
        }
        return negative ? -value : value
    }

    func bool(forKey key: [UInt8], from offset: Int = 0) -> Bool {
        guard let start = valueStart(forKey: key, from: offset), start + 4 <= bytes.count else { return false }
        return bytes[start] == 0x74 && bytes[start + 1] == 0x72 && bytes[start + 2] == 0x75 && bytes[start + 3] == 0x65
    }

    func objectValueStart(forKey key: [UInt8], from offset: Int = 0) -> Int? {
        guard let start = valueStart(forKey: key, from: offset), bytes[start] == 0x7B else { return nil }
        return start
    }

    private func valueStart(forKey key: [UInt8], from offset: Int = 0) -> Int? {
        guard !key.isEmpty, key.count <= bytes.count else { return nil }
        guard let base = bytes.baseAddress else { return nil }
        return key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) -> Int? in
            guard let keyBase = keyBytes.baseAddress else { return nil }
            var cursor = min(max(0, offset), bytes.count)
            while cursor + key.count <= bytes.count {
                guard let found = memmem(base.advanced(by: cursor), bytes.count - cursor, keyBase, key.count) else { return nil }
                let foundBytes = UnsafePointer(found.assumingMemoryBound(to: UInt8.self))
                let keyStart = foundBytes - base.assumingMemoryBound(to: UInt8.self)
                let boundaryOK: Bool
                if keyStart == 0 {
                    boundaryOK = true
                } else {
                    let previous = bytes[keyStart - 1]
                    boundaryOK = previous == 0x7B || previous == 0x2C || previous == 0x20 || previous == 0x09 || previous == 0x0D || previous == 0x0A
                }
                if boundaryOK {
                    var value = keyStart + key.count
                    while value < bytes.count && (bytes[value] == 0x20 || bytes[value] == 0x09 || bytes[value] == 0x0D || bytes[value] == 0x0A) { value += 1 }
                    if value < bytes.count, bytes[value] == 0x3A {
                        value += 1
                        while value < bytes.count && (bytes[value] == 0x20 || bytes[value] == 0x09 || bytes[value] == 0x0D || bytes[value] == 0x0A) { value += 1 }
                        return value
                    }
                }
                cursor = keyStart + 1
            }
            return nil
        }
    }
}
