import Foundation

/// Conventional local provider roots for the personal desktop build.
///
/// The app deliberately checks only known provider locations; it never walks
/// the user's home directory looking for arbitrary JSONL files.
public enum ProviderRootDiscovery {
    public static func conventionalSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [UsageSource] {
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        var sources: [UsageSource] = []

        if isReadableDirectory(codex.path), isDirectory(codex.appendingPathComponent("sessions", isDirectory: true)) || isDirectory(codex.appendingPathComponent("archived_sessions", isDirectory: true)) {
            sources.append(UsageSource(displayName: "Codex · local", provider: .codex, rootPath: codex.path))
        }
        if isReadableDirectory(claude.path), isDirectory(claude.appendingPathComponent("projects", isDirectory: true)) {
            sources.append(UsageSource(displayName: "Claude Code · local", provider: .claude, rootPath: claude.path))
        }
        return sources
    }

    public static func isReadableDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return isDirectory(url) && FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
