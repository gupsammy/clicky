//
//  CodexAgentClient.swift
//  leanring-buddy
//
//  Safe thread and turn operations layered on the Codex app-server client.
//

import Foundation

extension CodexAppServerClient {
    func startThread(
        in workspace: CodexAgentWorkspace,
        model: String? = nil,
        developerInstructions: String? = nil,
        ephemeral: Bool = false
    ) async throws -> CodexThreadStartResponse {
        try await sendRequest(
            method: "thread/start",
            parameters: CodexThreadStartParameters(
                cwd: workspace.path,
                approvalPolicy: .onRequest,
                approvalsReviewer: .user,
                sandbox: .workspaceWrite,
                ephemeral: ephemeral,
                model: normalizedOptionalValue(model),
                developerInstructions: normalizedOptionalValue(developerInstructions)
            )
        )
    }

    func resumeThread(
        threadID: String,
        in workspace: CodexAgentWorkspace,
        model: String? = nil
    ) async throws -> CodexThreadResumeResponse {
        try await sendRequest(
            method: "thread/resume",
            parameters: CodexThreadResumeParameters(
                threadId: threadID,
                cwd: workspace.path,
                approvalPolicy: .onRequest,
                approvalsReviewer: .user,
                sandbox: .workspaceWrite,
                model: normalizedOptionalValue(model)
            )
        )
    }

    func listThreads(
        in workspace: CodexAgentWorkspace,
        cursor: String? = nil,
        archived: Bool = false
    ) async throws -> CodexThreadListResponse {
        try await sendRequest(
            method: "thread/list",
            parameters: CodexThreadListParameters(
                cwd: [workspace.path],
                cursor: cursor,
                limit: 50,
                archived: archived,
                sortKey: "updated_at",
                sortDirection: "desc"
            )
        )
    }

    func readThread(
        threadID: String,
        in workspace: CodexAgentWorkspace,
        includeTurns: Bool = true
    ) async throws -> CodexThreadReadResponse {
        let threadReadResponse: CodexThreadReadResponse = try await sendRequest(
            method: "thread/read",
            parameters: CodexThreadReadParameters(
                threadId: threadID,
                includeTurns: includeTurns
            )
        )

        // thread/read has no server-side workspace filter (unlike thread/list),
        // so enforce the "history is scoped to the selected Agent Folder"
        // guarantee here instead of trusting every caller to only pass thread
        // IDs obtained from a scoped listThreads call. Both paths are resolved
        // because Codex may report the same directory through a different
        // symlink spelling (e.g. /tmp vs /private/tmp on macOS).
        let workspaceDirectoryPath = URL(fileURLWithPath: workspace.path)
            .resolvingSymlinksInPath().path
        let threadDirectoryPath = URL(fileURLWithPath: threadReadResponse.thread.cwd)
            .resolvingSymlinksInPath().path
        guard threadDirectoryPath == workspaceDirectoryPath else {
            throw CodexAppServerError.threadOutsideWorkspace(
                threadID: threadID,
                workspacePath: workspace.path
            )
        }

        return threadReadResponse
    }

    func startTurn(
        threadID: String,
        prompt: String,
        in workspace: CodexAgentWorkspace,
        model: String? = nil,
        reasoningEffort: String? = nil,
        clientUserMessageID: String = UUID().uuidString
    ) async throws -> CodexTurnStartResponse {
        let normalizedPrompt = try normalizedPrompt(prompt)

        return try await sendRequest(
            method: "turn/start",
            parameters: CodexTurnStartParameters(
                threadId: threadID,
                input: [CodexTextUserInput(text: normalizedPrompt)],
                cwd: workspace.path,
                approvalPolicy: .onRequest,
                approvalsReviewer: .user,
                sandboxPolicy: CodexWorkspaceWriteSandboxPolicy(
                    writableRoots: [workspace.path]
                ),
                model: normalizedOptionalValue(model),
                effort: normalizedOptionalValue(reasoningEffort),
                clientUserMessageId: clientUserMessageID
            )
        )
    }

    func steerTurn(
        threadID: String,
        expectedTurnID: String,
        prompt: String,
        clientUserMessageID: String = UUID().uuidString
    ) async throws -> CodexTurnSteerResponse {
        let normalizedPrompt = try normalizedPrompt(prompt)

        return try await sendRequest(
            method: "turn/steer",
            parameters: CodexTurnSteerParameters(
                threadId: threadID,
                expectedTurnId: expectedTurnID,
                input: [CodexTextUserInput(text: normalizedPrompt)],
                clientUserMessageId: clientUserMessageID
            )
        )
    }

    func interruptTurn(
        threadID: String,
        turnID: String
    ) async throws {
        let _: CodexEmptyParameters = try await sendRequest(
            method: "turn/interrupt",
            parameters: CodexTurnInterruptParameters(
                threadId: threadID,
                turnId: turnID
            )
        )
    }

    private func normalizedPrompt(_ prompt: String) throws -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw CodexAppServerError.emptyAgentPrompt
        }
        return normalizedPrompt
    }

    private func normalizedOptionalValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedValue.isEmpty ? nil : normalizedValue
    }
}
