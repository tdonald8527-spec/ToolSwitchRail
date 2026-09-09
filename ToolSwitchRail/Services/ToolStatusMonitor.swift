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
        if let wb = WorkBuddyStatusSource.readQuotaItem() {
            reports.append(wb)
        }
        if let gpt = ChatGPTStatusSource.readQuotaItem() {
            reports.append(gpt)
        }
        return reports
    }

    static func readSnapshot(for tool: ToolItem) -> ToolStatusSnapshot {
        let key = tool.id.lowercased()
        let bundle = (tool.bundleIdentifier ?? "").lowercased()

        if key == "hermes" || bundle == "com.nousresearch.hermes" {
            if let snap = HermesStatusSource.read(toolID: tool.id) {
                return snap
            }
        }
        if key == "antigravity" || bundle == "com.google.antigravity" {
            if let snap = AntigravityStatusSource.read(toolID: tool.id) {
                return snap
            }
        }
        if key == "grok-bot" || key == "grok" || bundle == "com.anysphere.sand" {
            if let snap = GrokBotStatusSource.read(toolID: tool.id) {
                return snap
            }
        }
        if key == "workbuddy" || key == "work-buddy" || bundle == "com.tencent.workbuddy.mac" {
            if let snap = WorkBuddyStatusSource.read(toolID: tool.id) {
                return snap
            }
        }
        if key == "codex" || key == "chatgpt" || bundle == "com.openai.codex" || bundle == "com.openai.chat" {
            if let snap = ChatGPTStatusSource.read(toolID: tool.id) {
                return snap
            }
        }

        // Generic fallback: If the tool app is running in macOS, report .idle rather than .unknown
        if let bundleID = tool.bundleIdentifier,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return ToolStatusSnapshot(
                toolID: tool.id,
                status: .idle,
                taskTitle: nil,
                usageText: nil,
                sourceReliable: true
            )
        }
        if let appName = tool.appName {
            let isRunning = NSWorkspace.shared.runningApplications.contains { app in
                app.localizedName?.lowercased() == appName.lowercased()
            }
            if isRunning {
                return ToolStatusSnapshot(
                    toolID: tool.id,
                    status: .idle,
                    taskTitle: nil,
                    usageText: nil,
                    sourceReliable: true
                )
            }
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

// MARK: - Base32 Helper

private enum Base32 {
    static func decodeToString(_ string: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let clean = string.uppercased().replacingOccurrences(of: "=", with: "")
        var bits = 0
        var bitCount = 0
        var bytes = [UInt8]()
        for char in clean {
            guard let val = alphabet.firstIndex(of: char) else { continue }
            bits = (bits << 5) | val
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((bits >> bitCount) & 0xFF))
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - Grok Bot

private enum GrokBotStatusSource {
    static func read(toolID: String) -> ToolStatusSnapshot? {
        let grokDir = NSHomeDirectory() + "/Library/Application Support/Grok Bot"
        let markerPath = grokDir + "/sand-session-marker.json"
        let isRunningApp = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anysphere.sand").isEmpty

        guard isRunningApp || FileManager.default.fileExists(atPath: markerPath) else {
            return nil
        }

        var isAlive = isRunningApp
        if let markerData = try? Data(contentsOf: URL(fileURLWithPath: markerPath)),
           let markerJSON = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any] {
            if let aliveAt = markerJSON["aliveAtMs"] as? Double {
                let nowMs = Date().timeIntervalSince1970 * 1000
                if (nowMs - aliveAt) < 45000 {
                    isAlive = true
                }
            }
            if !isAlive, let pid = markerJSON["pid"] as? pid_t, pid > 0 {
                if kill(pid, 0) == 0 {
                    isAlive = true
                }
            }
        }

        guard isAlive else {
            return ToolStatusSnapshot(toolID: toolID, status: .idle, taskTitle: nil, usageText: nil, sourceReliable: false)
        }

        let persistDir = grokDir + "/sand-client-persistence"
        let fm = FileManager.default
        var lastAgentID: String?
        var agentName: String?
        var isStreaming = false
        var isSending = false

        if let files = try? fm.contentsOfDirectory(atPath: persistDir) {
            var decodedMap: [(file: String, key: String)] = []
            for f in files where f.hasSuffix(".blob") {
                let raw = String(f.dropLast(5))
                if let key = Base32.decodeToString(raw) {
                    decodedMap.append((f, key))
                }
            }

            for item in decodedMap where item.key.contains("last-agent") {
                let path = persistDir + "/" + item.file
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let val = json["value"] as? [String: Any],
                   let aid = val["agentId"] as? String {
                    lastAgentID = aid
                    break
                }
            }

            if let aid = lastAgentID {
                for item in decodedMap where item.key.contains("last-roster") {
                    let path = persistDir + "/" + item.file
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let val = json["value"] as? [String: Any],
                       let rows = val["rows"] as? [[String: Any]] {
                        for r in rows where (r["id"] as? String) == aid {
                            agentName = r["name"] as? String
                            break
                        }
                    }
                    break
                }

                for item in decodedMap where item.key.contains("transcript.replicas." + aid) {
                    let path = persistDir + "/" + item.file
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let val = json["value"] as? [String: Any],
                       let entries = val["entries"] as? [[String: Any]],
                       let last = entries.last {
                        isStreaming = (last["isStreaming"] as? Bool) ?? false
                    }
                    break
                }
            }

            for item in decodedMap where item.key.contains("send-journal") {
                let path = persistDir + "/" + item.file
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let val = json["value"] as? [String: Any],
                   let records = val["records"] as? [Any] {
                    isSending = !records.isEmpty
                }
                break
            }
        }

        let status: AgentTaskStatus = (isStreaming || isSending) ? .working : .idle
        return ToolStatusSnapshot(
            toolID: toolID,
            status: status,
            taskTitle: agentName,
            usageText: nil,
            sourceReliable: true
        )
    }

    static func readQuotaItem() -> AgentQuotaItem? {
        let statusFile = NSHomeDirectory() + "/Library/Application Support/Grok Bot/desktop-status.json"
        guard FileManager.default.fileExists(atPath: statusFile),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statusFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let signedIn = json["signedIn"] as? Bool ?? false
        let version = json["appVersion"] as? String ?? ""
        var sub: [String] = []
        if let snap = read(toolID: "grok-bot"), let title = snap.taskTitle {
            sub.append("当前助手: \(title)")
        } else {
            sub.append("就绪在线")
        }
        return AgentQuotaItem(
            id: "grok-bot",
            title: "Grok Bot",
            detail: signedIn ? "xAI 桌面助手 · 已登录 (v\(version))" : "xAI 桌面助手 (v\(version))",
            subDetails: sub
        )
    }
}

// MARK: - WorkBuddy

private enum WorkBuddyStatusSource {
    static func read(toolID: String) -> ToolStatusSnapshot? {
        let isRunningApp = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.workbuddy.mac").isEmpty
        let wbDir = NSHomeDirectory() + "/.workbuddy"
        let sessDir = wbDir + "/sessions"
        let fm = FileManager.default

        guard isRunningApp || fm.fileExists(atPath: wbDir) else {
            return nil
        }

        var isAlive = isRunningApp
        let nowMs = Date().timeIntervalSince1970 * 1000

        if let files = try? fm.contentsOfDirectory(atPath: sessDir) {
            for f in files where f.hasSuffix(".json") {
                let path = sessDir + "/" + f
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let hb = json["lastHeartbeat"] as? Double,
                   (nowMs - hb) < 45000 {
                    isAlive = true
                    break
                }
            }
        }

        guard isAlive else {
            return ToolStatusSnapshot(toolID: toolID, status: .idle, taskTitle: nil, usageText: nil, sourceReliable: false)
        }

        var isWorking = false
        var needsApproval = false
        var taskTitle: String?

        // 1. Check latest artifact-index for latest task/file title
        let artDir = wbDir + "/artifact-index"
        if let artFiles = try? fm.contentsOfDirectory(atPath: artDir) {
            var bestDate: Date = .distantPast
            var bestPath: String?
            for f in artFiles where f.hasSuffix(".json") {
                let p = artDir + "/" + f
                if let attrs = try? fm.attributesOfItem(atPath: p),
                   let mod = attrs[.modificationDate] as? Date,
                   mod > bestDate {
                    bestDate = mod
                    bestPath = p
                }
            }
            if let bestPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: bestPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arts = json["artifacts"] as? [[String: Any]],
               let first = arts.first,
               let name = first["name"] as? String {
                taskTitle = name
            }
        }

        // 2. Check today's logs for activity
        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())
        let todayLogDir = wbDir + "/logs/" + todayStr

        if let logFiles = try? fm.contentsOfDirectory(atPath: todayLogDir) {
            let nowSec = Date().timeIntervalSince1970
            for f in logFiles where f.hasSuffix(".log") {
                let path = todayLogDir + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date else { continue }
                let modSec = mod.timeIntervalSince1970

                // If log was touched in last 3.5 seconds
                if (nowSec - modSec) < 3.5 {
                    if f.contains("sdk") || f.contains("conversations") || f.contains("workbuddyMainThread") {
                        isWorking = true
                    }
                }

                // Check tail of workspace log for runId or needsApproval
                if f.contains("__") {
                    if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
                        let size = handle.seekToEndOfFile()
                        let readLen = min(size, 4096)
                        handle.seek(toFileOffset: size - readLen)
                        let data = handle.readDataToEndOfFile()
                        if let text = String(data: data, encoding: .utf8) {
                            if text.contains("runId=") && !text.contains("runId=(none)") {
                                isWorking = true
                            }
                            if text.contains("needsApproval") || text.contains("requireApproval") {
                                needsApproval = true
                            }
                        }
                        try? handle.close()
                    }
                }
            }
        }

        let status: AgentTaskStatus
        if needsApproval {
            status = .needsApproval
        } else if isWorking {
            status = .working
        } else {
            status = .idle
        }

        return ToolStatusSnapshot(
            toolID: toolID,
            status: status,
            taskTitle: taskTitle,
            usageText: nil,
            sourceReliable: true
        )
    }

    static func readQuotaItem() -> AgentQuotaItem? {
        let wbDir = NSHomeDirectory() + "/.workbuddy"
        let sessDir = wbDir + "/sessions"
        let fm = FileManager.default
        var version = "2.132.0"

        if let files = try? fm.contentsOfDirectory(atPath: sessDir) {
            for f in files where f.hasSuffix(".json") {
                let path = sessDir + "/" + f
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let v = json["version"] as? String {
                    version = v
                    break
                }
            }
        }

        var sub: [String] = []
        if let snap = read(toolID: "workbuddy"), let title = snap.taskTitle {
            sub.append("最近产出: \(title)")
        } else {
            sub.append("就绪在线")
        }

        return AgentQuotaItem(
            id: "workbuddy",
            title: "WorkBuddy",
            detail: "腾讯云开发智能助手 · v\(version)",
            subDetails: sub
        )
    }
}

// MARK: - ChatGPT / Codex

private enum ChatGPTStatusSource {
    static func read(toolID: String) -> ToolStatusSnapshot? {
        let isRunningApp = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").isEmpty

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let today = formatter.string(from: Date())
        let logDir = NSHomeDirectory() + "/Library/Logs/com.openai.codex/" + today
        let fm = FileManager.default

        guard isRunningApp || fm.fileExists(atPath: logDir) else {
            return nil
        }

        guard isRunningApp else {
            return ToolStatusSnapshot(toolID: toolID, status: .idle, taskTitle: nil, usageText: nil, sourceReliable: false)
        }

        var isWorking = false
        var taskTitle: String?

        if let files = try? fm.contentsOfDirectory(atPath: logDir) {
            var bestDate: Date = .distantPast
            var bestFile: String?
            for f in files where f.hasSuffix(".log") {
                let path = logDir + "/" + f
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mod = attrs[.modificationDate] as? Date,
                   mod > bestDate {
                    bestDate = mod
                    bestFile = path
                }
            }

            if let bestFile, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: bestFile)) {
                let size = handle.seekToEndOfFile()
                let readLen = min(size, 8192)
                handle.seek(toFileOffset: size - readLen)
                let data = handle.readDataToEndOfFile()
                if let text = String(data: data, encoding: .utf8) {
                    let lines = text.components(separatedBy: "\n")
                    var lastStarted = -1
                    var lastCompleted = -1
                    for (i, line) in lines.enumerated() {
                        if line.contains("chatgpt_conversation_refetch_started") {
                            lastStarted = i
                        } else if line.contains("chatgpt_conversation_refetch_completed") {
                            lastCompleted = i
                        }
                        if line.contains("conversationId=") {
                            for part in line.components(separatedBy: " ") {
                                if part.hasPrefix("conversationId=") {
                                    let cid = String(part.dropFirst("conversationId=".count))
                                    if cid != "null" && !cid.isEmpty {
                                        taskTitle = "会话 " + String(cid.prefix(8))
                                    }
                                }
                            }
                        }
                    }
                    let timeSinceMod = Date().timeIntervalSince(bestDate)
                    if lastStarted > lastCompleted && timeSinceMod < 12 {
                        isWorking = true
                    }
                }
                try? handle.close()
            }
        }

        let status: AgentTaskStatus = isWorking ? .working : .idle
        return ToolStatusSnapshot(
            toolID: toolID,
            status: status,
            taskTitle: taskTitle,
            usageText: nil,
            sourceReliable: true
        )
    }

    static func readQuotaItem() -> AgentQuotaItem? {
        var sub: [String] = []
        if let snap = read(toolID: "codex"), let title = snap.taskTitle {
            sub.append("最近: \(title)")
        } else {
            sub.append("就绪在线")
        }
        return AgentQuotaItem(
            id: "codex",
            title: "ChatGPT (Mac)",
            detail: "OpenAI 桌面助手 · Codex",
            subDetails: sub
        )
    }
}
