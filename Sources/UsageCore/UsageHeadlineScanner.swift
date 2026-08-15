import Foundation

public struct UsageHeadlineResult: Sendable {
    public var summary: UsageSummary
    public var complete: Bool
    public var duration: TimeInterval

    public init(summary: UsageSummary = UsageSummary(), complete: Bool = false, duration: TimeInterval = 0) {
        self.summary = summary
        self.complete = complete
        self.duration = duration
    }
}

/// Produces a first-frame Codex headline without opening or mutating SQLite.
/// It reads fixed-size transcript head/tail windows and prices only the small
/// set of root-thread snapshots that fit inside that bounded pass. Inherited
/// thread usage and Claude remain deferred to the accurate SQLite refresh.
public enum UsageHeadlineScanner {
    public static func scanCodex(sources: [UsageSource], timeLimit: TimeInterval = 4) -> UsageHeadlineResult {
        let started = Date()
        let deadline = started.addingTimeInterval(max(0.1, timeLimit))
        var events: [UsageEvent] = []
        var accounting = AccountingDiagnostics()
        var complete = true

        func finish() -> UsageHeadlineResult {
            var summary = UsageAggregator.summarize(events)
            summary.accounting = accounting
            summary.isProvisional = true
            return UsageHeadlineResult(
                summary: summary,
                complete: complete,
                duration: Date().timeIntervalSince(started)
            )
        }

        for source in sources where source.enabled && source.provider == .codex {
            let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
            let metadata = CodexMetadata(root: root)
            for directory in CodexScanner.transcriptDirectories(root: root) {
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in complete = false; return false }
                ) else {
                    complete = false
                    continue
                }
                for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                    guard Date() < deadline else {
                        complete = false
                        return finish()
                    }
                    let scanned = CodexScanner.quickScanFile(
                        source: source,
                        url: file,
                        metadata: metadata,
                        maximumTailWindow: 512 * 1024
                    )
                    accounting = accounting + scanned.accounting
                    events.append(contentsOf: scanned.events)
                }
            }
        }
        return finish()
    }
}
