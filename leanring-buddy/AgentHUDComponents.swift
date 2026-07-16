//
//  AgentHUDComponents.swift
//  leanring-buddy
//
//  Shared visual language for the notch, task detail, and per-screen agent tokens.
//

import SwiftUI

struct AgentTokenGlyph: View {
    let task: CodexAgentTaskSnapshot
    var size: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(task.agentAccentColor.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .stroke(task.agentAccentColor.opacity(0.55), lineWidth: 0.8)
                }

            Triangle()
                .fill(task.agentAccentColor)
                .rotationEffect(.degrees(-35))
                .shadow(color: task.agentAccentColor.opacity(0.65), radius: 5)
                .padding(size * 0.23)

            if task.status == .waitingForApproval || task.status == .waitingForInput {
                Circle()
                    .fill(DS.Colors.warning)
                    .frame(width: max(6, size * 0.18), height: max(6, size * 0.18))
                    .overlay(Circle().stroke(DS.Colors.background, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: size, height: size)
    }
}

struct AgentStatusPill: View {
    let status: CodexAgentTaskStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.displayColor)
                .frame(width: 5, height: 5)
            Text(status.displayTitle)
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundColor(status.displayColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(status.displayColor.opacity(0.13))
                .overlay {
                    Capsule()
                        .stroke(status.displayColor.opacity(0.28), lineWidth: 0.7)
                }
        )
    }
}

struct AgentProgressRail: View {
    let color: Color
    @State private var progressOffset: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, color.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * 0.34)
                    .offset(x: progressOffset * geometry.size.width)
            }
            .onAppear {
                progressOffset = -0.4
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    progressOffset = 1.1
                }
            }
        }
        .frame(height: 2)
        .clipped()
    }
}

struct AgentTaskListRow: View {
    let task: CodexAgentTaskSnapshot
    let openAction: () -> Void
    let stopAction: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openAction) {
                HStack(spacing: 11) {
                    AgentTokenGlyph(task: task, size: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let currentActivity = task.currentActivity {
                                Image(systemName: currentActivity.kind.systemImageName)
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(task.compactSummary)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .foregroundColor(DS.Colors.textTertiary)
                    }

                    Spacer(minLength: 8)
                    AgentStatusPill(status: task.status)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if let stopAction {
                Button(action: stopAction) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(DS.Colors.destructiveText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(DS.Colors.destructive.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Stop agent")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(isHovered ? Color.white.opacity(0.035) : .clear)
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                isHovered = hovering
            }
        }
    }
}

struct AgentTaskCard: View {
    let task: CodexAgentTaskSnapshot
    let isProminent: Bool
    let openAction: () -> Void
    let stopAction: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Button(action: openAction) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    AgentTokenGlyph(task: task, size: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.system(size: isProminent ? 15 : 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(task.compactSummary)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(isProminent ? 2 : 3)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 8)
                    AgentStatusPill(status: task.status)

                    if let stopAction {
                        Button(action: stopAction) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.black.opacity(0.20)))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Stop agent")
                    }
                }

                if let currentActivity = task.currentActivity {
                    HStack(spacing: 7) {
                        Image(systemName: currentActivity.kind.systemImageName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(currentActivity.summary)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                }

                if !task.status.isTerminal {
                    AgentProgressRail(color: task.agentAccentColor)
                } else {
                    HStack(spacing: 6) {
                        Text("Open Agent")
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.22)))
                }
            }
            .padding(isProminent ? 18 : 16)
            .frame(maxWidth: .infinity, minHeight: isProminent ? 132 : 174, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                task.agentAccentColor.opacity(isHovered ? 0.34 : 0.26),
                                DS.Colors.surface1.opacity(0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(task.agentAccentColor.opacity(isHovered ? 0.62 : 0.34), lineWidth: 0.8)
                    }
                    .shadow(color: task.agentAccentColor.opacity(isHovered ? 0.20 : 0.09), radius: 14)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                isHovered = hovering
            }
        }
    }
}

extension CodexAgentTaskSnapshot {
    var compactSummary: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let currentActivity, !currentActivity.summary.isEmpty {
            return currentActivity.summary
        }
        let trimmedMessage = latestAgentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            return trimmedMessage
        }
        if !workspacePath.isEmpty {
            return URL(fileURLWithPath: workspacePath).lastPathComponent
        }
        switch status {
        case .queued:
            return "Waiting to start"
        case .idle:
            return "Ready to continue"
        default:
            return "No update yet"
        }
    }

    var agentAccentColor: Color {
        let palette: [Color] = [
            DS.Colors.blue400,
            Color(hex: "#A78BFA"),
            DS.Colors.success,
            Color(hex: "#F59E0B"),
            Color(hex: "#F472B6")
        ]
        let scalarTotal = threadID.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
        return palette[scalarTotal % palette.count]
    }
}

extension CodexAgentTaskStatus {
    var displayTitle: String {
        switch self {
        case .queued: return "QUEUED"
        case .idle: return "IDLE"
        case .running: return "WORKING"
        case .waitingForApproval: return "APPROVAL"
        case .waitingForInput: return "INPUT"
        case .completed: return "DONE"
        case .interrupted: return "STOPPED"
        case .failed: return "FAILED"
        }
    }

    var displayColor: Color {
        switch self {
        case .queued: return DS.Colors.textTertiary
        case .idle: return DS.Colors.textSecondary
        case .running: return DS.Colors.blue400
        case .waitingForApproval, .waitingForInput: return DS.Colors.warning
        case .completed: return DS.Colors.success
        case .interrupted: return DS.Colors.textSecondary
        case .failed: return DS.Colors.destructiveText
        }
    }
}

extension CodexAgentActivityKind {
    var systemImageName: String {
        switch self {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .mcpTool, .dynamicTool: return "wrench.and.screwdriver"
        case .collaboration: return "person.2"
        case .plan: return "checklist"
        case .reasoning: return "brain"
        case .contextCompaction: return "arrow.triangle.2.circlepath"
        case .other: return "sparkles"
        }
    }
}
