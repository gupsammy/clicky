//
//  CodexAgentTaskModels.swift
//  leanring-buddy
//
//  UI-independent snapshots produced from streamed Codex agent events.
//

import Foundation

enum CodexAgentTaskStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case waitingForApproval
    case waitingForInput
    case completed
    case interrupted
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed:
            return true
        case .queued, .running, .waitingForApproval, .waitingForInput:
            return false
        }
    }
}

enum CodexAgentActivityKind: String, Codable, Equatable, Sendable {
    case command
    case fileChange
    case mcpTool
    case dynamicTool
    case collaboration
    case plan
    case reasoning
    case other
}

enum CodexAgentActivityStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case declined
}

struct CodexAgentActivity: Codable, Equatable, Sendable {
    let itemID: String
    let kind: CodexAgentActivityKind
    let summary: String
    let status: CodexAgentActivityStatus
}

struct CodexAgentApproval: Codable, Equatable, Sendable {
    let requestID: CodexAppServerRequestID
    let method: String
    let threadID: String
    let turnID: String
    let itemID: String
    let summary: String
    let reason: String?
    let workingDirectory: String?
}

struct CodexAgentTaskSnapshot: Codable, Equatable, Sendable {
    let threadID: String
    let turnID: String?
    let workspacePath: String
    let title: String
    let status: CodexAgentTaskStatus
    let latestAgentMessage: String
    let currentActivity: CodexAgentActivity?
    let activities: [CodexAgentActivity]
    let pendingApprovals: [CodexAgentApproval]
    let errorMessage: String?
    let lastEventSequence: Int64
}

struct CodexAgentMessageDeltaNotification: Codable, Equatable, Sendable {
    let threadId: String
    let turnId: String
    let itemId: String
    let delta: String
}

struct CodexAgentItemStartedNotification: Codable, Equatable, Sendable {
    let threadId: String
    let turnId: String
    let item: CodexJSONValue
    let startedAtMs: Int64
}

struct CodexAgentItemCompletedNotification: Codable, Equatable, Sendable {
    let threadId: String
    let turnId: String
    let item: CodexJSONValue
    let completedAtMs: Int64
}

struct CodexAgentServerRequestResolvedNotification: Codable, Equatable, Sendable {
    let requestId: CodexAppServerRequestID
    let threadId: String
}

struct CodexAgentThreadStatusChangedNotification: Codable, Equatable, Sendable {
    let threadId: String
    let status: CodexThreadStatus
}

extension CodexJSONValue {
    var objectValue: [String: CodexJSONValue]? {
        guard case .object(let objectValue) = self else { return nil }
        return objectValue
    }

    var arrayValue: [CodexJSONValue]? {
        guard case .array(let arrayValue) = self else { return nil }
        return arrayValue
    }

    var stringValue: String? {
        guard case .string(let stringValue) = self else { return nil }
        return stringValue
    }
}
