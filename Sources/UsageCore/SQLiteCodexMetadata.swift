import Foundation
import SQLite3

struct SQLiteCodexRow {
    let id: String?
    let rolloutPath: String?
    let model: String?
    let parentID: String?
    let isSubagent: Bool
}

struct SQLiteCodexMetadataResult {
    let rows: [SQLiteCodexRow]
    let complete: Bool
}

enum SQLiteCodexMetadata {
    static func read(from url: URL) -> SQLiteCodexMetadataResult {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            return SQLiteCodexMetadataResult(rows: [], complete: false)
        }
        defer { sqlite3_close(database) }
        let sql = "SELECT id, rollout_path, model, agent_path FROM threads WHERE rollout_path IS NOT NULL ORDER BY rollout_path, id, model, agent_path"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return SQLiteCodexMetadataResult(rows: [], complete: false) }
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteCodexRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let id = column(statement, 0)
            let path = column(statement, 1)
            let model = column(statement, 2)
            let agentPath = column(statement, 3)
            rows.append(SQLiteCodexRow(id: id, rolloutPath: path, model: model, parentID: nil, isSubagent: agentPath != nil))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return SQLiteCodexMetadataResult(rows: [], complete: false) }
        let edges = readEdges(from: database)
        let enriched = rows.map { row in
            SQLiteCodexRow(id: row.id, rolloutPath: row.rolloutPath, model: row.model, parentID: row.id.flatMap { edges[$0] }, isSubagent: row.isSubagent || row.id.map { edges[$0] != nil } == true)
        }
        return SQLiteCodexMetadataResult(rows: enriched, complete: true)
    }

    private static func readEdges(from database: OpaquePointer?) -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW, let parent = column(statement, 0), let child = column(statement, 1) { result[child] = parent }
        return result
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}
