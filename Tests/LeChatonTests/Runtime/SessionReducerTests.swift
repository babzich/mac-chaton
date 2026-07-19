import Foundation
import Testing
@testable import LeChatonCore

@Suite("Session reducer")
struct SessionReducerTests {
    @Test("Stable replay messages replace while live chunks append")
    func replayReplacementAndLiveAppend() {
        let generation = UUID()
        let attempt = UUID()
        var reducer = SessionReducer()
        reducer.reduce(envelope(
            generation: generation,
            attempt: attempt,
            sequence: 1,
            phase: .loadPending,
            update: .agentMessage(messageID: "message", content: .text("first replay", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: attempt,
            sequence: 2,
            phase: .loadPending,
            update: .agentMessage(messageID: "message", content: .text("replacement replay", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 3,
            phase: .live,
            update: .agentMessage(messageID: "message", content: .text(" + live", metadata: nil), metadata: nil)
        ))

        #expect(reducer.state.messages.count == 1)
        #expect(reducer.state.messages[0].text == "replacement replay + live")
        #expect(reducer.state.lastAppliedSequence == 3)
    }

    @Test("ID-less chunks are distinct generation-sequence events")
    func idlessChunksStayDistinct() {
        let generation = UUID()
        var reducer = SessionReducer()
        for sequence in 1...2 {
            reducer.reduce(envelope(
                generation: generation,
                attempt: nil,
                sequence: UInt64(sequence),
                phase: .live,
                update: .agentMessage(messageID: nil, content: .text("same", metadata: nil), metadata: nil)
            ))
        }
        #expect(reducer.state.messages.count == 2)
        #expect(reducer.state.messages[0].id != reducer.state.messages[1].id)
        #expect(reducer.state.transcriptOrder == [
            .message(role: .agent, id: .synthetic(runtimeGeneration: generation, sequence: 1)),
            .message(role: .agent, id: .synthetic(runtimeGeneration: generation, sequence: 2)),
        ])
    }

    @Test("Transcript references preserve first occurrence across event kinds")
    func transcriptOrderAcrossEventKinds() {
        let generation = UUID()
        var reducer = SessionReducer()
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 1,
            phase: .live,
            update: .userMessage(messageID: "user", content: .text("Question", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 2,
            phase: .live,
            update: .reasoning(messageID: "reasoning", content: .text("Think", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 3,
            phase: .live,
            update: .toolCallStarted(.init(toolCallID: "tool", title: "Read", status: .inProgress))
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 4,
            phase: .live,
            update: .agentMessage(messageID: "agent", content: .text("Answer", metadata: nil), metadata: nil)
        ))

        #expect(reducer.state.transcriptOrder == [
            .message(role: .user, id: .stable("user")),
            .reasoning(id: .stable("reasoning")),
            .tool(id: "tool"),
            .message(role: .agent, id: .stable("agent")),
        ])
    }

    @Test("Transcript references preserve ordering across turns")
    func transcriptOrderAcrossTurns() {
        let generation = UUID()
        var reducer = SessionReducer()
        let updates: [SessionUpdate] = [
            .userMessage(messageID: "user-1", content: .text("First", metadata: nil), metadata: nil),
            .reasoning(messageID: "reasoning-1", content: .text("Think first", metadata: nil), metadata: nil),
            .agentMessage(messageID: "agent-1", content: .text("First answer", metadata: nil), metadata: nil),
            .userMessage(messageID: "user-2", content: .text("Second", metadata: nil), metadata: nil),
            .toolCallStarted(.init(toolCallID: "tool-2", title: "Work", status: .inProgress)),
            .agentMessage(messageID: "agent-2", content: .text("Second answer", metadata: nil), metadata: nil),
        ]
        for (offset, update) in updates.enumerated() {
            reducer.reduce(envelope(
                generation: generation,
                attempt: nil,
                sequence: UInt64(offset + 1),
                phase: .live,
                update: update
            ))
        }

        #expect(reducer.state.transcriptOrder == [
            .message(role: .user, id: .stable("user-1")),
            .reasoning(id: .stable("reasoning-1")),
            .message(role: .agent, id: .stable("agent-1")),
            .message(role: .user, id: .stable("user-2")),
            .tool(id: "tool-2"),
            .message(role: .agent, id: .stable("agent-2")),
        ])
    }

    @Test("Stable replay and live updates retain their first transcript position")
    func stableUpdatesDoNotDuplicateTranscriptReferences() {
        let generation = UUID()
        let attempt = UUID()
        var reducer = SessionReducer()
        reducer.reduce(envelope(
            generation: generation,
            attempt: attempt,
            sequence: 1,
            phase: .loadPending,
            update: .agentMessage(messageID: "agent", content: .text("Replay", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: attempt,
            sequence: 2,
            phase: .loadPending,
            update: .reasoning(messageID: "reasoning", content: .text("Replay thought", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: attempt,
            sequence: 3,
            phase: .loadPending,
            update: .toolCallStarted(.init(toolCallID: "tool", title: "Replay tool", status: .inProgress))
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: attempt,
            sequence: 4,
            phase: .loadPending,
            update: .agentMessage(messageID: "agent", content: .text("Replacement", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 5,
            phase: .live,
            update: .reasoning(messageID: "reasoning", content: .text(" + live", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 6,
            phase: .live,
            update: .toolCallUpdated(.init(toolCallID: "tool", status: .completed))
        ))

        #expect(reducer.state.transcriptOrder == [
            .message(role: .agent, id: .stable("agent")),
            .reasoning(id: .stable("reasoning")),
            .tool(id: "tool"),
        ])
        #expect(reducer.state.messages[0].text == "Replacement")
        #expect(reducer.state.reasoning[0].text == "Replay thought + live")
        #expect(reducer.state.toolCalls["tool"]?.status == .completed)
    }

    @Test("Plans are complete replacements and clear on unload")
    func transientPlan() {
        var reducer = SessionReducer()
        reducer.reduce(envelope(
            generation: UUID(),
            attempt: nil,
            sequence: 1,
            phase: .live,
            update: .plan(
                id: "plan",
                entries: [.init(content: "One", priority: .high, status: .inProgress)],
                metadata: nil
            )
        ))
        #expect(reducer.state.plan.map(\.content) == ["One"])

        reducer.unloadRuntime()
        #expect(reducer.state.plan.isEmpty)
        #expect(reducer.state.planID == nil)
    }

    @Test("Unload preserves transcript references while reset clears them")
    func unloadAndResetTranscriptOrder() {
        let generation = UUID()
        var reducer = SessionReducer()
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 1,
            phase: .live,
            update: .userMessage(messageID: "user", content: .text("Question", metadata: nil), metadata: nil)
        ))
        reducer.reduce(envelope(
            generation: generation,
            attempt: nil,
            sequence: 2,
            phase: .live,
            update: .plan(
                id: "plan",
                entries: [.init(content: "One", priority: .high, status: .inProgress)],
                metadata: nil
            )
        ))
        let transcriptOrder = reducer.state.transcriptOrder

        reducer.unloadRuntime()

        #expect(reducer.state.transcriptOrder == transcriptOrder)
        #expect(reducer.state.plan.isEmpty)
        #expect(reducer.state.planID == nil)

        reducer.reset()

        #expect(reducer.state.transcriptOrder.isEmpty)
        #expect(reducer.state.messages.isEmpty)
    }

    @Test("Cancellation is idempotent and marks unfinished tools")
    func cancellation() {
        var reducer = SessionReducer()
        reducer.reduce(envelope(
            generation: UUID(),
            attempt: nil,
            sequence: 1,
            phase: .live,
            update: .toolCallStarted(.init(toolCallID: "tool", title: "Work", status: .inProgress))
        ))
        reducer.beginPrompt()
        reducer.beginCancellation()
        reducer.beginCancellation()
        #expect(reducer.state.turnState == .cancelling)
        #expect(reducer.state.toolCalls["tool"]?.status == .cancelled)
    }

    private func envelope(
        generation: UUID,
        attempt: UUID?,
        sequence: UInt64,
        phase: DeliveryPhase,
        update: SessionUpdate
    ) -> EventEnvelope<SessionUpdate> {
        EventEnvelope(
            runtimeGeneration: generation,
            loadAttemptID: attempt,
            sequence: sequence,
            deliveryPhase: phase,
            payload: update
        )
    }
}
