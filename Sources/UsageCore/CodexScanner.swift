import Foundation

enum CodexScanner {
    static func transcriptDirectories(root: URL) -> [URL] {
        ["sessions", "archived_sessions"].map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func scan(source: UsageSource, interval: DateInterval?, maxFiles: Int? = nil) -> ScanResult {
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let metadata = CodexMetadata(root: root)
        var result = ScanResult()
        let directories = transcriptDirectories(root: root)
        guard !directories.isEmpty else {
            result.warnings.append("Codex transcript directories are not readable under: \(root.path)")
            return result
        }

        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
                result.warnings.append("Codex transcript directory is not readable: \(directory.path)")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if let maxFiles, result.filesScanned >= maxFiles { return result }
                let file = scanFile(source: source, url: url, interval: interval, metadata: metadata)
                result.events.append(contentsOf: file.events)
                result.warnings.append(contentsOf: file.warnings)
                result.filesScanned += file.filesScanned
                result.bytesRead += file.bytesRead
                result.accounting = result.accounting + file.accounting
            }
        }
        return result
    }

    static func scanFile(source: UsageSource, url: URL, interval: DateInterval?, metadata: CodexMetadata? = nil, startOffset: Int64 = 0, previousSnapshot: [String: Int64]? = nil, previousModel: String? = nil, compact: Bool = false) -> ScanResult {
        let metadata = metadata ?? CodexMetadata(root: URL(fileURLWithPath: source.rootPath, isDirectory: true))
        var result = ScanResult(filesScanned: 1, bytesRead: Int64((try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize) ?? 0))
        let threadKey = url.deletingPathExtension().lastPathComponent
        let thread = metadata.thread(for: url, fallbackKey: threadKey)
        let header = transcriptHeader(at: url, thread: thread)
        let parentID = thread.parentID ?? header?.parentID
        let isSubagent = thread.isSubagent || header?.isSubagent == true
        var effectiveStartOffset = startOffset
        var requiresFirstRequestUsage = false
        if startOffset == 0, let header {
            result.accounting.inheritedBaselines += 1
            switch ownUsageBoundary(in: url, header: header) {
            case .found(let ownStart):
                effectiveStartOffset = ownStart
                requiresFirstRequestUsage = true
            case .noOwnedUsage:
                return result
            case .ambiguous:
                result.warnings.append("Could not locate the first original task in inherited Codex transcript: \(url.path)")
                return result
            }
        }
        var highWater = requiresFirstRequestUsage ? nil : previousSnapshot.map(RawCodexUsage.init(snapshot:))
        var lastObservedSnapshot: RawCodexUsage?
        var observedCounterDecrease = false
        var lastSnapshotKey: SnapshotKey?
        var currentModel = previousModel ?? thread.model ?? "unknown"
        var longContextThreshold = PricingCatalog.longContextThreshold(for: currentModel, provider: .codex)
        var rollups = compact ? EventRollupAccumulator() : nil
        let stream = StreamLines.forEachLine(
            in: url,
            startOffset: effectiveStartOffset,
            firstCandidate: CodexJSON.tokenCountMarker,
            secondCandidate: CodexJSON.turnContextMarker
        ) { rawLine, offset in
            let line = FastJSONLine(bytes: rawLine)
            if line.contains(CodexJSON.turnContextMarker) {
                if let model = line.string(forKey: CodexJSON.model), !model.isEmpty {
                    currentModel = model
                    longContextThreshold = PricingCatalog.longContextThreshold(for: model, provider: .codex)
                }
                return
            }
            guard line.contains(CodexJSON.tokenCountMarker),
                  let timestamp = line.date(forKey: CodexJSON.timestamp),
                  let totalStart = line.objectValueStart(forKey: CodexJSON.totalTokenUsage) else { return }

            let current = RawCodexUsage(line: line, from: totalStart)
            lastObservedSnapshot = current
            let last = line.contains(CodexJSON.lastTokenUsageMarker)
                ? line.objectValueStart(forKey: CodexJSON.lastTokenUsage).map { RawCodexUsage(line: line, from: $0) }
                : nil
            let key = SnapshotKey(current: current, last: last)
            let delta: RawCodexUsage
            let isExplicitRequestUsage: Bool
            if let previousHighWater = highWater {
                let positiveDelta = current.positiveDelta(from: previousHighWater)
                if !positiveDelta.hasPositiveUsage {
                    if key == lastSnapshotKey { result.accounting.duplicateSnapshots += 1 }
                    else { result.accounting.staleSnapshots += 1 }
                    observedCounterDecrease = observedCounterDecrease || current.hasDecrease(from: previousHighWater)
                    return
                }
                observedCounterDecrease = observedCounterDecrease || current.hasDecrease(from: previousHighWater)
                highWater = previousHighWater.maximum(with: current)
                if let last, last.hasPositiveUsage {
                    let preferred = last.clamped(to: positiveDelta)
                    if preferred.hasPositiveUsage {
                        delta = preferred
                        isExplicitRequestUsage = true
                    } else {
                        delta = positiveDelta
                        isExplicitRequestUsage = false
                    }
                } else {
                    delta = positiveDelta
                    isExplicitRequestUsage = false
                }
            } else {
                highWater = current
                if requiresFirstRequestUsage {
                    requiresFirstRequestUsage = false
                    lastSnapshotKey = key
                    guard let last, last.hasPositiveUsage else { return }
                    delta = last.clamped(to: current)
                    isExplicitRequestUsage = true
                } else {
                    let firstDelta = last?.clamped(to: current)
                    if firstDelta?.hasPositiveUsage == true {
                        delta = firstDelta!
                        isExplicitRequestUsage = true
                    } else {
                        delta = current
                        isExplicitRequestUsage = false
                    }
                }
            }
            lastSnapshotKey = key
            guard delta.hasPositiveUsage,
                  interval.map({ timestamp >= $0.start && timestamp < $0.end }) ?? true else { return }

            let usage = TokenUsage(inputTokens: max(0, delta.input - delta.cached), cachedInputTokens: delta.cached, cacheWrite5mInputTokens: delta.cacheWrite5m, cacheWrite1hInputTokens: delta.cacheWrite1h, outputTokens: delta.output, reasoningOutputTokens: delta.reasoningOutput)
            let longContextUsage = longContextThreshold
                .map { isExplicitRequestUsage && delta.input > $0 } == true ? usage : TokenUsage()
            let pricingContext = APIPricingContext(longContextUsage: longContextUsage)
            if compact {
                rollups?.append(provider: .codex, sourceID: source.id, accountID: "unattributed", currentAuthAccountID: nil, attributionConfidence: .sourceOnly, attributionBasis: .none, sessionID: thread.id ?? header?.id ?? threadKey, parentSessionID: parentID, timestamp: timestamp, model: currentModel, sourcePath: url.path, isSubagent: isSubagent, usage: usage, pricingContext: pricingContext)
            } else {
                result.events.append(UsageEvent(id: "codex:\(source.id):\(url.path):\(offset)", provider: .codex, sourceID: source.id, accountID: "unattributed", currentAuthAccountID: nil, attributionConfidence: .sourceOnly, attributionBasis: .none, sessionID: thread.id ?? header?.id ?? threadKey, parentSessionID: parentID, timestamp: timestamp, model: currentModel, sourcePath: url.path, byteOffset: offset, isSubagent: isSubagent, usage: usage, pricingContext: pricingContext))
            }
        }
        result.warnings.append(contentsOf: stream.warnings)
        result.bytesRead = max(0, stream.bytes - effectiveStartOffset)
        result.endOffset = stream.completeBytes
        result.lastCodexModel = currentModel
        if let rollups { result.events = rollups.values }
        if let highWater {
            result.lastCodexSnapshot = highWater.snapshot
            // Codex can append cumulative snapshots from concurrent work out
            // of order. A later recovery to the component-wise high-water
            // proves reordering, not a reset. Only a file that ends below its
            // high-water remains accounting-ambiguous.
            if observedCounterDecrease, lastObservedSnapshot != highWater {
                result.accounting.ambiguousResets += 1
            }
        }
        return result
    }

    static func quickScanFile(source: UsageSource, url: URL, metadata: CodexMetadata, includeInheritedUsage: Bool = false, maximumTailWindow: Int = 8 * 1024 * 1024) -> ScanResult {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let threadKey = url.deletingPathExtension().lastPathComponent
        let thread = metadata.thread(for: url, fallbackKey: threadKey)
        let header = transcriptHeader(at: url, thread: thread)
        if header != nil {
            if includeInheritedUsage {
                return scanFile(source: source, url: url, interval: nil, metadata: metadata, compact: true)
            }
            var result = ScanResult(filesScanned: 1)
            result.accounting.inheritedBaselines = 1
            result.warnings.append("Deferred inherited Codex transcript until the accurate index pass: \(url.path)")
            return result
        }
        var tailWindow = 512 * 1024
        var lastData = readWindow(at: url, fromEnd: true, windowSize: tailWindow)
        var last = snapshot(in: lastData, fromEnd: true)
        // A large final tool result can push the latest counter outside the
        // ordinary tail window. Expand only for those uncommon threads and
        // keep the overview read bounded to 8 MiB per file.
        while last == nil, lastData.count == tailWindow, tailWindow < maximumTailWindow {
            tailWindow = min(tailWindow * 2, maximumTailWindow)
            lastData = readWindow(at: url, fromEnd: true, windowSize: tailWindow)
            last = snapshot(in: lastData, fromEnd: true)
        }
        var result = ScanResult(filesScanned: 1, bytesRead: Int64(lastData.count))
        result.lastCodexModel = thread.model
        guard let last else {
            result.warnings.append("No final token snapshot found in \(url.path)")
            result.endOffset = 0
            return result
        }
        let usage = last.usage
        guard usage.hasPositiveUsage else {
            result.endOffset = 0
            result.lastCodexSnapshot = last.usage.snapshot
            return result
        }
        let timestamp = last.timestamp ?? values?.contentModificationDate ?? Date()
        let event = UsageEvent(
            id: "codex-fast:\(source.id):\(url.path)",
            provider: .codex,
            sourceID: source.id,
            accountID: "unattributed",
            currentAuthAccountID: nil,
            attributionConfidence: .sourceOnly,
            attributionBasis: .none,
            sessionID: thread.id ?? threadKey,
            parentSessionID: thread.parentID,
            timestamp: timestamp,
            model: thread.model ?? "unknown",
            sourcePath: url.path,
            isSubagent: thread.isSubagent,
            usage: TokenUsage(inputTokens: max(0, usage.input - usage.cached), cachedInputTokens: usage.cached, cacheWrite5mInputTokens: usage.cacheWrite5m, cacheWrite1hInputTokens: usage.cacheWrite1h, outputTokens: usage.output, reasoningOutputTokens: usage.reasoningOutput)
        )
        result.events = [event]
        result.endOffset = 0
        result.lastCodexSnapshot = last.usage.snapshot
        return result
    }

    private struct QuickSnapshot {
        let timestamp: Date?
        let usage: RawCodexUsage
    }

    private static func readWindow(at url: URL, fromEnd: Bool, windowSize: Int) -> Data {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let fileSize = values.fileSize, fileSize > 0, let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let offset = fromEnd ? max(0, fileSize - windowSize) : 0
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: min(windowSize, fileSize - offset)) ?? Data()
        } catch {
            return Data()
        }
    }

    private static func snapshot(in data: Data, fromEnd: Bool) -> QuickSnapshot? {
        var found: QuickSnapshot?
        data.withUnsafeBytes { rawBuffer in
            guard let rawBaseAddress = rawBuffer.baseAddress else { return }
            let baseAddress = rawBaseAddress.assumingMemoryBound(to: UInt8.self)
            if fromEnd {
                var end = rawBuffer.count
                while end > 0 {
                    var start = end
                    while start > 0 && baseAddress[start - 1] != 0x0A { start -= 1 }
                    let line = UnsafeRawBufferPointer(start: baseAddress.advanced(by: start), count: end - start)
                    let fastLine = FastJSONLine(bytes: line)
                    if fastLine.contains(CodexJSON.tokenCountMarker),
                       let totalStart = fastLine.objectValueStart(forKey: CodexJSON.totalTokenUsage) {
                        found = QuickSnapshot(timestamp: fastLine.date(forKey: CodexJSON.timestamp), usage: RawCodexUsage(line: fastLine, from: totalStart))
                        return
                    }
                    if start == 0 { break }
                    end = start - 1
                }
            } else {
                var start = 0
                while start < rawBuffer.count {
                    var end = start
                    while end < rawBuffer.count && baseAddress[end] != 0x0A { end += 1 }
                    let line = UnsafeRawBufferPointer(start: baseAddress.advanced(by: start), count: end - start)
                    let fastLine = FastJSONLine(bytes: line)
                    if fastLine.contains(CodexJSON.tokenCountMarker),
                       let totalStart = fastLine.objectValueStart(forKey: CodexJSON.totalTokenUsage) {
                        found = QuickSnapshot(timestamp: fastLine.date(forKey: CodexJSON.timestamp), usage: RawCodexUsage(line: fastLine, from: totalStart))
                        return
                    }
                    if end >= rawBuffer.count { break }
                    start = end + 1
                }
            }
        }
        return found
    }

    private struct InheritedTranscriptHeader {
        let id: String?
        let parentID: String?
        let isSubagent: Bool
        let createdAt: Date?
    }

    private static func transcriptHeader(at url: URL, thread: CodexThreadMetadata) -> InheritedTranscriptHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        let lineEnd = data.firstIndex(of: 0x0A) ?? data.endIndex
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return nil }
            let line = FastJSONLine(bytes: UnsafeRawBufferPointer(start: base, count: lineEnd))
            let forkedFromID = line.string(forKey: CodexJSON.forkedFromID)
            let rawParentID = line.string(forKey: CodexJSON.parentThreadID)
            let hasRawSpawnParent = line.contains(CodexJSON.threadSpawnMarker) && rawParentID != nil
            let isSubagent = thread.isSubagent || hasRawSpawnParent
            // `parent_thread_id` alone identifies older independent subagents.
            // Codex writes `forked_from_id` when it physically copies parent
            // history into this transcript, which is the baseline we exclude.
            guard forkedFromID != nil else { return nil }
            return InheritedTranscriptHeader(
                id: line.string(forKey: CodexJSON.id),
                parentID: thread.parentID ?? rawParentID ?? forkedFromID,
                isSubagent: isSubagent,
                createdAt: line.date(forKey: CodexJSON.timestamp)
            )
        }
    }

    private enum OwnUsageBoundary {
        case found(Int64)
        case noOwnedUsage
        case ambiguous
    }

    private static func ownUsageBoundary(in url: URL, header: InheritedTranscriptHeader) -> OwnUsageBoundary {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values?.fileSize, fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return .ambiguous }
        defer { try? handle.close() }

        // Forks place their original turns after a byte-for-byte copy of the
        // parent transcript. Walk backwards in bounded windows until the last
        // copied task is reached, so a multi-gigabyte inherited prefix is never
        // replayed merely to locate the ownership boundary.
        let chunkSize = 16 * 1024 * 1024
        let overlap = 256 * 1024
        var coreEnd = fileSize
        var earliestOwnOffset: Int64?
        var sawBoundary = false
        var sawAmbiguousBoundary = false
        while coreEnd > 0 {
            let coreStart = max(0, coreEnd - chunkSize)
            let readStart = max(0, coreStart - overlap)
            let readEnd = min(fileSize, coreEnd + overlap)
            let boundaries = autoreleasepool { () -> [TaskBoundary]? in
                do {
                    try handle.seek(toOffset: UInt64(readStart))
                    guard let data = try handle.read(upToCount: readEnd - readStart) else { return nil }
                    return taskBoundaries(
                        in: data,
                        fileOffset: Int64(readStart),
                        coreRange: Int64(coreStart)..<Int64(coreEnd),
                        header: header
                    )
                } catch {
                    return nil
                }
            }
            guard let boundaries else { return .ambiguous }
            var copiedOffset: Int64?
            for boundary in boundaries {
                sawBoundary = true
                switch boundary.ownership {
                case .own:
                    if earliestOwnOffset.map({ boundary.offset < $0 }) ?? true {
                        earliestOwnOffset = boundary.offset
                    }
                case .copied:
                    if let earliestOwnOffset, boundary.offset > earliestOwnOffset {
                        return .ambiguous
                    }
                    copiedOffset = boundary.offset
                case .ambiguous:
                    sawAmbiguousBoundary = true
                }
            }
            if copiedOffset != nil {
                guard !sawAmbiguousBoundary else { return .ambiguous }
                return earliestOwnOffset.map(OwnUsageBoundary.found) ?? .noOwnedUsage
            }
            coreEnd = coreStart
        }
        guard !sawAmbiguousBoundary else { return .ambiguous }
        if let earliestOwnOffset { return .found(earliestOwnOffset) }
        return sawBoundary ? .noOwnedUsage : .ambiguous
    }

    private enum TaskOwnership {
        case own
        case copied
        case ambiguous
    }

    private struct TaskBoundary {
        let offset: Int64
        let ownership: TaskOwnership
    }

    private static func taskBoundaries(
        in data: Data,
        fileOffset: Int64,
        coreRange: Range<Int64>,
        header: InheritedTranscriptHeader
    ) -> [TaskBoundary] {
        let marker = Data(CodexJSON.taskStartedMarker)
        var boundaries: [TaskBoundary] = []
        var searchStart = data.startIndex
        let creationSecond = header.createdAt.map { Int64(floor($0.timeIntervalSince1970)) }
        while searchStart < data.endIndex,
              let match = data.range(of: marker, in: searchStart..<data.endIndex) {
            let markerOffset = fileOffset + Int64(match.lowerBound)
            searchStart = match.upperBound
            guard coreRange.contains(markerOffset) else { continue }
            let lineStart = data[..<match.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[match.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                let line = FastJSONLine(bytes: UnsafeRawBufferPointer(start: base.advanced(by: lineStart), count: lineEnd - lineStart))
                let startedAt = line.int64(forKey: CodexJSON.startedAt)
                let turnID = line.string(forKey: CodexJSON.turnID)
                let ownership: TaskOwnership
                if let creationSecond, let startedAt {
                    if startedAt != creationSecond {
                        ownership = startedAt > creationSecond ? .own : .copied
                    } else if let childID = header.id,
                              let turnID,
                              isVersion7UUID(childID),
                              isVersion7UUID(turnID) {
                        ownership = turnID >= childID ? .own : .copied
                    } else {
                        // Copied task records can share the fork's creation
                        // second but predate v7 turn IDs. Treat that legacy
                        // shape as copied; a later own boundary still fences
                        // the child usage explicitly.
                        ownership = .copied
                    }
                } else if let childID = header.id,
                          let turnID,
                          isVersion7UUID(childID),
                          isVersion7UUID(turnID) {
                    ownership = turnID >= childID ? .own : .copied
                } else {
                    ownership = .ambiguous
                }
                boundaries.append(TaskBoundary(offset: fileOffset + Int64(lineStart), ownership: ownership))
            }
        }
        return boundaries
    }

    private static func isVersion7UUID(_ value: String) -> Bool {
        value.utf8.count == 36 && value.utf8.dropFirst(14).first == Character("7").asciiValue
    }
}

struct RawCodexUsage: Equatable {
    let input: Int64
    let cached: Int64
    let cacheWrite5m: Int64
    let cacheWrite1h: Int64
    let output: Int64
    let reasoningOutput: Int64

    init(dictionary: [String: Any]) {
        input = JSONValue.int64(dictionary, "input_tokens") ?? 0
        cached = JSONValue.int64(dictionary, "cached_input_tokens") ?? 0
        cacheWrite5m = JSONValue.int64(dictionary, "cache_write_input_tokens") ?? 0
        cacheWrite1h = JSONValue.int64(dictionary, "cache_write_input_tokens_1h") ?? 0
        output = JSONValue.int64(dictionary, "output_tokens") ?? 0
        reasoningOutput = JSONValue.int64(dictionary, "reasoning_output_tokens") ?? 0
    }

    init(line: FastJSONLine, from offset: Int) {
        input = line.int64(forKey: CodexJSON.inputTokens, from: offset) ?? 0
        cached = line.int64(forKey: CodexJSON.cachedInputTokens, from: offset) ?? 0
        cacheWrite5m = line.int64(forKey: CodexJSON.cacheWriteInputTokens, from: offset) ?? 0
        cacheWrite1h = line.int64(forKey: CodexJSON.cacheWriteInputTokens1h, from: offset) ?? 0
        output = line.int64(forKey: CodexJSON.outputTokens, from: offset) ?? 0
        reasoningOutput = line.int64(forKey: CodexJSON.reasoningOutputTokens, from: offset) ?? 0
    }

    init(snapshot: [String: Int64]) {
        input = snapshot["input"] ?? 0
        cached = snapshot["cached"] ?? 0
        cacheWrite5m = snapshot["cache_5m"] ?? 0
        cacheWrite1h = snapshot["cache_1h"] ?? 0
        output = snapshot["output"] ?? 0
        reasoningOutput = snapshot["reasoning"] ?? 0
    }

    var snapshot: [String: Int64] {
        ["input": input, "cached": cached, "cache_5m": cacheWrite5m, "cache_1h": cacheWrite1h, "output": output, "reasoning": reasoningOutput]
    }

    var hasPositiveUsage: Bool { input > 0 || output > 0 || reasoningOutput > 0 || cached > 0 || cacheWrite5m > 0 || cacheWrite1h > 0 }

    func positiveDelta(from previous: RawCodexUsage) -> RawCodexUsage {
        func difference(_ value: Int64, _ old: Int64) -> Int64 { max(0, value - old) }
        return RawCodexUsage(
            input: difference(input, previous.input),
            cached: difference(cached, previous.cached),
            cacheWrite5m: difference(cacheWrite5m, previous.cacheWrite5m),
            cacheWrite1h: difference(cacheWrite1h, previous.cacheWrite1h),
            output: difference(output, previous.output),
            reasoningOutput: difference(reasoningOutput, previous.reasoningOutput)
        )
    }

    func clamped(to limit: RawCodexUsage) -> RawCodexUsage {
        RawCodexUsage(
            input: min(max(0, input), limit.input),
            cached: min(max(0, cached), limit.cached),
            cacheWrite5m: min(max(0, cacheWrite5m), limit.cacheWrite5m),
            cacheWrite1h: min(max(0, cacheWrite1h), limit.cacheWrite1h),
            output: min(max(0, output), limit.output),
            reasoningOutput: min(max(0, reasoningOutput), limit.reasoningOutput)
        )
    }

    func maximum(with other: RawCodexUsage) -> RawCodexUsage {
        RawCodexUsage(
            input: max(input, other.input),
            cached: max(cached, other.cached),
            cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
            cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h),
            output: max(output, other.output),
            reasoningOutput: max(reasoningOutput, other.reasoningOutput)
        )
    }

    func hasDecrease(from previous: RawCodexUsage) -> Bool {
        input < previous.input || cached < previous.cached || cacheWrite5m < previous.cacheWrite5m || cacheWrite1h < previous.cacheWrite1h || output < previous.output || reasoningOutput < previous.reasoningOutput
    }

    private init(input: Int64, cached: Int64, cacheWrite5m: Int64, cacheWrite1h: Int64, output: Int64, reasoningOutput: Int64) {
        self.input = input; self.cached = cached; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h; self.output = output; self.reasoningOutput = reasoningOutput
    }
}

private struct SnapshotKey: Equatable {
    let current: RawCodexUsage
    let last: RawCodexUsage?
}

private enum CodexJSON {
    static let timestamp = Array(#""timestamp""#.utf8)
    static let tokenCountMarker = Array(#""type":"token_count""#.utf8)
    static let turnContextMarker = Array(#""type":"turn_context""#.utf8)
    static let model = Array(#""model""#.utf8)
    static let threadSpawnMarker = Array(#""thread_spawn""#.utf8)
    static let parentThreadID = Array(#""parent_thread_id""#.utf8)
    static let forkedFromID = Array(#""forked_from_id""#.utf8)
    static let id = Array(#""id""#.utf8)
    static let taskStartedMarker = Array(#""type":"task_started""#.utf8)
    static let startedAt = Array(#""started_at""#.utf8)
    static let turnID = Array(#""turn_id""#.utf8)
    static let totalTokenUsage = Array(#""total_token_usage""#.utf8)
    static let lastTokenUsage = Array(#""last_token_usage""#.utf8)
    static let lastTokenUsageMarker = Array(#""last_token_usage""#.utf8)
    static let inputTokens = Array(#""input_tokens""#.utf8)
    static let cachedInputTokens = Array(#""cached_input_tokens""#.utf8)
    static let cacheWriteInputTokens = Array(#""cache_write_input_tokens""#.utf8)
    static let cacheWriteInputTokens1h = Array(#""cache_write_input_tokens_1h""#.utf8)
    static let outputTokens = Array(#""output_tokens""#.utf8)
    static let reasoningOutputTokens = Array(#""reasoning_output_tokens""#.utf8)
}

struct CodexThreadMetadata {
    let id: String?
    let model: String?
    let parentID: String?
    let isSubagent: Bool
}

struct CodexMetadata {
    let isComplete: Bool
    private var byPath: [String: CodexThreadMetadata] = [:]
    private var byName: [String: CodexThreadMetadata] = [:]

    init(root: URL) {
        var mapByPath: [String: CodexThreadMetadata] = [:]
        var mapByName: [String: CodexThreadMetadata] = [:]
        var complete = true
        let children: [URL]
        if let listed = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            children = listed
        } else {
            children = []
            complete = false
        }
        let stateFiles = children
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.path < $1.path }
        for state in stateFiles {
            let metadata = SQLiteCodexMetadata.read(from: state)
            complete = complete && metadata.complete
            for row in metadata.rows {
                let meta = CodexThreadMetadata(id: row.id, model: row.model, parentID: row.parentID, isSubagent: row.isSubagent)
                if let path = row.rolloutPath {
                    mapByPath[path] = meta
                    mapByPath[URL(fileURLWithPath: path).standardizedFileURL.path] = meta
                    mapByName[URL(fileURLWithPath: path).lastPathComponent] = meta
                }
                if let id = row.id { mapByName[id] = meta }
            }
        }
        byPath = mapByPath
        byName = mapByName
        isComplete = complete
    }

    func thread(for url: URL, fallbackKey: String) -> CodexThreadMetadata {
        byPath[url.path] ?? byPath[url.standardizedFileURL.path] ?? byName[url.lastPathComponent] ?? byName[fallbackKey] ?? CodexThreadMetadata(id: nil, model: nil, parentID: nil, isSubagent: url.path.contains("/subagents/"))
    }

    func exactThread(for url: URL) -> CodexThreadMetadata? {
        byPath[url.path] ?? byPath[url.standardizedFileURL.path]
    }
}
