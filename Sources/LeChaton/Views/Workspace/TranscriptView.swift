import LeChatonCore
import SwiftUI

struct TranscriptView: View {
    let state: SessionState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.messages.isEmpty,
                       state.reasoning.isEmpty,
                       state.toolCalls.isEmpty,
                       state.plan.isEmpty
                    {
                        ContentUnavailableView(
                            "No messages yet",
                            systemImage: "text.bubble",
                            description: Text("Send a prompt to begin this Thread.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }

                    ForEach(state.transcriptOrder) { reference in
                        transcriptItem(reference)
                    }

                    if !state.plan.isEmpty {
                        LivePlanView(entries: state.plan)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                }
                .frame(maxWidth: 748)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
            .onChange(of: state.lastAppliedSequence) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptItem(_ reference: SessionTranscriptItemReference) -> some View {
        switch reference {
        case let .message(role, id):
            if let message = state.messages.first(where: { $0.role == role && $0.id == id }) {
                MessageRow(message: message)
            }
        case let .reasoning(id):
            if let reasoning = state.reasoning.first(where: { $0.id == id }) {
                ReasoningRow(reasoning: reasoning)
            }
        case let .tool(id):
            if let tool = state.toolCalls[id] {
                ToolCallRow(tool: tool)
            }
        }
    }
}

private struct MessageRow: View {
    let message: SessionMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "You" : "Vibe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        message.role == .user
                            ? LeChatonTheme.primaryText.opacity(0.78)
                            : LeChatonTheme.secondaryText
                    )
                Text(message.text.isEmpty ? "Non-text content" : message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(message.role == .user ? 12 : 0)
            .padding(.vertical, message.role == .agent ? 8 : 0)
            .frame(maxWidth: message.role == .user ? 520 : .infinity, alignment: .leading)
            .background(
                message.role == .user ? LeChatonTheme.userBubble : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(message.role == .user ? LeChatonTheme.orange.opacity(0.28) : .clear)
            }
            .overlay(alignment: .bottom) {
                if message.role == .agent {
                    Rectangle().fill(LeChatonTheme.hairline).frame(height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReasoningRow: View {
    let reasoning: SessionReasoning

    var body: some View {
        DisclosureGroup {
            Text(reasoning.text.isEmpty ? "Non-text reasoning content" : reasoning.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Label("Reasoning", systemImage: "brain.head.profile")
                .font(.callout.weight(.medium))
                .foregroundStyle(LeChatonTheme.reasoningAccent)
        }
        .padding(12)
        .background(LeChatonTheme.reasoningSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(LeChatonTheme.reasoningAccent.opacity(0.22))
        }
    }
}

private struct ToolCallRow: View {
    let tool: SessionToolCall

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let kind = tool.kind {
                    LabeledContent("Kind", value: kind)
                }
                if let input = tool.rawInput {
                    JSONDetail(label: "Input", value: input)
                }
                if let output = tool.rawOutput {
                    JSONDetail(label: "Output", value: output)
                }
                ForEach(Array(tool.content.enumerated()), id: \.offset) { _, value in
                    Text(value.encodedString())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label(tool.title, systemImage: toolStatusIcon)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                Spacer()
                Text(tool.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(toolStatusColor)
            }
        }
        .padding(12)
        .background(LeChatonTheme.utilitySurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(LeChatonTheme.hairline)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(toolStatusColor.opacity(0.72))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .accessibilityLabel("Tool call: \(tool.title), \(tool.status.rawValue)")
    }

    private var toolStatusIcon: String {
        switch tool.status {
        case .pending: "hourglass"
        case .inProgress: "gearshape.2"
        case .completed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .cancelled: "slash.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var toolStatusColor: Color {
        switch tool.status {
        case .completed: LeChatonTheme.success
        case .failed: LeChatonTheme.danger
        case .inProgress: LeChatonTheme.amber
        case .cancelled: LeChatonTheme.secondaryText
        case .pending, .unknown: LeChatonTheme.secondaryText
        }
    }
}

private struct JSONDetail: View {
    let label: String
    let value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.encodedString())
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct LivePlanView: View {
    let entries: [PlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Plan", systemImage: "checklist")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LeChatonTheme.amber)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(for: entry.status))
                            .foregroundStyle(entry.status == .completed ? LeChatonTheme.success : LeChatonTheme.secondaryText)
                        Text(entry.content)
                        Spacer()
                        Text(priorityLabel(entry.priority))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(LeChatonTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(LeChatonTheme.hairline)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LeChatonTheme.accentGradient)
                .frame(width: 3)
                .padding(.vertical, 7)
        }
        .accessibilityElement(children: .contain)
    }

    private func icon(for status: PlanEntryStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func priorityLabel(_ priority: PlanEntryPriority) -> String {
        switch priority {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case let .unknown(raw): raw
        }
    }
}
