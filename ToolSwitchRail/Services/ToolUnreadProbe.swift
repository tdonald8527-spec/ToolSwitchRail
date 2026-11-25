import CryptoKit
import Foundation
import SQLite3

/// Reads only each application's own persisted unread state.
///
/// A `nil` result means the source was unavailable, incomplete, or changed
/// schema. Callers should retain the last trusted value rather than inventing
/// or clearing a badge from an uncertain read.
enum ToolUnreadProbe {
    static func hasUnread(
        toolID: String,
        bundleIdentifier: String?,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool? {
        let key = toolID.lowercased()
        let bundle = (bundleIdentifier ?? "").lowercased()

        if key == "mac" || key == "workbuddy" || key == "work-buddy"
            || bundle == "com.tencent.workbuddy.mac" {
            return WorkBuddyUnreadSource.hasUnread(homeDirectory: homeDirectory)
        }

        if key == "codex" || bundle == "com.openai.codex" {
            return CodexUnreadSource.hasUnread(homeDirectory: homeDirectory)
        }

        if key == "sand" || key == "grok-bot" || key == "grok"
            || bundle == "com.anysphere.sand" {
            return GrokBotUnreadSource.hasUnread(homeDirectory: homeDirectory)
        }

        // DeepSeek Harness, Gemini, and Hark currently expose no stable local
        // conversation-read state. Unknown is safer than a guessed badge.
        return nil
    }
}

/// Applies successful probe results while preserving the last trusted value
/// across transient lock/file-rewrite failures.
struct ToolUnreadState {
    private(set) var unreadToolIDs: Set<String> = []

    mutating func update(with results: [String: Bool?]) -> Set<String> {
        for (toolID, result) in results {
            guard let result else { continue }
            if result {
                unreadToolIDs.insert(toolID)
            } else {
                unreadToolIDs.remove(toolID)
            }
        }
        return unreadToolIDs
    }
}

private enum WorkBuddyUnreadSource {
    static func hasUnread(homeDirectory: String) -> Bool? {
        let path = homeDirectory + "/.workbuddy/workbuddy.db"
        let sql = """
        SELECT EXISTS(
            SELECT 1
            FROM sessions
            WHERE unread > 0
              AND deleted_at IS NULL
              AND IFNULL(is_playground, 0) = 0
              AND status <> 'archived'
        )
        """
        guard let rows = ToolUnreadSQLite.query(path: path, sql: sql),
              let value = rows.first?.first else {
            return nil
        }
        return value == "1"
    }
}

private enum CodexUnreadSource {
    static func hasUnread(homeDirectory: String) -> Bool? {
        let home = homeDirectory + "/.codex"
        guard let stateData = try? Data(contentsOf: URL(fileURLWithPath: home + "/.codex-global-state.json")),
              let root = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let atom = root["electron-persisted-atom-state"] as? [String: Any],
              let readState = root["electron-thread-read-state-v1"] as? [String: Any],
              let unreadByIdentity = readState["unreadByIdentity"] as? [String: Any] else {
            return nil
        }

        guard let account = currentAccount(root: root, atom: atom),
              let identity = identityHash(account: account),
              let hosts = unreadByIdentity[identity] as? [String: Any] else {
            return nil
        }

        let unreadIDs = Set(hosts.values.flatMap { value -> [String] in
            (value as? [String]) ?? []
        })
        guard !unreadIDs.isEmpty else { return false }

        guard let threads = ToolUnreadSQLite.query(
                path: home + "/state_5.sqlite",
                sql: """
                SELECT id
                FROM threads
                WHERE creator_account_id = ?
                  AND creator_user_id = ?
                  AND archived = 0
                """,
                bind: { statement in
                    bindText(account.accountID, to: 1, in: statement)
                    bindText(account.userID, to: 2, in: statement)
                }
              ) else {
            return nil
        }

        let validThreadIDs = Set(threads.compactMap(\.first))
        return !unreadIDs.isDisjoint(with: validThreadIDs)
    }

    private static func identityHash(
        account: (accountID: String, userID: String)
    ) -> String? {
        let identityInput = ["chatgpt", account.accountID, account.userID]
        guard let data = try? JSONSerialization.data(
            withJSONObject: identityInput,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func currentAccount(
        root: [String: Any],
        atom: [String: Any]
    ) -> (accountID: String, userID: String)? {
        if let miniCache = atom["mini-style-cache"] as? [String: Any],
           let encoded = miniCache["key"] as? String,
           let data = encoded.data(using: .utf8),
           let account = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = accountValue(account) {
            return value
        }

        if let environment = root["environment-catalog-cache-v1"] as? [String: Any],
           let value = accountValue(environment) {
            return value
        }
        return nil
    }

    private static func accountValue(_ dictionary: [String: Any]) -> (accountID: String, userID: String)? {
        guard let accountID = dictionary["accountId"] as? String,
              let userID = dictionary["userId"] as? String,
              !accountID.isEmpty,
              !userID.isEmpty else {
            return nil
        }
        return (accountID, userID)
    }
}

private enum GrokBotUnreadSource {
    static func hasUnread(homeDirectory: String) -> Bool? {
        let directory = homeDirectory + "/Library/Application Support/Grok Bot/sand-client-persistence"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        var foundRoster = false
        for name in names where name.hasSuffix(".blob") {
            let path = directory + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["schemaVersion"] as? Int) == 4,
                  let value = root["value"] as? [String: Any],
                  let rows = value["rows"] as? [[String: Any]] else {
                continue
            }

            foundRoster = true
            for row in rows {
                let hidden = boolValue(row["isHiddenFromSidebar"])
                let removed = boolValue(row["isRemovedFromSidebar"])
                guard !hidden, !removed else { continue }

                let hasUnreadFlag = boolValue(row["hasUnread"])
                let unreadCount = intValue(row["unreadCount"])
                let unreadThreadCount = intValue(row["unreadThreadCount"])
                if hasUnreadFlag || unreadCount > 0 || unreadThreadCount > 0 {
                    return true
                }
            }
        }
        return foundRoster ? false : nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}

private enum ToolUnreadSQLite {
    static func query(
        path: String,
        sql: String,
        bind: ((OpaquePointer) -> Void)? = nil
    ) -> [[String]]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)

        var rows: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let count = Int(sqlite3_column_count(statement))
                var row: [String] = []
                row.reserveCapacity(count)
                for index in 0..<count {
                    if let text = sqlite3_column_text(statement, Int32(index)) {
                        row.append(String(cString: text))
                    } else {
                        row.append("")
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}

private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_text(
        statement,
        index,
        value,
        -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    )
}
