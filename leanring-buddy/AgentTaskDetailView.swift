//
//  AgentTaskDetailView.swift
//  leanring-buddy
//
//  Shared task detail used by the global notch and per-screen agent tokens.
//

import Foundation
import SwiftUI

struct AgentTaskDetailView: View {
    @ObservedObject var presentationModel: AgentPresentationModel

    var body: some View {
        if let task = presentationModel.selectedTask {
            VStack(spacing: 0) {
                taskHeader(task)
                Divider().overlay(DS.Colors.borderSubtle.opacity(0.65))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        resultCard(task)

                        if !task.pendingApprovals.isEmpty {
                            sectionTitle("APPROVAL NEEDED")
                            ForEach(task.pendingApprovals, id: \.requestID) { approval in
                                AgentApprovalCard(
                                    approval: approval,
                                    isBusy: presentationModel.isPerformingOperation,
                                    decisionAction: { decision in
                                        presentationModel.resolveApproval(
                                            approval,
                                            decision: decision
                                        )
                                    }
                                )
                            }
                        }


                        if !task.pendingUserInputs.isEmpty {
                            sectionTitle("INPUT NEEDED")
                            ForEach(task.pendingUserInputs, id: \.requestID) { request in
                                AgentUserInputCard(
                                    request: request,
                                    isBusy: presentationModel.isPerformingOperation,
                                    interactionAction: {
                                        presentationModel.snoozeAutomaticUserInputResolution(
                                            request
                                        )
                                    },
                                    submitAction: { answersByQuestionID in
                                        presentationModel.resolveUserInput(
                                            request,
                                            answersByQuestionID: answersByQuestionID
                                        )
                                    }
                                )
                            }
                        }

                        if !task.activities.isEmpty {
                            sectionTitle("ACTIVITY")
                            activityTimeline(task)
                        }

                        if task.pendingUserInputs.isEmpty {
                            followUpComposer(task)
                        }

                        if let operationErrorMessage = presentationModel.operationErrorMessage {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(DS.Colors.warning)
                                Text(operationErrorMessage)
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(2)
                                Spacer()
                                if presentationModel.canRetryConnection {
                                    Button("Reconnect", action: presentationModel.retryConnection)
                                        .font(.system(size: 10, weight: .semibold))
                                        .buttonStyle(.plain)
                                        .foregroundColor(DS.Colors.accentText)
                                        .pointerCursor()
                                }
                                Button(action: presentationModel.dismissOperationError) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(DS.Colors.textTertiary)
                                .pointerCursor()
                                .help("Dismiss error")
                                .accessibilityLabel("Dismiss error")
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DS.Colors.warning.opacity(0.08))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(DS.Colors.warning.opacity(0.25), lineWidth: 0.7)
                                    }
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 24))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("This agent is no longer in the current workspace.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Button("Back to agents") {
                    presentationModel.showOverview()
                }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func taskHeader(_ task: CodexAgentTaskSnapshot) -> some View {
        HStack(spacing: 12) {
            Button {
                presentationModel.showOverview()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .background(Circle().fill(DS.Colors.surface2))
            .pointerCursor()
            .help("Back to agents")
            .accessibilityLabel("Back to agents")

            AgentTokenGlyph(task: task, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(URL(fileURLWithPath: task.workspacePath).lastPathComponent)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()
            AgentStatusPill(status: task.status)

            if !task.status.isTerminal {
                Button(action: presentationModel.interruptSelectedTask) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.destructiveText)
                .background(Capsule().fill(DS.Colors.destructive.opacity(0.10)))
                .pointerCursor()
                .disabled(presentationModel.isPerformingOperation)
            } else {
                Button {
                    presentationModel.dismissTaskToken(threadID: task.threadID)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .background(Capsule().fill(DS.Colors.surface2))
                .pointerCursor()
                .help("Dismiss the top-right agent token")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    private func resultCard(_ task: CodexAgentTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(task.status.isTerminal ? "RESULT" : "CURRENT UPDATE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(task.agentAccentColor)
                Spacer()
                if task.status.isTerminal {
                    Button(action: presentationModel.openWorkspace) {
                        Label("Open folder", systemImage: "folder")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                }
            }

            Text(task.compactSummary)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let currentActivity = task.currentActivity {
                HStack(spacing: 8) {
                    Image(systemName: currentActivity.kind.systemImageName)
                    Text(currentActivity.summary)
                        .lineLimit(2)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                )
            }

            if !task.status.isTerminal {
                AgentProgressRail(color: task.agentAccentColor)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [task.agentAccentColor.opacity(0.20), DS.Colors.surface1],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(task.agentAccentColor.opacity(0.34), lineWidth: 0.8)
                }
        )
    }

    private func activityTimeline(_ task: CodexAgentTaskSnapshot) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(task.activities.suffix(12), id: \.itemID) { activity in
                Button {
                    presentationModel.openFileChange(activity)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: activity.kind.systemImageName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(activity.status.displayColor)
                            .frame(width: 18)

                        Text(activity.summary)
                            .font(.system(size: 10, design: activity.kind == .command ? .monospaced : .default))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Spacer()

                        Image(systemName: activity.status.systemImageName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(activity.status.displayColor)

                        if activity.kind == .fileChange {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: activity.kind == .fileChange)
                .disabled(activity.kind != .fileChange)

                if activity.itemID != task.activities.suffix(12).last?.itemID {
                    Divider().overlay(DS.Colors.borderSubtle.opacity(0.55))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                }
        )
    }

    private func followUpComposer(_ task: CodexAgentTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("FOLLOW UP")

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    task.status.isTerminal
                        ? "Continue with this agent"
                        : "Steer this agent",
                    text: $presentationModel.followUpPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .onSubmit(presentationModel.sendFollowUp)
                .accessibilityLabel(
                    task.status.isTerminal
                        ? "Continue with this agent"
                        : "Steer this agent"
                )

                Button(action: presentationModel.sendFollowUp) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundColor(.white)
                        .background(Circle().fill(task.agentAccentColor))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(
                    presentationModel.followUpPrompt
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || presentationModel.isPerformingOperation
                )
                .accessibilityLabel(
                    task.status.isTerminal
                        ? "Continue agent"
                        : "Steer agent"
                )
                .accessibilityHint("Send the follow-up text to this agent")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(DS.Colors.surface2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                    }
            )
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.7)
    }
}

private struct AgentApprovalCard: View {
    let approval: CodexAgentApproval
    let isBusy: Bool
    let decisionAction: (CodexAgentApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundColor(DS.Colors.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(approval.summary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                    if let reason = approval.reason {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    if let workingDirectory = approval.workingDirectory {
                        Text("Working directory: \(workingDirectory)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let requestedPermissionsDescription {
                VStack(alignment: .leading, spacing: 5) {
                    Text("REQUESTED SCOPE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.warning)
                        .tracking(0.6)
                    Text(requestedPermissionsDescription)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.72))
                )
            }

            HStack(spacing: 8) {
                approvalButton("Allow once", decision: .accept, isPrimary: true)
                approvalButton("Always allow", decision: .acceptForSession, isPrimary: false)
                approvalButton("Decline", decision: .decline, isPrimary: false)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(DS.Colors.warning.opacity(0.28), lineWidth: 0.8)
                }
        )
    }

    private func approvalButton(
        _ title: String,
        decision: CodexAgentApprovalDecision,
        isPrimary: Bool
    ) -> some View {
        Button(title) {
            decisionAction(decision)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(isPrimary ? .white : DS.Colors.textSecondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(isPrimary ? DS.Colors.accent : DS.Colors.surface3)
        )
        .pointerCursor()
        .disabled(isBusy)
    }

    private var requestedPermissionsDescription: String? {
        guard let requestedPermissions = approval.requestedPermissions,
              let encodedPermissions = try? JSONEncoder().encode(requestedPermissions),
              let object = try? JSONSerialization.jsonObject(with: encodedPermissions),
              let formattedData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(data: formattedData, encoding: .utf8)
    }
}

private struct AgentUserInputCard: View {
    let request: CodexAgentUserInputRequest
    let isBusy: Bool
    let interactionAction: () -> Void
    let submitAction: ([String: String]) -> Void

    @State private var selectedOptionByQuestionID: [String: String] = [:]
    @State private var customAnswerByQuestionID: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 9) {
                    Text(question.header.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.accentText)
                        .tracking(0.6)
                    Text(question.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let options = question.options {
                        VStack(spacing: 7) {
                            ForEach(options, id: \.label) { option in
                                optionButton(option, for: question)
                            }
                        }
                    }

                    if question.options == nil || question.isOther {
                        answerField(for: question)
                    }
                }
            }

            Button("Continue agent") {
                interactionAction()
                submitAction(resolvedAnswersByQuestionID)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(DS.Colors.accent))
            .pointerCursor()
            .disabled(isBusy || !hasAnswerForEveryQuestion)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(DS.Colors.accent.opacity(0.26), lineWidth: 0.8)
                }
        )
    }

    private func optionButton(
        _ option: CodexAgentUserInputOption,
        for question: CodexAgentUserInputQuestion
    ) -> some View {
        let isSelected = selectedOptionByQuestionID[question.id] == option.label
        return Button {
            interactionAction()
            selectedOptionByQuestionID[question.id] = option.label
            customAnswerByQuestionID[question.id] = ""
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(option.description)
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.10) : DS.Colors.surface1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(option.label)
        .accessibilityValue(option.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func answerField(
        for question: CodexAgentUserInputQuestion
    ) -> some View {
        let answerBinding = Binding(
            get: { customAnswerByQuestionID[question.id] ?? "" },
            set: { answer in
                interactionAction()
                customAnswerByQuestionID[question.id] = answer
                if !answer.isEmpty {
                    selectedOptionByQuestionID[question.id] = nil
                }
            }
        )
        if question.isSecret {
            SecureField("Enter a private answer", text: answerBinding)
                .textFieldStyle(.plain)
                .padding(10)
                .background(fieldBackground)
                .accessibilityLabel(question.question)
                .accessibilityHint("Enter a private answer")
        } else {
            TextField(
                question.options == nil ? "Type your answer" : "Or type another answer",
                text: answerBinding,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .padding(10)
            .background(fieldBackground)
            .accessibilityLabel(question.question)
            .accessibilityHint(
                question.options == nil
                    ? "Type your answer"
                    : "Type another answer"
            )
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(DS.Colors.surface2)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            }
    }

    private var hasAnswerForEveryQuestion: Bool {
        request.questions.allSatisfy { question in
            !(resolvedAnswersByQuestionID[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private var resolvedAnswersByQuestionID: [String: String] {
        Dictionary(uniqueKeysWithValues: request.questions.map { question in
            let customAnswer = customAnswerByQuestionID[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                question.id,
                customAnswer.isEmpty
                    ? selectedOptionByQuestionID[question.id] ?? ""
                    : customAnswer
            )
        })
    }
}

private extension CodexAgentActivityStatus {
    var displayColor: Color {
        switch self {
        case .running: return DS.Colors.blue400
        case .completed: return DS.Colors.success
        case .failed, .declined: return DS.Colors.destructiveText
        }
    }

    var systemImageName: String {
        switch self {
        case .running: return "ellipsis"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .declined: return "xmark"
        }
    }
}
