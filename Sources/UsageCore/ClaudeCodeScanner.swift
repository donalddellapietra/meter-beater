import Foundation

enum ClaudeCodeScanner {
    static func scan(source: UsageSource, interval: DateInterval?, maxFiles: Int? = nil) -> ScanResult {
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let resolver = ClaudeAccountResolver(root: root)
        var result = ScanResult()
        var latestByMessage: [String: UsageEvent] = [:]

        guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            result.warnings.append("Claude projects directory is not readable: \(projects.path)")
            return result
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let maxFiles, result.filesScanned >= maxFiles { break }
            let file = scanFile(source: source, url: url, interval: nil, resolver: resolver)
            for event in file.events {
                let key = event.providerEventID.map { "\($0):\(event.isSubagent ? "sidechain" : "main")" } ?? event.id
                if let old = latestByMessage[key], old.timestamp > event.timestamp || (old.timestamp == event.timestamp && old.byteOffset >= event.byteOffset) { continue }
                latestByMessage[key] = event
            }
            result.warnings.append(contentsOf: file.warnings)
            result.filesScanned += file.filesScanned
            result.bytesRead += file.bytesRead
        }

        result.events = latestByMessage.values.filter { interval?.contains($0.timestamp) ?? true }.sorted { $0.timestamp < $1.timestamp }
        return result
    }

    static func scanFile(source: UsageSource, url: URL, interval: DateInterval?, resolver: ClaudeAccountResolver? = nil, startOffset: Int64 = 0, compact: Bool = false) -> ScanResult {
        let resolver = resolver ?? ClaudeAccountResolver(root: URL(fileURLWithPath: source.rootPath, isDirectory: true))
        var result = ScanResult(filesScanned: 1, bytesRead: Int64((try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize) ?? 0))
        var latestByMessage: [String: UsageEvent] = [:]
        var rollups = compact ? EventRollupAccumulator() : nil
        let fileSubagentID = subagentID(from: url)
        let fileIsSubagent = url.path.contains("/subagents/")
        let stream = StreamLines.forEachLine(in: url, startOffset: startOffset, candidate: ClaudeJSON.usage) { rawLine, offset in
            let line = FastJSONLine(bytes: rawLine)
            guard line.contains(ClaudeJSON.assistantMarker),
                  let usageStart = line.objectValueStart(forKey: ClaudeJSON.usage),
                  let messageID = line.string(forKey: ClaudeJSON.id),
                  let sessionID = line.string(forKey: ClaudeJSON.sessionID),
                  let timestampString = line.string(forKey: ClaudeJSON.timestamp),
                  let timestamp = DateParsing.parse(timestampString) else { return }
            let cacheCreationTotal = line.int64(forKey: ClaudeJSON.cacheCreationInputTokens, from: usageStart) ?? 0
            let cache5m = line.int64(forKey: ClaudeJSON.ephemeral5mInputTokens, from: usageStart) ?? 0
            let cache1h = line.int64(forKey: ClaudeJSON.ephemeral1hInputTokens, from: usageStart) ?? 0
            let usageValue = TokenUsage(inputTokens: line.int64(forKey: ClaudeJSON.inputTokens, from: usageStart) ?? 0, cachedInputTokens: line.int64(forKey: ClaudeJSON.cacheReadInputTokens, from: usageStart) ?? 0, cacheWrite5mInputTokens: cache5m + (cache5m == 0 && cache1h == 0 ? cacheCreationTotal : 0), cacheWrite1hInputTokens: cache1h, outputTokens: line.int64(forKey: ClaudeJSON.outputTokens, from: usageStart) ?? 0, reasoningOutputTokens: 0)
            // Claude emits synthetic assistant envelopes with an empty usage
            // object. They are not provider usage and should not inflate event,
            // session, or unpriced-model counts.
            guard usageValue.totalTokens > 0 else { return }
            let agentID = line.string(forKey: ClaudeJSON.agentID) ?? fileSubagentID
            let isSubagent = line.bool(forKey: ClaudeJSON.isSidechain) || agentID != nil || fileIsSubagent
            let effectiveSessionID = agentID.map { "agent:\($0)" } ?? sessionID
            // If Claude omits an agent ID and does not place the record under a
            // subagents path, the exact child identity is unknowable. Keep the
            // main and sidechain streams distinct rather than dropping one when
            // they reuse a message ID, while retaining the parent link.
            let streamKind = isSubagent ? "sidechain" : "main"
            let identityKey = "\(effectiveSessionID):\(streamKind)"
            let parentAttribution = resolver.attribution(for: sessionID) ?? resolver.defaultAttribution
            let attributionConfidence: AttributionConfidence
            let attributionBasis: AttributionBasis
            if parentAttribution.confidence == .ambiguousAccount {
                attributionConfidence = .ambiguousAccount
                attributionBasis = .claudeAccountConflict
            } else if isSubagent && agentID == nil {
                attributionConfidence = .ambiguousSidechain
                attributionBasis = .parentSession
            } else if isSubagent {
                attributionConfidence = .parentSession
                attributionBasis = .parentSession
            } else {
                attributionConfidence = parentAttribution.confidence
                attributionBasis = parentAttribution.basis
            }
            let event = UsageEvent(id: "claude:\(source.id):\(url.path):\(identityKey):\(messageID)", providerEventID: messageID, provider: .claude, sourceID: source.id, accountID: parentAttribution.accountID, attributionConfidence: attributionConfidence, attributionBasis: attributionBasis, sessionID: effectiveSessionID, parentSessionID: isSubagent ? sessionID : nil, timestamp: timestamp, model: line.string(forKey: ClaudeJSON.model) ?? "unknown", sourcePath: url.path, byteOffset: offset, isSubagent: isSubagent, usage: usageValue)
            let dedupeKey = "\(identityKey):\(messageID)"
            if let old = latestByMessage[dedupeKey], old.timestamp > event.timestamp || (old.timestamp == event.timestamp && old.byteOffset >= event.byteOffset) { return }
            latestByMessage[dedupeKey] = event
        }
        for event in latestByMessage.values where interval?.contains(event.timestamp) ?? true {
            if compact { rollups?.append(event) } else { result.events.append(event) }
        }
        if let rollups { result.events = rollups.values }
        result.warnings.append(contentsOf: stream.warnings)
        result.bytesRead = max(0, stream.bytes - startOffset)
        result.endOffset = stream.completeBytes
        return result
    }

    private static func subagentID(from url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.lastIndex(of: "subagents"), index + 1 < components.count else { return nil }
        let filename = URL(fileURLWithPath: components[index + 1]).deletingPathExtension().lastPathComponent
        return filename.isEmpty ? nil : filename
    }
}

private enum ClaudeJSON {
    static let type = Array(#""type""#.utf8)
    static let assistant = Array(#"assistant"#.utf8)
    static let assistantMarker = Array(#""type":"assistant""#.utf8)
    static let usage = Array(#""usage""#.utf8)
    static let id = Array(#""id""#.utf8)
    static let model = Array(#""model""#.utf8)
    static let sessionID = Array(#""sessionId""#.utf8)
    static let timestamp = Array(#""timestamp""#.utf8)
    static let agentID = Array(#""agentId""#.utf8)
    static let isSidechain = Array(#""isSidechain""#.utf8)
    static let inputTokens = Array(#""input_tokens""#.utf8)
    static let cacheReadInputTokens = Array(#""cache_read_input_tokens""#.utf8)
    static let cacheCreationInputTokens = Array(#""cache_creation_input_tokens""#.utf8)
    static let ephemeral5mInputTokens = Array(#""ephemeral_5m_input_tokens""#.utf8)
    static let ephemeral1hInputTokens = Array(#""ephemeral_1h_input_tokens""#.utf8)
    static let outputTokens = Array(#""output_tokens""#.utf8)
}

struct ClaudeAccountResolver {
    private var sessionAttributions: [String: ClaudeAccountAttribution] = [:]
    let defaultAttribution: ClaudeAccountAttribution

    init(root: URL) {
        var mapping: [String: ClaudeAccountAttribution] = [:]
        var telemetryCandidates: [String: Set<String>] = [:]
        var supportCandidates: [String: Set<String>] = [:]
        let telemetry = root.appendingPathComponent("telemetry", isDirectory: true)
        if let files = FileManager.default.enumerator(at: telemetry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let telemetryFiles = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            for url in telemetryFiles {
                guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data), let dict = JSONValue.dictionary(object) else { continue }
                let event = JSONValue.dictionary(dict["event_data"]) ?? dict
                let auth = JSONValue.dictionary(event["auth"])
                guard let session = JSONValue.string(event, "session_id"), let account = JSONValue.string(auth ?? [:], "account_uuid") else { continue }
                telemetryCandidates[session, default: []].insert(account)
            }
        }

        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL.path
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        if root.standardizedFileURL.path == defaultRoot, let accounts = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for accountURL in accounts.sorted(by: { $0.path < $1.path }) {
                let account = accountURL.lastPathComponent
                guard let organizations = try? FileManager.default.contentsOfDirectory(at: accountURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for organizationURL in organizations.sorted(by: { $0.path < $1.path }) {
                    guard let files = try? FileManager.default.contentsOfDirectory(at: organizationURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                    for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
                        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data), let dict = JSONValue.dictionary(object), let cliID = JSONValue.string(dict, "cliSessionId") else { continue }
                        supportCandidates[cliID, default: []].insert(account)
                    }
                }
            }
        }

        for session in Set(telemetryCandidates.keys).union(supportCandidates.keys) {
            if let telemetry = telemetryCandidates[session] {
                var candidates = telemetry
                candidates.formUnion(supportCandidates[session] ?? [])
                mapping[session] = ClaudeAccountAttribution.fromCandidates(candidates, basis: .claudeTelemetry)
            } else if let support = supportCandidates[session] {
                mapping[session] = ClaudeAccountAttribution.fromCandidates(support, basis: .claudeSupportSession)
            }
        }
        sessionAttributions = mapping

        let config = root.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: config), let object = try? JSONSerialization.jsonObject(with: data), let dict = JSONValue.dictionary(object), JSONValue.string(dict, "userID") != nil {
            defaultAttribution = ClaudeAccountAttribution(accountID: "unattributed", confidence: .currentConfigOnly, basis: .claudeCurrentConfig)
        } else {
            defaultAttribution = ClaudeAccountAttribution(accountID: "unattributed", confidence: .sourceOnly, basis: .none)
        }
    }

    func attribution(for session: String) -> ClaudeAccountAttribution? { sessionAttributions[session] }
}

struct ClaudeAccountAttribution {
    let accountID: String
    let confidence: AttributionConfidence
    let basis: AttributionBasis

    static func fromCandidates(_ candidates: Set<String>, basis: AttributionBasis) -> ClaudeAccountAttribution {
        guard candidates.count == 1, let accountID = candidates.first else {
            return ClaudeAccountAttribution(accountID: "ambiguous", confidence: .ambiguousAccount, basis: .claudeAccountConflict)
        }
        return ClaudeAccountAttribution(accountID: accountID, confidence: .sessionVerified, basis: basis)
    }
}
