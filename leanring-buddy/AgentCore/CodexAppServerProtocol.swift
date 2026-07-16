//
//  CodexAppServerProtocol.swift
//  leanring-buddy
//
//  Stable JSONL protocol types shared by the Codex app-server client and tests.
//

import Foundation

enum CodexJSONValue: Codable, Equatable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let booleanValue = try? container.decode(Bool.self) {
            self = .boolean(booleanValue)
        } else if let integerValue = try? container.decode(Int64.self) {
            self = .integer(integerValue)
        } else if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([CodexJSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: CodexJSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value from Codex app-server"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .object(let objectValue):
            try container.encode(objectValue)
        case .array(let arrayValue):
            try container.encode(arrayValue)
        case .string(let stringValue):
            try container.encode(stringValue)
        case .integer(let integerValue):
            try container.encode(integerValue)
        case .number(let numberValue):
            try container.encode(numberValue)
        case .boolean(let booleanValue):
            try container.encode(booleanValue)
        case .null:
            try container.encodeNil()
        }
    }
}

enum CodexAppServerRequestID: Codable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let integerValue = try? container.decode(Int64.self) {
            self = .integer(integerValue)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .integer(let integerValue):
            try container.encode(integerValue)
        case .string(let stringValue):
            try container.encode(stringValue)
        }
    }
}

struct CodexAppServerProtocolError: Codable, Equatable, Sendable {
    let code: Int
    let message: String
    let data: CodexJSONValue?
}

struct CodexAppServerIncomingMessage: Decodable, Sendable {
    let id: CodexAppServerRequestID?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let hasResult: Bool
    let error: CodexAppServerProtocolError?

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(CodexAppServerRequestID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(CodexJSONValue.self, forKey: .params)
        error = try container.decodeIfPresent(CodexAppServerProtocolError.self, forKey: .error)
        hasResult = container.contains(.result)
        result = hasResult
            ? try container.decode(CodexJSONValue.self, forKey: .result)
            : nil
    }
}

struct CodexAppServerOutgoingRequest<Parameters: Encodable>: Encodable {
    let method: String
    let id: CodexAppServerRequestID
    let params: Parameters
}

struct CodexAppServerOutgoingNotification<Parameters: Encodable>: Encodable {
    let method: String
    let params: Parameters
}

struct CodexAppServerOutgoingResponse<Result: Encodable>: Encodable {
    let id: CodexAppServerRequestID
    let result: Result
}

struct CodexAppServerOutgoingErrorResponse: Encodable {
    let id: CodexAppServerRequestID
    let error: CodexAppServerProtocolError
}

struct CodexEmptyParameters: Codable, Equatable, Sendable {}

struct CodexAppServerClientInfo: Codable, Equatable, Sendable {
    let name: String
    let title: String?
    let version: String
}

struct CodexAppServerInitializeCapabilities: Codable, Equatable, Sendable {
    let experimentalApi: Bool
    let optOutNotificationMethods: [String]?

    init(
        experimentalApi: Bool = false,
        optOutNotificationMethods: [String]? = nil
    ) {
        self.experimentalApi = experimentalApi
        self.optOutNotificationMethods = optOutNotificationMethods
    }
}

struct CodexAppServerInitializeParameters: Codable, Equatable, Sendable {
    let clientInfo: CodexAppServerClientInfo
    let capabilities: CodexAppServerInitializeCapabilities?
}

struct CodexAppServerInitializeResponse: Codable, Equatable, Sendable {
    let codexHome: String
    let platformFamily: String
    let platformOs: String
    let userAgent: String
}

struct CodexAppServerAccountReadParameters: Codable, Equatable, Sendable {
    let refreshToken: Bool

    init(refreshToken: Bool = false) {
        self.refreshToken = refreshToken
    }
}

struct CodexAppServerAccount: Codable, Equatable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct CodexAppServerAccountReadResponse: Codable, Equatable, Sendable {
    let account: CodexAppServerAccount?
    let requiresOpenaiAuth: Bool

    var isAuthenticated: Bool {
        account != nil
    }

    var isUsingChatGPTSubscription: Bool {
        account?.type == "chatgpt"
    }
}

struct CodexAppServerSession: Equatable, Sendable {
    let initialization: CodexAppServerInitializeResponse
    let account: CodexAppServerAccountReadResponse
}

struct CodexAppServerNotification: Equatable, Sendable {
    let method: String
    let params: CodexJSONValue?
}

struct CodexAppServerRequest: Equatable, Sendable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexJSONValue?
}

enum CodexAppServerConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case invalidAgentWorkspace(path: String)
    case emptyAgentPrompt
    case alreadyConnected
    case notConnected
    case malformedMessage
    case missingResponsePayload
    case requestTimedOut(method: String)
    case protocolFailure(code: Int, message: String)
    case processTerminated(exitCode: Int32, standardError: String)
    case threadOutsideWorkspace(threadID: String, workspacePath: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex could not be found. Install the Codex app or ChatGPT, or bundle the Codex executable with Clicky."
        case .invalidAgentWorkspace(let path):
            return "The selected Agent Folder is not an existing directory: \(path)"
        case .emptyAgentPrompt:
            return "An agent prompt cannot be empty."
        case .alreadyConnected:
            return "Clicky is already connected to Codex app-server."
        case .notConnected:
            return "Clicky is not connected to Codex app-server."
        case .malformedMessage:
            return "Codex app-server returned a malformed message."
        case .missingResponsePayload:
            return "Codex app-server returned a response without a result."
        case .requestTimedOut(let method):
            return "Codex app-server did not respond to \(method) in time."
        case .protocolFailure(_, let message):
            return message
        case .processTerminated(let exitCode, let standardError):
            let trimmedStandardError = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedStandardError.isEmpty {
                return "Codex app-server exited with status \(exitCode)."
            }
            return "Codex app-server exited with status \(exitCode): \(trimmedStandardError)"
        case .threadOutsideWorkspace(let threadID, let workspacePath):
            return "Thread \(threadID) does not belong to the selected Agent Folder: \(workspacePath)"
        }
    }
}

protocol CodexAppServerTransport: AnyObject {
    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (CodexAppServerError) -> Void
    ) throws

    func send(_ messageData: Data) throws
    func stop()
}
