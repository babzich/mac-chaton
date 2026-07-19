import Foundation
import Testing
@testable import LeChatonCore

@Suite("ACPProbe configuration recovery supervisor")
struct ConfigurationGateSupervisorTests {
    @Test("A successful worker is cleaned up before originals are restored and committed")
    func workerSuccess() async throws {
        let fixture = try JournalFixture()
        defer { fixture.removeDirectory() }
        let events = EventRecorder()

        try await ConfigurationGateSupervisor.run(
            worker: { await events.record("worker") },
            cleanupWorker: { await events.record("cleanup") },
            restoreOriginals: { await events.record("restore") },
            commitRestoration: {
                await events.record("commit")
                try ConfigurationJournalStore.remove(fixture.journalURL)
            }
        )

        #expect(await events.snapshot() == ["worker", "cleanup", "restore", "commit"])
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("A crashed worker is cleaned and restored before its error is rethrown")
    func workerFailureStillRestores() async throws {
        let fixture = try JournalFixture()
        defer { fixture.removeDirectory() }
        let events = EventRecorder()

        do {
            try await ConfigurationGateSupervisor.run(
                worker: {
                    await events.record("worker")
                    throw SimulatedFailure.workerCrash
                },
                cleanupWorker: { await events.record("cleanup") },
                restoreOriginals: { await events.record("restore") },
                commitRestoration: {
                    await events.record("commit")
                    try ConfigurationJournalStore.remove(fixture.journalURL)
                }
            )
            Issue.record("Expected the worker failure to be rethrown")
        } catch let error as SimulatedFailure {
            #expect(error == .workerCrash)
        }

        #expect(await events.snapshot() == ["worker", "cleanup", "restore", "commit"])
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Task cancellation cannot skip worker cleanup or restoration")
    func taskCancellationStillCleansAndRestores() async throws {
        let fixture = try JournalFixture()
        defer { fixture.removeDirectory() }
        let events = EventRecorder()

        let supervision = Task {
            try await ConfigurationGateSupervisor.run(
                worker: {
                    await events.record("worker")
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        await events.record("worker-cancelled")
                        throw error
                    }
                },
                cleanupWorker: { await events.record("cleanup") },
                restoreOriginals: { await events.record("restore") },
                commitRestoration: {
                    await events.record("commit")
                    try ConfigurationJournalStore.remove(fixture.journalURL)
                }
            )
        }

        await events.wait(untilRecorded: "worker")
        supervision.cancel()
        do {
            try await supervision.value
            Issue.record("Expected cancellation to be rethrown after restoration")
        } catch is CancellationError {
            // Expected after the non-cancelled recovery sequence completes.
        }

        #expect(
            await events.snapshot()
                == ["worker", "worker-cancelled", "cleanup", "restore", "commit"]
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Cleanup failure blocks restoration and retains the journal")
    func cleanupFailureBlocksRestoration() async throws {
        let fixture = try JournalFixture()
        defer { fixture.removeDirectory() }
        let events = EventRecorder()

        do {
            try await ConfigurationGateSupervisor.run(
                worker: { await events.record("worker") },
                cleanupWorker: {
                    await events.record("cleanup")
                    throw SimulatedFailure.cleanupIncomplete
                },
                restoreOriginals: { await events.record("restore") },
                commitRestoration: {
                    await events.record("commit")
                    try ConfigurationJournalStore.remove(fixture.journalURL)
                }
            )
            Issue.record("Expected cleanup failure")
        } catch let error as ConfigurationGateSupervisorError {
            guard case let .cleanup(underlying) = error else {
                Issue.record("Expected a cleanup failure, got \(error)")
                return
            }
            #expect(underlying as? SimulatedFailure == .cleanupIncomplete)
        }

        #expect(await events.snapshot() == ["worker", "cleanup"])
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test(
        "Restoration failure or timeout retains the journal",
        arguments: [SimulatedFailure.restoration, SimulatedFailure.restorationTimeout]
    )
    func restorationFailureRetainsJournal(_ failure: SimulatedFailure) async throws {
        let fixture = try JournalFixture()
        defer { fixture.removeDirectory() }
        let events = EventRecorder()

        do {
            try await ConfigurationGateSupervisor.run(
                worker: { await events.record("worker") },
                cleanupWorker: { await events.record("cleanup") },
                restoreOriginals: {
                    await events.record("restore")
                    throw failure
                },
                commitRestoration: {
                    await events.record("commit")
                    try ConfigurationJournalStore.remove(fixture.journalURL)
                }
            )
            Issue.record("Expected restoration failure")
        } catch let error as ConfigurationGateSupervisorError {
            guard case let .restoration(underlying) = error else {
                Issue.record("Expected a restoration failure, got \(error)")
                return
            }
            #expect(underlying as? SimulatedFailure == failure)
        }

        #expect(await events.snapshot() == ["worker", "cleanup", "restore"])
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Worker process identities are durably replaced in deterministic order")
    func workerIdentityJournal() throws {
        let fixture = try JournalFixture()
        defer { fixture.removeDirectory() }
        let identities: Set<ProcessIdentity> = [
            .init(pid: 41, processStartTime: 9),
            .init(pid: 7, processStartTime: 5),
            .init(pid: 41, processStartTime: 3),
        ]

        try ConfigurationJournalStore.updateWorkerIdentities(
            identities,
            at: fixture.journalURL
        )

        let loaded = try ConfigurationJournalStore.load(from: fixture.journalURL)
        #expect(
            loaded.workerProcessIdentities == [
                .init(pid: 7, processStartTime: 5),
                .init(pid: 41, processStartTime: 3),
                .init(pid: 41, processStartTime: 9),
            ]
        )
        #expect(loaded.model.value == .string("original-model"))
        #expect(loaded.thinking.value == .string("original-thinking"))
    }
}

enum SimulatedFailure: Error, Equatable, Sendable {
    case workerCrash
    case cleanupIncomplete
    case restoration
    case restorationTimeout
}

private actor EventRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func wait(untilRecorded event: String) async {
        while !events.contains(event) {
            await Task.yield()
        }
    }
}

private struct JournalFixture: Sendable {
    let directoryURL: URL
    let journalURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonConfigurationSupervisorTests")
            .appending(path: UUID().uuidString)
        journalURL = directoryURL.appending(path: "journal.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try ConfigurationJournalStore.save(
            ConfigurationJournal(
                formatVersion: 1,
                executablePath: "/usr/bin/false",
                workingDirectory: directoryURL.path,
                sessionID: "offline-test-session",
                createdAtUnixMilliseconds: 1,
                model: .init(optionID: "model", value: .string("original-model")),
                thinking: .init(optionID: "thinking", value: .string("original-thinking"))
            ),
            to: journalURL
        )
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
