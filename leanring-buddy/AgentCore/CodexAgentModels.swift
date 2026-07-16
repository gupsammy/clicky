//
//  CodexAgentModels.swift
//  leanring-buddy
//
//  Stable thread and turn contracts used by Clicky's durable agent lane.
//

import Foundation

struct CodexAgentWorkspace: Equatable, Sendable {
    let directoryURL: URL

    init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let resolvedDirectoryURL = directoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(
            atPath: resolvedDirectoryURL.path,
            isDirectory: &isDirectory
        )

        guard resolvedDirectoryURL.isFileURL,
              resolvedDirectoryURL.path.hasPrefix("/"),
              directoryExists,
              isDirectory.boolValue else {
            throw CodexAppServerError.invalidAgentWorkspace(path: directoryURL.path)
        }

        self.directoryURL = resolvedDirectoryURL
    }

    var path: String {
        directoryURL.path
    }
}

enum CodexApprovalPolicy: String, Codable, Equatable, Sendable {
    case onRequest = "on-request"
    case never
}

enum CodexApprovalsReviewer: String, Codable, Equatable, Sendable {
    case user
}

enum CodexSandboxMode: String, Codable, Equatable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
}

struct CodexModelListParameters: Encodable, Equatable, Sendable {
    let cursor: String?
    let includeHidden: Bool?
    let limit: Int?

    init(
        cursor: String? = nil,
        includeHidden: Bool? = false,
        limit: Int? = nil
    ) {
        self.cursor = cursor
        self.includeHidden = includeHidden
        self.limit = limit
    }
}

struct CodexModel: Codable, Equatable, Sendable {
    let id: String
    let model: String
    let isDefault: Bool
}

struct CodexModelListResponse: Codable, Equatable, Sendable {
    let data: [CodexModel]
    let nextCursor: String?
}

struct CodexThreadStartParameters: Encodable, Equatable, Sendable {
    let cwd: String
    let approvalPolicy: CodexApprovalPolicy
    let approvalsReviewer: CodexApprovalsReviewer
    let sandbox: CodexSandboxMode
    let ephemeral: Bool
    let model: String?
    let developerInstructions: String?
}

struct CodexThreadResumeParameters: Encodable, Equatable, Sendable {
    let threadId: String
    let cwd: String
    let approvalPolicy: CodexApprovalPolicy
    let approvalsReviewer: CodexApprovalsReviewer
    let sandbox: CodexSandboxMode
    let model: String?
}

struct CodexThreadListParameters: Encodable, Equatable, Sendable {
    let cwd: [String]
    let cursor: String?
    let limit: Int?
    let archived: Bool?
    let sortKey: String
    let sortDirection: String
}

struct CodexThreadReadParameters: Encodable, Equatable, Sendable {
    let threadId: String
    let includeTurns: Bool
}

struct CodexThreadStatus: Codable, Equatable, Sendable {
    let type: String
    let activeFlags: [String]?
}

enum CodexTurnStatus: Codable, Equatable, Sendable {
    case completed
    case interrupted
    case failed
    case inProgress
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case "completed":
            self = .completed
        case "interrupted":
            self = .interrupted
        case "failed":
            self = .failed
        case "inProgress":
            self = .inProgress
        default:
            self = .unknown(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .completed:
            try container.encode("completed")
        case .interrupted:
            try container.encode("interrupted")
        case .failed:
            try container.encode("failed")
        case .inProgress:
            try container.encode("inProgress")
        case .unknown(let rawValue):
            try container.encode(rawValue)
        }
    }
}

struct CodexTurnError: Codable, Equatable, Sendable {
    let message: String
    let additionalDetails: String?
    let codexErrorInfo: CodexJSONValue?
}

struct CodexTurn: Codable, Equatable, Sendable {
    let id: String
    let status: CodexTurnStatus
    let items: [CodexJSONValue]
    let startedAt: Int64?
    let completedAt: Int64?
    let durationMs: Int64?
    let error: CodexTurnError?
}

struct CodexThread: Codable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let preview: String
    let name: String?
    let cwd: String
    let modelProvider: String
    let cliVersion: String
    let createdAt: Int64
    let updatedAt: Int64
    let ephemeral: Bool
    let status: CodexThreadStatus
    let turns: [CodexTurn]
}

struct CodexThreadStartResponse: Codable, Equatable, Sendable {
    let thread: CodexThread
    let model: String
    let modelProvider: String
    let cwd: String
    let approvalPolicy: CodexJSONValue
    let approvalsReviewer: String
    let sandbox: CodexJSONValue
    let reasoningEffort: String?
    let instructionSources: [String]?
}

typealias CodexThreadResumeResponse = CodexThreadStartResponse

struct CodexThreadListResponse: Codable, Equatable, Sendable {
    let data: [CodexThread]
    let nextCursor: String?
    let backwardsCursor: String?
}

struct CodexThreadReadResponse: Codable, Equatable, Sendable {
    let thread: CodexThread
}

struct CodexTextUserInput: Encodable, Equatable, Sendable {
    let type = "text"
    let text: String
}

struct CodexLocalImageUserInput: Encodable, Equatable, Sendable {
    let type = "localImage"
    let path: String
}

enum CodexUserInput: Encodable, Equatable, Sendable {
    case text(CodexTextUserInput)
    case localImage(CodexLocalImageUserInput)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let textInput):
            try textInput.encode(to: encoder)
        case .localImage(let localImageInput):
            try localImageInput.encode(to: encoder)
        }
    }
}

struct CodexWorkspaceWriteSandboxPolicy: Encodable, Equatable, Sendable {
    let type = "workspaceWrite"
    let writableRoots: [String]
    let networkAccess = false
    // Codex's workspace-write sandbox additionally treats /tmp and $TMPDIR as
    // writable unless they are explicitly excluded. Excluding both keeps the
    // effective writable set to exactly writableRoots (the selected Agent
    // Folder), matching the safety guarantee documented in AGENTS.md.
    let excludeSlashTmp = true
    let excludeTmpdirEnvVar = true
}

struct CodexReadOnlySandboxPolicy: Encodable, Equatable, Sendable {
    let type = "readOnly"
    let networkAccess = false
}

enum CodexTurnSandboxPolicy: Encodable, Equatable, Sendable {
    case readOnly(CodexReadOnlySandboxPolicy)
    case workspaceWrite(CodexWorkspaceWriteSandboxPolicy)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .readOnly(let readOnlyPolicy):
            try readOnlyPolicy.encode(to: encoder)
        case .workspaceWrite(let workspaceWritePolicy):
            try workspaceWritePolicy.encode(to: encoder)
        }
    }
}

struct CodexTurnStartParameters: Encodable, Equatable, Sendable {
    let threadId: String
    let input: [CodexUserInput]
    let cwd: String
    let approvalPolicy: CodexApprovalPolicy
    let approvalsReviewer: CodexApprovalsReviewer
    let sandboxPolicy: CodexTurnSandboxPolicy
    let model: String?
    let effort: String?
    let clientUserMessageId: String?
}

struct CodexTurnStartResponse: Codable, Equatable, Sendable {
    let turn: CodexTurn
}

struct CodexTurnSteerParameters: Encodable, Equatable, Sendable {
    let threadId: String
    let expectedTurnId: String
    let input: [CodexTextUserInput]
    let clientUserMessageId: String?
}

struct CodexTurnSteerResponse: Codable, Equatable, Sendable {
    let turnId: String
}

struct CodexTurnInterruptParameters: Encodable, Equatable, Sendable {
    let threadId: String
    let turnId: String
}

struct CodexTurnLifecycleNotification: Codable, Equatable, Sendable {
    let threadId: String
    let turn: CodexTurn
}

extension CodexAppServerNotification {
    func decodeParameters<Parameters: Decodable>(
        as parametersType: Parameters.Type
    ) throws -> Parameters {
        guard let params else {
            throw CodexAppServerError.malformedMessage
        }

        let encodedParameters = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(parametersType, from: encodedParameters)
    }
}
