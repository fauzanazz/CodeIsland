import ActivityKit
import Foundation

struct CodeIslandSessionActivityPreview: Codable, Hashable, Identifiable {
    var sessionId: String?
    var source: String
    var status: String
    var toolName: String?
    var workspaceName: String?
    var message: String?
    var updatedAt: Date

    var id: String {
        sessionId ?? "\(source)-\(workspaceName ?? "session")-\(updatedAt.timeIntervalSince1970)"
    }

    var statusLabel: String {
        switch status {
        case "processing": return "Processing"
        case "running": return "Running"
        case "waitingApproval": return "Waiting for Approval"
        case "waitingQuestion": return "Waiting for Answer"
        default: return "Idle"
        }
    }

    var sourceLabel: String {
        source.isEmpty ? "CodeIsland" : source.uppercased()
    }
}

struct CodeIslandActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var sequence: UInt64
        var source: String
        var status: String
        var toolName: String?
        var workspaceName: String?
        var message: String?
        var pendingAction: String?
        var questionText: String?
        var questionHeader: String?
        var questionProgress: String?
        var sessions: [CodeIslandSessionActivityPreview]
        var updatedAt: Date

        var statusLabel: String {
            switch status {
            case "processing": return "Processing"
            case "running": return "Running"
            case "waitingApproval": return "Waiting for Approval"
            case "waitingQuestion": return "Waiting for Answer"
            default: return "Idle"
            }
        }

        var sourceLabel: String {
            source.isEmpty ? "CodeIsland" : source.uppercased()
        }

        var compactStatusLabel: String {
            switch status {
            case "waitingApproval": return "Approve"
            case "waitingQuestion": return "Answer"
            case "processing": return "Processing"
            case "running": return "Running"
            default: return "Idle"
            }
        }

        var activeSessionCount: Int {
            sessions.filter { $0.status != "idle" }.count
        }
    }

    var sessionId: String?
}
