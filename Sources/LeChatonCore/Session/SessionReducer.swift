import Foundation

public enum SessionRole: String, Equatable, Hashable, Sendable {
    case user
    case agent
}

public enum SessionItemID: Equatable, Hashable, Sendable {
    case stable(String)
    case synthetic(runtimeGeneration: UUID, sequence: UInt64)
}

public struct SessionMessage: Equatable, Hashable, Sendable, Identifiable {
    public let id: SessionItemID
    public let role: SessionRole
    public var blocks: [ACPContentBlock]
    public var metadata: JSONValue?

    public var text: String { blocks.compactMap(\.text).joined() }
}

public struct SessionReasoning: Equatable, Hashable, Sendable, Identifiable {
    public let id: SessionItemID
    public var blocks: [ACPContentBlock]
    public var metadata: JSONValue?

    public var text: String { blocks.compactMap(\.text).joined() }
}

public struct SessionToolCall: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var kind: String?
    public var status: ToolCallStatus
    public var content: [JSONValue]
    public var locations: [JSONValue]
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var metadata: JSONValue?
}

public enum SessionTurnState: String, Equatable, Hashable, Sendable {
    case idle
    case prompting
    case cancelling
    case completed
    case failed
}

public struct SessionState: Equatable, Sendable {
    public var messages: [SessionMessage] = []
    public var reasoning: [SessionReasoning] = []
    public var toolCalls: [String: SessionToolCall] = [:]
    public var toolCallOrder: [String] = []
    public var planID: String?
    public var plan: [PlanEntry] = []
    public var turnState: SessionTurnState = .idle
    public var unknownUpdateCount = 0
    public var lastAppliedSequence: UInt64 = 0

    public init() {}

    public var orderedToolCalls: [SessionToolCall] {
        toolCallOrder.compactMap { toolCalls[$0] }
    }
}

/// Pure, synchronous ACP session reduction. It owns no clocks, I/O, or concurrency.
public struct SessionReducer: Sendable {
    public private(set) var state: SessionState

    public init(state: SessionState = SessionState()) {
        self.state = state
    }

    public mutating func reduce(_ envelope: EventEnvelope<SessionUpdate>) {
        switch envelope.payload {
        case let .userMessage(messageID, content, metadata):
            mergeMessage(
                id: itemID(messageID, envelope: envelope),
                role: .user,
                content: content,
                metadata: metadata,
                replacesDuringReplay: envelope.deliveryPhase != .live
            )

        case let .agentMessage(messageID, content, metadata):
            mergeMessage(
                id: itemID(messageID, envelope: envelope),
                role: .agent,
                content: content,
                metadata: metadata,
                replacesDuringReplay: envelope.deliveryPhase != .live
            )

        case let .reasoning(messageID, content, metadata):
            mergeReasoning(
                id: itemID(messageID, envelope: envelope),
                content: content,
                metadata: metadata,
                replacesDuringReplay: envelope.deliveryPhase != .live
            )

        case let .toolCallStarted(patch):
            mergeTool(patch, replace: envelope.deliveryPhase != .live)

        case let .toolCallUpdated(patch):
            mergeTool(patch, replace: false)

        case let .plan(id, entries, _):
            state.planID = id
            state.plan = entries

        case let .planRemoved(id, _):
            if id == nil || state.planID == nil || state.planID == id {
                state.planID = nil
                state.plan = []
            }

        case .metadata:
            break

        case .unknown:
            state.unknownUpdateCount += 1
        }
        state.lastAppliedSequence = max(state.lastAppliedSequence, envelope.sequence)
    }

    public mutating func beginPrompt() {
        state.turnState = .prompting
        state.planID = nil
        state.plan = []
    }

    public mutating func beginCancellation() {
        guard state.turnState == .prompting else { return }
        state.turnState = .cancelling
        for id in state.toolCallOrder where !isTerminal(state.toolCalls[id]?.status) {
            state.toolCalls[id]?.status = .cancelled
        }
    }

    public mutating func finishPrompt(failed: Bool = false) {
        state.turnState = failed ? .failed : .completed
    }

    /// Runtime unload clears transient plans and turn state while retaining replayable history.
    public mutating func unloadRuntime() {
        state.planID = nil
        state.plan = []
        state.turnState = .idle
    }

    public mutating func reset() {
        state = SessionState()
    }

    private func itemID(_ stableID: String?, envelope: EventEnvelope<SessionUpdate>) -> SessionItemID {
        if let stableID, !stableID.isEmpty { return .stable(stableID) }
        return .synthetic(runtimeGeneration: envelope.runtimeGeneration, sequence: envelope.sequence)
    }

    private mutating func mergeMessage(
        id: SessionItemID,
        role: SessionRole,
        content: ACPContentBlock,
        metadata: JSONValue?,
        replacesDuringReplay: Bool
    ) {
        if let index = state.messages.firstIndex(where: { $0.id == id }) {
            guard state.messages[index].role == role else { return }
            if replacesDuringReplay {
                state.messages[index].blocks = [content]
            } else {
                state.messages[index].blocks.append(content)
            }
            if let metadata { state.messages[index].metadata = metadata }
        } else {
            state.messages.append(.init(id: id, role: role, blocks: [content], metadata: metadata))
        }
    }

    private mutating func mergeReasoning(
        id: SessionItemID,
        content: ACPContentBlock,
        metadata: JSONValue?,
        replacesDuringReplay: Bool
    ) {
        if let index = state.reasoning.firstIndex(where: { $0.id == id }) {
            if replacesDuringReplay {
                state.reasoning[index].blocks = [content]
            } else {
                state.reasoning[index].blocks.append(content)
            }
            if let metadata { state.reasoning[index].metadata = metadata }
        } else {
            state.reasoning.append(.init(id: id, blocks: [content], metadata: metadata))
        }
    }

    private mutating func mergeTool(_ patch: ToolCallPatch, replace: Bool) {
        if state.toolCalls[patch.toolCallID] == nil {
            state.toolCallOrder.append(patch.toolCallID)
            state.toolCalls[patch.toolCallID] = SessionToolCall(
                id: patch.toolCallID,
                title: patch.title ?? patch.toolCallID,
                kind: patch.kind,
                status: patch.status ?? .pending,
                content: patch.content ?? [],
                locations: patch.locations ?? [],
                rawInput: patch.rawInput,
                rawOutput: patch.rawOutput,
                metadata: patch.metadata
            )
            return
        }

        guard var tool = state.toolCalls[patch.toolCallID] else { return }
        if let title = patch.title { tool.title = title }
        if let kind = patch.kind { tool.kind = kind }
        if let status = patch.status { tool.status = status }
        if let content = patch.content { tool.content = content }
        if let locations = patch.locations { tool.locations = locations }
        if let rawInput = patch.rawInput { tool.rawInput = rawInput }
        if let rawOutput = patch.rawOutput { tool.rawOutput = rawOutput }
        if let metadata = patch.metadata { tool.metadata = metadata }
        if replace, patch.content == nil { tool.content = [] }
        state.toolCalls[patch.toolCallID] = tool
    }

    private func isTerminal(_ status: ToolCallStatus?) -> Bool {
        switch status {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}
