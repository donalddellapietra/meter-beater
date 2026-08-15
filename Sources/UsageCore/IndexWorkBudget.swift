import Foundation

/// Resource limits for work that is allowed to run while the desktop app is
/// interactive. The index is local and rebuildable, so throughput is less
/// important than keeping memory, thermal load, and input latency bounded.
public struct IndexWorkBudget: Sendable, Hashable {
    public let workerCount: Int
    public let maxPendingFiles: Int
    public let maxPendingEvents: Int
    public let maxPendingBytes: Int64

    public init(
        workerCount: Int,
        maxPendingFiles: Int = 16,
        maxPendingEvents: Int = 80_000,
        maxPendingBytes: Int64 = 64 * 1024 * 1024
    ) {
        self.workerCount = max(1, workerCount)
        self.maxPendingFiles = max(1, maxPendingFiles)
        self.maxPendingEvents = max(1, maxPendingEvents)
        self.maxPendingBytes = max(1, maxPendingBytes)
    }

    /// Two workers keep mmap residency and CPU contention bounded while the
    /// already-visible headline remains interactive.
    public static let interactive = IndexWorkBudget(
        workerCount: 2,
        maxPendingFiles: 8,
        maxPendingEvents: 30_000,
        maxPendingBytes: 24 * 1024 * 1024
    )
}
