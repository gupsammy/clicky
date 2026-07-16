//
//  AgentTokenRailView.swift
//  leanring-buddy
//
//  Lightweight, screen-local agent activity tokens that open the shared notch detail.
//

import CoreGraphics
import SwiftUI

struct AgentTokenRailView: View {
    @ObservedObject var presentationModel: AgentPresentationModel
    let displayIdentifier: CGDirectDisplayID

    private var tasks: [CodexAgentTaskSnapshot] {
        Array(presentationModel.tasks(for: displayIdentifier).prefix(4))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(tasks, id: \.threadID) { task in
                AgentPersistentTokenView(
                    task: task,
                    openAction: {
                        presentationModel.showTask(
                            threadID: task.threadID,
                            on: displayIdentifier
                        )
                    },
                    dismissAction: task.status.isTerminal ? {
                        presentationModel.dismissTaskToken(threadID: task.threadID)
                    } : nil
                )
            }

            let hiddenTaskCount = presentationModel.tasks(for: displayIdentifier).count - tasks.count
            if hiddenTaskCount > 0 {
                Button {
                    presentationModel.showOverview()
                } label: {
                    Text("+\(hiddenTaskCount) more")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.86)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

private struct AgentPersistentTokenView: View {
    let task: CodexAgentTaskSnapshot
    let openAction: () -> Void
    let dismissAction: (() -> Void)?

    @State private var isHovered = false
    @State private var isDrawingAttention = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: openAction) {
                HStack(spacing: 9) {
                    AgentTokenGlyph(task: task, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        Text(task.compactSummary)
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                    statusAccessory
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open \(task.title)")

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(isHovered ? 0.10 : 0.05)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Dismiss agent")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 280, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            task.agentAccentColor.opacity(isDrawingAttention ? 0.90 : 0.38),
                            lineWidth: isDrawingAttention ? 1.4 : 0.8
                        )
                }
                .shadow(
                    color: task.agentAccentColor.opacity(isDrawingAttention ? 0.46 : 0.14),
                    radius: isDrawingAttention ? 18 : 9
                )
        )
        .scaleEffect(isDrawingAttention ? 1.035 : 1)
        .onHover { isHovered = $0 }
        .onAppear {
            if task.status.isTerminal {
                drawAttentionToCompletion()
            }
        }
        .onChange(of: task.status) { _, newStatus in
            if newStatus.isTerminal {
                drawAttentionToCompletion()
            }
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch task.status {
        case .queued, .running:
            TokenProgressDots(color: task.agentAccentColor)
        case .idle:
            Image(systemName: "pause.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
        case .waitingForApproval, .waitingForInput:
            Circle()
                .fill(DS.Colors.warning)
                .frame(width: 7, height: 7)
                .shadow(color: DS.Colors.warning.opacity(0.55), radius: 4)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(DS.Colors.success)
        case .interrupted:
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(DS.Colors.destructiveText)
        }
    }

    private func drawAttentionToCompletion() {
        isDrawingAttention = false
        withAnimation(
            .easeInOut(duration: 0.34)
                .repeatCount(6, autoreverses: true)
        ) {
            isDrawingAttention = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.2)) {
                isDrawingAttention = false
            }
        }
    }
}

private struct TokenProgressDots: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { dotIndex in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .opacity(isAnimating ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.65)
                            .repeatForever(autoreverses: true)
                            .delay(Double(dotIndex) * 0.14),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}
