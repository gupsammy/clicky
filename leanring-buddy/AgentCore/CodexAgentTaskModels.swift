//
//  CodexAgentTaskModels.swift
//  leanring-buddy
//
//  UI-independent snapshots produced from streamed Codex agent events.
//

import Foundation

enum CodexAgentTaskStatus: String, Codable, Equatable, Sendable {
    case queued
    case idle
    case running
    case waitingForApproval
    case waitingForInput
    case completed
    case interrupted
    case failed

    var isTerminal: Bool {
        switch self {
        case .idle, .completed, .interrupted, .failed:
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
    case contextCompaction
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
    let requestedPermissions: CodexJSONValue?
}

enum CodexAgentApprovalDecision: String, Codable, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

struct CodexAgentApprovalDecisionResponse: Codable, Equatable, Sendable {
    let decision: CodexAgentApprovalDecision
}

enum CodexAgentPermissionGrantScope: String, Codable, Equatable, Sendable {
    case turn
    case session
}

struct CodexAgentPermissionsApprovalResponse: Codable, Equatable, Sendable {
    let permissions: CodexJSONValue
    let scope: CodexAgentPermissionGrantScope
}

struct CodexAgentUserInputOption: Codable, Equatable, Sendable {
    let label: String
    let description: String
}

struct CodexAgentUserInputQuestion: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let options: [CodexAgentUserInputOption]?
}

struct CodexAgentUserInputParameters: Codable, Equatable, Sendable {
    let threadId: String
    let turnId: String
    let itemId: String
    let questions: [CodexAgentUserInputQuestion]
    let autoResolutionMs: Int?
}

struct CodexAgentUserInputRequest: Codable, Equatable, Sendable {
    let requestID: CodexAppServerRequestID
    let threadID: String
    let turnID: String
    let itemID: String
    let questions: [CodexAgentUserInputQuestion]
    let autoResolutionMs: Int?
}

struct CodexAgentUserInputAnswer: Codable, Equatable, Sendable {
    let answers: [String]
}

struct CodexAgentUserInputResponse: Codable, Equatable, Sendable {
    let answers: [String: CodexAgentUserInputAnswer]
}

struct CodexAgentServerRequestResolvedNotification: Codable, Equatable, Sendable {
    let requestId: CodexAppServerRequestID
    let threadId: String
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
    let pendingUserInputs: [CodexAgentUserInputRequest]
    let errorMessage: String?
    let lastEventSequence: Int64
}

enum CodexAgentAttentionKind: Equatable, Sendable {
    case approval
    case userInput
}

struct CodexAgentAttentionRequest: Equatable, Sendable {
    let threadID: String
    let requestID: CodexAppServerRequestID
    let kind: CodexAgentAttentionKind
    let message: String

    var spokenAnnouncement: String {
        "The agent needs your attention."
    }
}

extension CodexAgentTaskSnapshot {
    var pendingAttentionRequest: CodexAgentAttentionRequest? {
        if status == .waitingForInput,
           let userInputRequest = pendingUserInputs.first,
           let question = userInputRequest.questions.first {
            return CodexAgentAttentionRequest(
                threadID: threadID,
                requestID: userInputRequest.requestID,
                kind: .userInput,
                message: question.question
            )
        }

        if status == .waitingForApproval,
           let approval = pendingApprovals.first {
            return CodexAgentAttentionRequest(
                threadID: threadID,
                requestID: approval.requestID,
                kind: .approval,
                message: "\(title) needs approval: \(approval.summary)"
            )
        }

        return nil
    }
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
