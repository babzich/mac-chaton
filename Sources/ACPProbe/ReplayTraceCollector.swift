import Foundation
import LeChatonCore

actor ReplayTraceCollector {
    private struct ObservedEvent: Sendable {
        let frameOrdinal: UInt64
        let envelope: EventEnvelope<SessionUpdate>
        let reducedThroughSequence: UInt64
    }

    private let expectedGeneration: UUID
    private var expectedLoadAttemptID: UUID?
    private var reducer = SessionReducer()
    private var events: [ObservedEvent] = []
    private var frameOrdinal: UInt64 = 0
    private var barrier: ReplayBarrier?
    private var failureMessage: String?
    private var streamFinished = false
    private var replayCoverage = ReplayCoverage()
    private var liveCoverage = ReplayCoverage()

    init(expectedGeneration: UUID) {
        self.expectedGeneration = expectedGeneration
    }

    func consume(_ envelope: EventEnvelope<SessionUpdate>) {
        guard failureMessage == nil else { return }
        guard envelope.runtimeGeneration == expectedGeneration else {
            failureMessage = "received an envelope from a stale runtime generation"
            return
        }

        if envelope.deliveryPhase == .loadPending || envelope.deliveryPhase == .postLoadGuard {
            guard let attemptID = envelope.loadAttemptID else {
                failureMessage = "loading envelope did not carry a load-attempt identifier"
                return
            }
            if let expectedLoadAttemptID, attemptID != expectedLoadAttemptID {
                failureMessage = "received an envelope from a superseded load attempt"
                return
            }
            expectedLoadAttemptID = attemptID
            replayCoverage.record(envelope.payload)
        } else {
            liveCoverage.record(envelope.payload)
        }

        frameOrdinal += 1
        reducer.reduce(envelope)
        events.append(.init(
            frameOrdinal: frameOrdinal,
            envelope: envelope,
            reducedThroughSequence: reducer.state.lastAppliedSequence
        ))
    }

    func markStreamFinished() {
        streamFinished = true
    }

    func beginPrompt() {
        reducer.beginPrompt()
    }

    func beginCancellation() {
        reducer.beginCancellation()
    }

    func finishPrompt(failed: Bool) {
        reducer.finishPrompt(failed: failed)
    }

    func register(_ replayBarrier: ReplayBarrier) {
        guard failureMessage == nil else { return }
        guard replayBarrier.runtimeGeneration == expectedGeneration else {
            failureMessage = "load barrier belongs to a stale runtime generation"
            return
        }
        if let expectedLoadAttemptID, replayBarrier.loadAttemptID != expectedLoadAttemptID {
            failureMessage = "load barrier does not match the observed load attempt"
            return
        }
        expectedLoadAttemptID = replayBarrier.loadAttemptID
        barrier = replayBarrier
    }

    func barrierStatus() -> (acknowledged: Bool, lastAppliedSequence: UInt64, failure: String?) {
        guard let barrier else {
            return (false, reducer.state.lastAppliedSequence, failureMessage ?? "load barrier was not registered")
        }
        let acknowledged = reducer.state.lastAppliedSequence >= barrier.throughSequence
        let prematureEnd = streamFinished && !acknowledged
        return (
            acknowledged,
            reducer.state.lastAppliedSequence,
            failureMessage ?? (prematureEnd ? "update stream ended before the barrier was reduced" : nil)
        )
    }

    func sanitizedRecords(
        traceID: String,
        historyKind: HistoryKind,
        freshProcessOrdinal: Int
    ) throws -> ([SanitizedReplayEvent], SanitizedBarrierRecord, ReplayCoverage) {
        if let failureMessage { throw ProbeError.compatibility(failureMessage) }
        guard let barrier else { throw ProbeError.compatibility("load barrier was not registered") }
        let lastApplied = reducer.state.lastAppliedSequence
        guard lastApplied >= barrier.throughSequence else {
            throw ProbeError.compatibility(
                "barrier through sequence \(barrier.throughSequence) was not reduced; last applied was \(lastApplied)"
            )
        }

        let records = events.compactMap { event -> SanitizedReplayEvent? in
            guard event.envelope.loadAttemptID == barrier.loadAttemptID else { return nil }
            let position = event.envelope.sequence <= barrier.throughSequence ? "before_response" : "after_response"
            return SanitizedReplayEvent(
                traceID: traceID,
                historyKind: historyKind,
                freshProcessOrdinal: freshProcessOrdinal,
                frameOrdinal: event.frameOrdinal,
                eventKind: event.envelope.payload.kind,
                localSequence: event.envelope.sequence,
                loadResponsePosition: position,
                reducedThroughSequence: event.reducedThroughSequence,
                barrierAcknowledged: event.reducedThroughSequence >= barrier.throughSequence
            )
        }
        let barrierRecord = SanitizedBarrierRecord(
            traceID: traceID,
            historyKind: historyKind,
            freshProcessOrdinal: freshProcessOrdinal,
            responseAfterSequence: barrier.throughSequence,
            throughSequence: barrier.throughSequence,
            reducedThroughSequence: lastApplied,
            acknowledged: true
        )
        return (records, barrierRecord, replayCoverage)
    }

    func currentState() -> SessionState { reducer.state }
    func observedReplayCoverage() -> ReplayCoverage { replayCoverage }
    func observedLiveCoverage() -> ReplayCoverage { liveCoverage }
    func lastAppliedSequence() -> UInt64 { reducer.state.lastAppliedSequence }
}

struct ReplayConsumer: Sendable {
    let collector: ReplayTraceCollector
    let task: Task<Void, Never>

    init(transport: ACPTransport, generation: UUID) {
        let collector = ReplayTraceCollector(expectedGeneration: generation)
        self.collector = collector
        task = Task {
            let updates = await transport.updates()
            for await envelope in updates {
                await collector.consume(envelope)
            }
            await collector.markStreamFinished()
        }
    }

    func cancel() { task.cancel() }
}

func waitForBarrierAcknowledgement(
    _ barrier: ReplayBarrier,
    collector: ReplayTraceCollector,
    transport: ACPTransport,
    timeout: Duration = .seconds(10)
) async throws {
    await collector.register(barrier)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        let status = await collector.barrierStatus()
        if let failure = status.failure { throw ProbeError.compatibility(failure) }
        if let transportFailure = await transport.failure() { throw transportFailure }
        if status.acknowledged { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    let status = await collector.barrierStatus()
    throw ProbeError.timeout(
        "replay barrier through sequence \(barrier.throughSequence); last applied was \(status.lastAppliedSequence)"
    )
}

func settleConsumer(_ collector: ReplayTraceCollector, timeout: Duration = .seconds(1)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var previous = await collector.lastAppliedSequence()
    var stableChecks = 0
    while clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
        let current = await collector.lastAppliedSequence()
        if current == previous {
            stableChecks += 1
            if stableChecks >= 3 { return }
        } else {
            stableChecks = 0
            previous = current
        }
    }
}
