import Foundation

/// Removes stale AIUsageTracker-prefixed artifacts that benchmark and test
/// harnesses leave in the user temporary directory (multi-gigabyte
/// `AIUsageTrackerRealBenchmark-*.sqlite` index builds, leaked
/// `AIUsageTrackerTests-*` scratch directories, and their `-wal`/`-shm`
/// sidecars). Harnesses that create scratch stores must use one of these
/// prefixes so their leftovers are reclaimed on the next app launch.
public enum TempArtifactJanitor {
    public static let stalePrefixes = [
        "AIUsageTrackerRealBenchmark-",
        "AIUsageTrackerBenchmark-",
        "AIUsageTracker-index-benchmark-",
        "AIUsageTrackerTests-",
    ]

    /// Sweeps on a background utility queue so launch is never delayed.
    public static func sweepAsync(olderThan age: TimeInterval = 24 * 60 * 60) {
        DispatchQueue.global(qos: .utility).async {
            _ = sweep(olderThan: age)
        }
    }

    /// Removes matching entries not modified within `age`. Returns the number
    /// of entries removed. Only the top level of `directory` is listed, so the
    /// cost is one readdir regardless of how much data is reclaimed.
    @discardableResult
    public static func sweep(
        olderThan age: TimeInterval = 24 * 60 * 60,
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> Int {
        let fm = FileManager()
        let cutoff = Date().addingTimeInterval(-age)
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return 0 }

        var removed = 0
        for url in entries {
            let name = url.lastPathComponent
            guard stalePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified < cutoff else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                // Entry may be held open by a live harness; leave it for the next sweep.
            }
        }
        return removed
    }
}
