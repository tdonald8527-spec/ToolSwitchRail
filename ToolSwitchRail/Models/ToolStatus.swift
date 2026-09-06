import SwiftUI

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

struct NeedsYouItem: Identifiable, Equatable {
    var id: String
    var toolID: String
    var toolName: String
    var status: AgentTaskStatus
    var taskTitle: String?
}
