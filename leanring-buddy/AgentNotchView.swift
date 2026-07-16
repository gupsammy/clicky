//
//  AgentNotchView.swift
//  leanring-buddy
//
//  Global agent switcher that expands down from the Mac's top-center notch area.
//

import AppKit
import SwiftUI

struct AgentNotchView: View {
    @ObservedObject var presentationModel: AgentPresentationModel

    var body: some View {
        Group {
            if presentationModel.isNotchExpanded {
                expandedSurface
            } else {
                collapsedSurface
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: presentationModel.isNotchExpanded)
    }

    private var collapsedSurface: some View {
        Button {
            presentationModel.showOverview()
        } label: {
            HStack(spacing: 12) {
                if let primaryTask = presentationModel.runningTasks.first {
                    AgentTokenGlyph(task: primaryTask, size: 24)
                } else {
                    Triangle()
                        .fill(DS.Colors.overlayCursorBlue)
                        .rotationEffect(.degrees(-35))
                        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.65), radius: 5)
                        .frame(width: 16, height: 16)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(collapsedTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let primaryTask = presentationModel.runningTasks.first {
                        Text(primaryTask.compactSummary)
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if presentationModel.runningTasks.isEmpty {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    AgentWorkingDots(color: presentationModel.runningTasks[0].agentAccentColor)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ClickyNotchShape(bottomCornerRadius: 20)
                    .fill(Color.black.opacity(0.98))
                    .overlay {
                        ClickyNotchShape(bottomCornerRadius: 20)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                    }
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Open Clicky agents")
    }

    private var expandedSurface: some View {
        VStack(spacing: 0) {
            expandedHeader
            Divider().overlay(DS.Colors.borderSubtle.opacity(0.7))

            Group {
                switch presentationModel.route {
                case .overview:
                    overview
                case .task:
                    AgentTaskDetailView(presentationModel: presentationModel)
                }
            }
        }
        .background(
            ClickyNotchShape(bottomCornerRadius: 36)
                .fill(DS.Colors.background.opacity(0.985))
                .overlay {
                    ClickyNotchShape(bottomCornerRadius: 36)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(0.55), radius: 30, y: 12)
        )
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            Button {
                presentationModel.collapseNotch()
                NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
            } label: {
                Label("Home", systemImage: "house")
            }
            .buttonStyle(AgentNotchNavigationButtonStyle(isSelected: false))

            Button {
                presentationModel.showOverview()
            } label: {
                Label("Agents", systemImage: "sparkles")
            }
            .buttonStyle(AgentNotchNavigationButtonStyle(isSelected: true))

            Spacer()

            connectionIndicator

            Button {
                presentationModel.chooseWorkspace()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textTertiary)
            .background(Circle().fill(DS.Colors.surface2))
            .pointerCursor()
            .help("Choose Agent Folder")

            Button {
                presentationModel.collapseNotch()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textTertiary)
            .pointerCursor()
            .help("Collapse")
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
    }

    private var connectionIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 6, height: 6)
            Text(connectionTitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if presentationModel.connectionPhase == .needsAuthentication {
                    authenticationRecovery
                } else {
                    newAgentComposer
                }

                if let operationErrorMessage = presentationModel.operationErrorMessage {
                    AgentHUDErrorBanner(
                        message: operationErrorMessage,
                        retryAction: presentationModel.canRetryConnection
                            ? { presentationModel.retryConnection() }
                            : nil,
                        dismissAction: { presentationModel.dismissOperationError() }
                    )
                }

                if !presentationModel.runningTasks.isEmpty {
                    agentTaskList(
                        title: "ACTIVE",
                        tasks: presentationModel.runningTasks
                    )
                }

                if !presentationModel.completedTasks.isEmpty {
                    agentTaskList(
                        title: "RECENT",
                        tasks: presentationModel.completedTasks
                    )
                }

                if presentationModel.taskSnapshots.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }

    private var authenticationRecovery: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(DS.Colors.warning)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DS.Colors.warning.opacity(0.12)))

            VStack(alignment: .leading, spacing: 7) {
                Text("Sign in to run Codex agents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Use your ChatGPT subscription. Clicky will open the secure Codex sign-in page in your browser.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { presentationModel.signInWithChatGPT() }) {
                    HStack(spacing: 7) {
                        if presentationModel.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(
                            presentationModel.isAuthenticating
                                ? "Waiting for sign-in…"
                                : presentationModel.authenticationCanStartAgain
                                    ? "Start again"
                                    : "Sign in with ChatGPT"
                        )
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!presentationModel.canSignInWithChatGPT)
                .opacity(presentationModel.canSignInWithChatGPT ? 1 : 0.68)
                .help("Sign in to Codex with your ChatGPT subscription")

                if presentationModel.canCancelChatGPTSignIn {
                    Button("Cancel sign-in") {
                        presentationModel.cancelChatGPTSignIn()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                    .help("Cancel this Codex browser sign-in")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.Colors.warning.opacity(0.25), lineWidth: 0.8)
                }
        )
    }

    private func agentTaskList(
        title: String,
        tasks: [CodexAgentTaskSnapshot]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            agentSectionTitle(title)

            LazyVStack(spacing: 0) {
                ForEach(tasks, id: \.threadID) { task in
                    AgentTaskListRow(
                        task: task,
                        openAction: {
                            presentationModel.showTask(threadID: task.threadID)
                        },
                        stopAction: task.status.isTerminal ? nil : {
                            presentationModel.interruptTask(threadID: task.threadID)
                        }
                    )

                    if task.threadID != tasks.last?.threadID {
                        Divider()
                            .overlay(DS.Colors.borderSubtle.opacity(0.58))
                            .padding(.leading, 52)
                    }
                }
            }
            .background(DS.Colors.surface1.opacity(0.66))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7)
            }
        }
    }

    private var newAgentComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NEW AGENT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                Button {
                    presentationModel.chooseWorkspace()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(presentationModel.workspacePath.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        } ?? "Choose Agent Folder")
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "What should an agent work on?",
                    text: $presentationModel.newTaskPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .onSubmit(presentationModel.startTask)

                Button(action: presentationModel.startTask) {
                    Group {
                        if presentationModel.isPerformingOperation {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .foregroundColor(.white)
                    .background(Circle().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!presentationModel.canRunTask)
                .opacity(presentationModel.canRunTask ? 1 : 0.42)
                .help("Run agent")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                    }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundColor(DS.Colors.accentText)
            Text("Your agents will appear here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Choose an Agent Folder, then give Codex a task.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func agentSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.7)
    }

    private var collapsedTitle: String {
        let runningCount = presentationModel.runningTasks.count
        if runningCount == 0 { return "Agents" }
        if runningCount == 1 { return presentationModel.runningTasks[0].title }
        return "\(runningCount) agents working"
    }

    private var connectionTitle: String {
        switch presentationModel.connectionPhase {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .connected(let accountLabel): return accountLabel
        case .needsAuthentication: return "Sign in required"
        case .failed: return "Unavailable"
        }
    }

    private var connectionColor: Color {
        switch presentationModel.connectionPhase {
        case .connected: return DS.Colors.success
        case .connecting: return DS.Colors.warning
        case .idle: return DS.Colors.textTertiary
        case .needsAuthentication, .failed: return DS.Colors.destructiveText
        }
    }
}

private struct AgentNotchNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected || isHovered ? DS.Colors.surface3 : .clear)
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

private struct AgentWorkingDots: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .opacity(isAnimating ? 1 : 0.28)
                    .animation(
                        .easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}

private struct ClickyNotchShape: Shape {
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomCornerRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct AgentHUDErrorBanner: View {
    let message: String
    let retryAction: (() -> Void)?
    let dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DS.Colors.warning)
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
            Spacer()
            if let retryAction {
                Button("Reconnect", action: retryAction)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
            }
            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textTertiary)
            .pointerCursor()
            .help("Dismiss error")
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

struct AgentNotchView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AgentNotchView(
                presentationModel: .preview(tasks: previewTasks)
            )
            .frame(width: 820, height: 520)
            .previewDisplayName("Agent overview")

            AgentNotchView(
                presentationModel: .preview(
                    tasks: previewTasks,
                    route: .task(threadID: "thread_running")
                )
            )
            .frame(width: 820, height: 520)
            .previewDisplayName("Running detail")

            AgentNotchView(
                presentationModel: .preview(
                    tasks: previewTasks,
                    isExpanded: false
                )
            )
            .frame(width: 460, height: 40)
            .previewDisplayName("Collapsed")
        }
    }

    private static let previewTasks = [
        CodexAgentTaskSnapshot(
            threadID: "thread_running",
            turnID: "turn_running",
            workspacePath: "/Users/samarthgupta/Projects/clicky",
            title: "Bring the agent HUD to parity",
            status: .running,
            latestAgentMessage: "I wired the shared task model and I am checking the visual states now.",
            currentActivity: CodexAgentActivity(
                itemID: "activity_typecheck",
                kind: .command,
                summary: "swiftc -typecheck AgentHUDViews.swift",
                status: .running
            ),
            activities: [
                CodexAgentActivity(
                    itemID: "activity_file",
                    kind: .fileChange,
                    summary: "leanring-buddy/AgentNotchView.swift",
                    status: .completed
                ),
                CodexAgentActivity(
                    itemID: "activity_typecheck",
                    kind: .command,
                    summary: "swiftc -typecheck AgentHUDViews.swift",
                    status: .running
                )
            ],
            pendingApprovals: [],
            pendingUserInputs: [],
            errorMessage: nil,
            lastEventSequence: 8
        ),
        CodexAgentTaskSnapshot(
            threadID: "thread_approval",
            turnID: "turn_approval",
            workspacePath: "/Users/samarthgupta/Projects/clicky",
            title: "Prepare the next reviewable slice",
            status: .waitingForApproval,
            latestAgentMessage: "The change is ready to publish after your approval.",
            currentActivity: nil,
            activities: [],
            pendingApprovals: [
                CodexAgentApproval(
                    requestID: .integer(14),
                    method: "item/commandExecution/requestApproval",
                    threadID: "thread_approval",
                    turnID: "turn_approval",
                    itemID: "activity_push",
                    summary: "git push personal feature/agent-hybrid-hud",
                    reason: "Publish the branch for review",
                    workingDirectory: "/Users/samarthgupta/Projects/clicky",
                    requestedPermissions: nil
                )
            ],
            pendingUserInputs: [],
            errorMessage: nil,
            lastEventSequence: 7
        ),
        CodexAgentTaskSnapshot(
            threadID: "thread_done",
            turnID: "turn_done",
            workspacePath: "/Users/samarthgupta/Projects/clicky",
            title: "Research the HeyClicky agent flow",
            status: .completed,
            latestAgentMessage: "Mapped the notch, screen tokens, task detail, approvals, and same-thread follow-up flow.",
            currentActivity: nil,
            activities: [],
            pendingApprovals: [],
            pendingUserInputs: [],
            errorMessage: nil,
            lastEventSequence: 6
        )
    ]
}
