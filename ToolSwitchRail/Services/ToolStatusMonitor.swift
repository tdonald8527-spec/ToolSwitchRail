import AppKit
import Foundation
import SQLite3

/// Polls local hooks / logs / SQLite / session files. Never uses the Accessibility tree.
@MainActor
final class ToolStatusMonitor: ObservableObject {
    @Published private(set) var snapshots: [String: ToolStatusSnapshot] = [:]
    @Published private(set) var needsYouItems: [NeedsYouItem] = []
    @Published private(set) var quotaReports: [AgentQuotaItem] = []

    private let configStore: ConfigStore
    private var timer: Timer?
    private var isRefreshing = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    deinit {
        timer?.invalidate()
    }

    func snapshot(for toolID: String) -> ToolStatusSnapshot {
        snapshots[toolID] ?? .unknown(toolID: toolID)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let tools = configStore.configuration.tools.filter(\.enabled)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var next: [String: ToolStatusSnapshot] = [:]
            for tool in tools {
                next[tool.id] = StatusProbe.readSnapshot(for: tool)
            }
            let items = StatusProbe.needsYouItems(from: next, tools: tools)
            let reports = StatusProbe.readQuotaReports()
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshots = next
                self.needsYouItems = items
                self.quotaReports = reports
                self.isRefreshing = false
            }
        }
    }
}

private enum StatusProbe {
    static func needsYouItems(from snapshots: [String: ToolStatusSnapshot], tools: [ToolItem]) -> [NeedsYouItem] {
        let names = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0.name) })
        return snapshots.values
            .filter { $0.status.needsYou }
            .sorted { lhs, rhs in
                if lhs.status == .needsApproval && rhs.status != .needsApproval { return true }
                if lhs.status != .needsApproval && rhs.status == .needsApproval { return false }
                return lhs.toolID < rhs.toolID
            }
            .map { snap in
                NeedsYouItem(
                    id: snap.toolID,
                    toolID: snap.toolID,
                    toolName: names[snap.toolID] ?? snap.toolID,
                    status: snap.status,
                    taskTitle: snap.taskTitle
                )
            }
    }

    static func readQuotaReports() -> [AgentQuotaItem] {
        var reports: [AgentQuotaItem] = []
        if let hermes = HermesStatusSource.readQuotaItem() {
            reports.append(hermes)
        }
        if let ag = AntigravityStatusSource.readQuotaItem() {
            reports.append(ag)
        }
        if let grok = GrokBotStatusSource.readQuotaItem() {
            reports.append(grok)
        }
        return reports
    }

    static func readSnapshot(for tool: ToolItem) -> ToolStatusSnapshot {
        let key = tool.id.lowercased()
        let bundle = (tool.bundleIdentifier ?? "").lowercased()
        if key == "hermes" || bundle == "com.nousresearch.hermes" {
            return HermesStatusSource.read(toolID: tool.id) ?? .unknown(toolID: tool.id)
        }
        if key == "antigravity" || bundle == "com.google.antigravity" {
            return AntigravityStatusSource.read(toolID: tool.id) ?? .unknown(toolID: tool.id)
        }
        return .unknown(toolID: tool.id)
    }
}

// MARK: - SQLite

private enum SQLiteRead {
    static func query(_ path: String, sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> [[String]] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        let walExists = FileManager.default.fileExists(atPath: path + "-wal")
        let uri = walExists ? "file:\(path)?mode=ro" : "file:\(path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 120)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cols = Int(sqlite3_column_count(stmt))
            var row: [String] = []
            for i in 0..<cols {
                if let cString = sqlite3_column_text(stmt, Int32(i)) {
                    row.append(String(cString: cString))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Hermes

private enum HermesStatusSource {
    static func read(toolID: String) -> ToolStatusSnapshot? {
        let home = NSHomeDirectory() + "/.hermes"
        let stateDB = home + "/state.db"
        guard FileManager.default.fileExists(atPath: stateDB) else { return nil }

        let now = Date().timeIntervalSince1970
        let leases = SQLiteRead.query(
            stateDB,
            sql: """
            SELECT conversation_id, holder, expires_at
            FROM session_turn_leases
            WHERE expires_at > ?
            """,
            bind: { stmt in
                sqlite3_bind_double(stmt, 1, now)
            }
        )

        let sessions = SQLiteRead.query(
            stateDB,
            sql: """
            SELECT id, source, title, last_activity_at, last_activity_description,
                   ended_at, estimated_cost_usd, input_tokens, output_tokens, cost_status
            FROM sessions
            WHERE IFNULL(archived, 0) = 0 AND IFNULL(hidden, 0) = 0
            ORDER BY last_activity_at DESC
            LIMIT 8
            """
        )
        guard !sessions.isEmpty || !leases.isEmpty else {
            // DB exists but no desktop sessions yet — still a reliable idle source.
            return ToolStatusSnapshot(
                toolID: toolID,
                status: .idle,
                taskTitle: nil,
                usageText: nil,
                sourceReliable: true
            )
        }

        let liveDesktopIDs: Set<String> = Set(leases.map { $0[0] }.filter { !$0.isEmpty })

        var bestStatus: AgentTaskStatus = .idle
        var bestTitle: String?
        var usageText: String?

        if let top = sessions.first {
            let sid = top[0]
            let title = top[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let activity = top[4]
            let ended = top[5]
            bestTitle = title.isEmpty ? nil : title

            let cost = Double(top[6]) ?? 0
            let inputTok = Int(top[7]) ?? 0
            let outputTok = Int(top[8]) ?? 0
            if inputTok + outputTok > 0 || cost > 0 {
                usageText = String(format: "tokens %d in / %d out · $%.3f", inputTok, outputTok, cost)
            }

            if liveDesktopIDs.contains(sid) || activity.contains("receiving stream") || activity.contains("tool") {
                bestStatus = .working
            } else if !ended.isEmpty {
                bestStatus = .completed
            } else {
                bestStatus = .idle
            }

            if let pending = pendingClarify(sessionID: sid, db: stateDB) {
                bestStatus = pending
            }
        } else if !liveDesktopIDs.isEmpty {
            bestStatus = .working
        }

        // Active lease on another desktop session still counts as Working unless this one needs you.
        if bestStatus != .needsInput && bestStatus != .needsApproval && !liveDesktopIDs.isEmpty {
            if bestStatus == .idle || bestStatus == .completed {
                bestStatus = .working
                if bestTitle == nil, let sid = liveDesktopIDs.first,
                   let match = sessions.first(where: { $0[0] == sid }) {
                    let title = match[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    bestTitle = title.isEmpty ? nil : title
                }
            }
        }

        if bestStatus != .needsInput && bestStatus != .needsApproval {
            for row in sessions {
                if let pending = pendingClarify(sessionID: row[0], db: stateDB) {
                    bestStatus = pending
                    let title = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    bestTitle = title.isEmpty ? bestTitle : title
                    break
                }
            }
        }

        return ToolStatusSnapshot(
            toolID: toolID,
            status: bestStatus,
            taskTitle: bestTitle,
            usageText: usageText,
            sourceReliable: true
        )
    }

    private static func pendingClarify(sessionID: String, db: String) -> AgentTaskStatus? {
        let rows = SQLiteRead.query(
            db,
            sql: """
            SELECT role, tool_name, content
            FROM messages
            WHERE session_id = ?
            ORDER BY id DESC
            LIMIT 12
            """,
            bind: { stmt in
                let ns = sessionID as NSString
                sqlite3_bind_text(stmt, 1, ns.utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        )
        for row in rows {
            let role = row[0]
            let tool = row[1]
            let content = row[2]
            if role == "user" {
                if content.hasPrefix("[IMPORTANT:") || content.hasPrefix("[System:") || content.hasPrefix("[CONTEXT") {
                    continue
                }
                return nil
            }
            if tool == "clarify" {
                return .needsInput
            }
            if role == "assistant" || role == "tool" {
                continue
            }
        }
        return nil
    }

    static func readQuotaItem() -> AgentQuotaItem? {
        let home = NSHomeDirectory() + "/.hermes"
        let authPath = home + "/auth.json"
        let stateDB = home + "/state.db"

        var tierText = "Nous"
        var spendText = "$0.00"
        var limitText = ""

        if let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
           let providers = authJSON["providers"] as? [String: Any],
           let nous = providers["nous"] as? [String: Any],
           let token = nous["access_token"] as? String,
           let payload = decodeJWTPayload(token) {
            if let tier = payload["subscription_tier"] as? Int {
                tierText = "Tier \(tier)"
            }
            if let spend = payload["member_spend_usd"] as? String, let s = Double(spend) {
                spendText = String(format: "$%.3f", s)
            }
            if let tpm = payload["rate_limit_tpm"] as? Int {
                limitText = " · TPM \(tpm / 1_000_000)M"
            }
        }

        var topModels: [String] = []
        if FileManager.default.fileExists(atPath: stateDB) {
            let rows = SQLiteRead.query(
                stateDB,
                sql: """
                SELECT model, SUM(input_tokens), SUM(output_tokens), SUM(estimated_cost_usd)
                FROM session_model_usage
                GROUP BY model
                ORDER BY SUM(estimated_cost_usd) DESC, SUM(input_tokens) DESC
                LIMIT 4
                """
            )
            for r in rows {
                let m = r[0].components(separatedBy: "/").last ?? r[0]
                let inTok = Int(r[1]) ?? 0
                let cost = Double(r[3]) ?? 0
                let inFormatted = inTok > 1_000_000 ? String(format: "%.1fM", Double(inTok) / 1_000_000.0) : "\(inTok / 1000)k"
                if cost > 0.001 {
                    topModels.append("\(m): \(inFormatted) tok · $\(String(format: "%.2f", cost))")
                } else if inTok > 0 {
                    topModels.append("\(m): \(inFormatted) tok (free)")
                }
            }
        }

        return AgentQuotaItem(
            id: "hermes",
            title: "Hermes Agent",
            detail: "\(tierText) · 已用 \(spendText)\(limitText)",
            subDetails: topModels
        )
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padLength = (4 - (base64.count % 4)) % 4
        base64.append(String(repeating: "=", count: padLength))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Antigravity

private enum AntigravityStatusSource {
    static func read(toolID: String) -> ToolStatusSnapshot? {
        let root = NSHomeDirectory() + "/.gemini/antigravity"
        let convDir = root + "/conversations"
        let annDir = root + "/annotations"
        guard FileManager.default.fileExists(atPath: convDir) else { return nil }

        let latest = latestConversation(in: convDir)
        guard let latest else {
            return ToolStatusSnapshot(
                toolID: toolID,
                status: .idle,
                taskTitle: nil,
                usageText: nil,
                sourceReliable: true
            )
        }

        let title = conversationTitle(id: latest.id, annotationsDir: annDir)
        let rows = SQLiteRead.query(
            latest.path,
            sql: "SELECT status FROM steps ORDER BY idx DESC LIMIT 1"
        )
        guard let statusRaw = rows.first?.first, let code = Int(statusRaw) else {
            return ToolStatusSnapshot(
                toolID: toolID,
                status: .idle,
                taskTitle: title,
                usageText: nil,
                sourceReliable: true
            )
        }

        let status: AgentTaskStatus
        switch code {
        case 7:
            status = .error
        case 3, 6:
            status = .idle
        default:
            status = .working
        }

        return ToolStatusSnapshot(
            toolID: toolID,
            status: status,
            taskTitle: title,
            usageText: nil,
            sourceReliable: true
        )
    }

    private struct ConversationFile {
        var id: String
        var path: String
        var modified: Date
    }

    private static func latestConversation(in dir: String) -> ConversationFile? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: ConversationFile?
        for name in names where name.hasSuffix(".db") && !name.contains("-shm") && !name.contains("-wal") {
            let path = dir + "/" + name
            let attrs = try? fm.attributesOfItem(atPath: path)
            let walAttrs = try? fm.attributesOfItem(atPath: path + "-wal")
            let m1 = attrs?[.modificationDate] as? Date ?? .distantPast
            let m2 = walAttrs?[.modificationDate] as? Date ?? .distantPast
            let modified = max(m1, m2)
            if best == nil || modified > best!.modified {
                best = ConversationFile(id: String(name.dropLast(3)), path: path, modified: modified)
            }
        }
        return best
    }

    private static func conversationTitle(id: String, annotationsDir: String) -> String? {
        let path = annotationsDir + "/" + id + ".pbtxt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let range = text.range(of: "title:\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let title = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func readQuotaItem() -> AgentQuotaItem? {
        let root = NSHomeDirectory() + "/.gemini/antigravity"
        let convDir = root + "/conversations"
        let annDir = root + "/annotations"
        guard FileManager.default.fileExists(atPath: convDir) else { return nil }

        let latest = latestConversation(in: convDir)
        let fm = FileManager.default
        let count = (try? fm.contentsOfDirectory(atPath: convDir).filter { $0.hasSuffix(".db") && !$0.contains("-wal") }.count) ?? 0

        var sub: [String] = []
        if let latest, let title = conversationTitle(id: latest.id, annotationsDir: annDir) {
            sub.append("最近会话: \(title)")
        }

        return AgentQuotaItem(
            id: "antigravity",
            title: "Antigravity",
            detail: "DeepMind Agent · \(count) 个任务会话",
            subDetails: sub
        )
    }
}

// MARK: - Grok Bot

private enum GrokBotStatusSource {
    static func readQuotaItem() -> AgentQuotaItem? {
        let statusFile = NSHomeDirectory() + "/Library/Application Support/Grok Bot/desktop-status.json"
        guard FileManager.default.fileExists(atPath: statusFile),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statusFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let signedIn = json["signedIn"] as? Bool ?? false
        let version = json["appVersion"] as? String ?? ""
        return AgentQuotaItem(
            id: "grok-bot",
            title: "Grok Bot",
            detail: signedIn ? "xAI 桌面助手 · 已登录 (v\(version))" : "xAI 桌面助手 (v\(version))",
            subDetails: ["就绪在线"]
        )
    }
}
