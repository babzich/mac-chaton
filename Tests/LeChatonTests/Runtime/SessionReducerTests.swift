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
