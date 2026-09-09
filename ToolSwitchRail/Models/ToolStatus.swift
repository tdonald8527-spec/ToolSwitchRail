import SwiftUI
import AppKit
import Foundation

enum AgentTaskStatus: String, Equatable {
    case unknown
    case idle
    case working
    case needsInput
    case needsApproval
    case completed
    case error

    var needsYou: Bool {
        self == .needsInput || self == .needsApproval
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "Unknown"
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs Input"
        case .needsApproval: return "Needs Approval"
        case .completed: return "Completed"
        case .error: return "Error"
        }
    }

    var dotColor: Color {
        switch self {
        case .unknown:
            return Color.primary.opacity(0.22)
        case .idle:
            return Color(red: 0.55, green: 0.58, blue: 0.62)
        case .working:
            return Color(red: 0.20, green: 0.72, blue: 0.45)
        case .needsInput:
            return Color(red: 0.98, green: 0.72, blue: 0.16)
        case .needsApproval:
            return Color(red: 0.98, green: 0.48, blue: 0.18)
        case .completed:
            return Color(red: 0.35, green: 0.78, blue: 0.55)
        case .error:
            return Color(red: 0.92, green: 0.28, blue: 0.28)
        }
    }
}

struct ToolStatusSnapshot: Equatable {
    var toolID: String
    var status: AgentTaskStatus
    var taskTitle: String?
    var usageText: String?
    var sourceReliable: Bool

    init(
        toolID: String,
        status: AgentTaskStatus,
        taskTitle: String?,
        usageText: String?,
        sourceReliable: Bool
    ) {
        let guarded = StatusReliabilityGuard.normalize(
            toolID: toolID,
            proposedStatus: status,
            proposedReliable: sourceReliable
        )
        self.toolID = toolID
        self.status = guarded.status
        self.taskTitle = taskTitle
        self.usageText = usageText
        self.sourceReliable = guarded.sourceReliable
    }

    static func unknown(toolID: String) -> ToolStatusSnapshot {
        ToolStatusSnapshot(
            toolID: toolID,
            status: .unknown,
            taskTitle: nil,
            usageText: nil,
            sourceReliable: false
        )
    }
}

/// Conservative guardrail for status sources that can otherwise leak stale or cross-app state.
/// It does not change UI, window switching, configuration, or any other Agent probe.
private enum StatusReliabilityGuard {
    static func normalize(
        toolID: String,
        proposedStatus: AgentTaskStatus,
        proposedReliable: Bool
    ) -> (status: AgentTaskStatus, sourceReliable: Bool) {
        let key = toolID.lowercased()

        if key == "chatgpt" || key == "chatgpt-mac" {
            // ChatGPT Mac must never inherit Codex log activity. Until a dedicated
            // ChatGPT status source exists, only report a trustworthy online/idle state.
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").isEmpty
            return running ? (.idle, true) : (.unknown, false)
        }

        if key == "codex" {
            // The existing Codex probe reads com.openai.codex logs. Do not let the
            // separate ChatGPT process make a stale Codex log look active.
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
            return running ? (proposedStatus, proposedReliable) : (.unknown, false)
        }

        if key == "workbuddy" || key == "work-buddy" {
            return workBuddyState()
        }

        return (proposedStatus, proposedReliable)
    }

    private static func workBuddyState() -> (status: AgentTaskStatus, sourceReliable: Bool) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.workbuddy.mac").first else {
            // Local files can outlive the process. Never surface stale Working / Approval
            // after WorkBuddy itself is no longer running.
            return (.idle, false)
        }

        let fm = FileManager.default
        let wbDir = NSHomeDirectory() + "/.workbuddy"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayLogDir = wbDir + "/logs/" + formatter.string(from: Date())
        let launchDate = app.launchDate ?? Date().addingTimeInterval(-24 * 60 * 60)

        guard let names = try? fm.contentsOfDirectory(atPath: todayLogDir) else {
            return (.idle, true)
        }

        struct LogFile {
            var path: String
            var name: String
            var modified: Date
        }

        var logs: [LogFile] = []
        for name in names where name.hasSuffix(".log") {
            let path = todayLogDir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified >= launchDate.addingTimeInterval(-2) else { continue }
            logs.append(LogFile(path: path, name: name, modified: modified))
        }

        guard !logs.isEmpty else {
            return (.idle, true)
        }

        // A workspace log is where run/approval lifecycle events are emitted. Parse
        // only the newest workspace log and apply events in chronological line order.
        if let workspace = logs
            .filter({ $0.name.contains("__") })
            .max(by: { $0.modified < $1.modified }),
           let text = tailText(path: workspace.path, bytes: 64 * 1024) {
            var state: AgentTaskStatus = .idle
            var sawLifecycleEvent = false

            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.lowercased()
                if line.isEmpty { continue }

                if isRunEnded(line) {
                    state = line.contains("fail") || line.contains("error") ? .error : .idle
                    sawLifecycleEvent = true
                    continue
                }

                if line.contains("runid=(none)") || line.contains("runid=null") || line.contains("runid=none") {
                    state = .idle
                    sawLifecycleEvent = true
                    continue
                }

                if isApprovalResolved(line) {
                    // Resolution means the old approval request is no longer pending.
                    state = .working
                    sawLifecycleEvent = true
                    continue
                }

                if isApprovalRequested(line) {
                    state = .needsApproval
                    sawLifecycleEvent = true
                    continue
                }

                if hasActiveRunID(line) {
                    state = .working
                    sawLifecycleEvent = true
                }
            }

            if sawLifecycleEvent {
                // Needs Approval is intentionally sticky until a later lifecycle event
                // resolves it. Working is not: if the workspace log has gone quiet,
                // prefer Idle rather than displaying a stale active state indefinitely.
                if state == .working && Date().timeIntervalSince(workspace.modified) > 30 {
                    return (.idle, true)
                }
                return (state, true)
            }
        }

        // Fallback for builds whose workspace log does not expose lifecycle markers:
        // very recent runtime log activity can indicate Working, but expires quickly.
        let activityNames = ["sdk", "conversations", "workbuddymainthread"]
        if let latestActivity = logs
            .filter({ log in activityNames.contains(where: { log.name.lowercased().contains($0) }) })
            .max(by: { $0.modified < $1.modified }),
           Date().timeIntervalSince(latestActivity.modified) < 4.0 {
            return (.working, true)
        }

        return (.idle, true)
    }

    private static func tailText(path: String, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let readLength = min(size, bytes)
        handle.seek(toFileOffset: size - readLength)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func hasActiveRunID(_ line: String) -> Bool {
        guard let range = line.range(of: "runid=") else { return false }
        let suffix = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty { return false }
        return !suffix.hasPrefix("(none)") && !suffix.hasPrefix("none") && !suffix.hasPrefix("null")
    }

    private static func isApprovalRequested(_ line: String) -> Bool {
        if line.contains("needsapproval=false") || line.contains("requireapproval=false") {
            return false
        }
        return line.contains("needsapproval")
            || line.contains("requireapproval")
            || line.contains("approvalrequested")
            || line.contains("approval requested")
            || line.contains("requestapproval")
    }

    private static func isApprovalResolved(_ line: String) -> Bool {
        guard line.contains("approval") else { return false }
        let resolvedMarkers = [
            "approved", "rejected", "resolved", "dismissed", "cancelled", "canceled",
            "approvalresult", "approval result", "approvalcompleted", "approval completed",
            "needsapproval=false", "requireapproval=false"
        ]
        return resolvedMarkers.contains(where: { line.contains($0) })
    }

    private static func isRunEnded(_ line: String) -> Bool {
        let endMarkers = [
            "run completed", "run finished", "run ended", "run stopped",
            "run cancelled", "run canceled", "run failed", "run error"
        ]
        return endMarkers.contains(where: { line.contains($0) })
    }
}

struct NeedsYouItem: Identifiable, Equatable {
    var id: String
    var toolID: String
    var toolName: String
    var status: AgentTaskStatus
    var taskTitle: String?
}

struct AgentQuotaItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var subDetails: [String] = []
}
