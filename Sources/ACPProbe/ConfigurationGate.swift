import Darwin
import Foundation
import LeChatonCore

enum ConfigurationGate {
    static let modelOptionID = "model"
    static let thinkingOptionID = "thinking"

    static func supervise(
        executable: VibeExecutable,
        cwd: URL,
        sessionID: String,
        journalURL: URL,
        workerTimeout: Duration
    ) async throws {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        defer {
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            ProbeOutput.emit([
                "record": .string("configuration_reconciliation"),
                "reason": .string("existing_journal"),
                "started": .bool(true),
            ])
            let existing = try ConfigurationJournalStore.load(from: journalURL)
            try await restore(journal: existing, journalURL: journalURL)
            try ConfigurationJournalStore.remove(journalURL)
            ProbeOutput.emit([
                "record": .string("configuration_reconciliation"),
                "reason": .string("existing_journal"),
                "originalsReobserved": .bool(true),
            ])
        }

        let original = try await queryConfiguration(
            executable: executable,
            cwd: cwd,
            sessionID: sessionID
        )
        let model = try original.option(id: modelOptionID)
        let thinking = try original.option(id: thinkingOptionID)
        let journal = ConfigurationJournal(
            formatVersion: 1,
            executablePath: executable.url.path,
            workingDirectory: cwd.path,
            sessionID: sessionID,
            createdAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            model: .init(optionID: model.id, value: model.currentValue),
            thinking: .init(optionID: thinking.id, value: thinking.currentValue)
        )
        try ConfigurationJournalStore.save(journal, to: journalURL)
        ProbeOutput.emit([
            "record": .string("configuration_journal"),
            "created": .bool(true),
            "containsTranscript": .bool(false),
        ])

        var workerError: (any Error)?
        do {
            try await runWorker(journalURL: journalURL, timeout: workerTimeout)
        } catch {
            workerError = error
        }

        do {
            try await restore(journal: journal, journalURL: journalURL)
            try ConfigurationJournalStore.remove(journalURL)
            ProbeOutput.emit([
                "record": .string("configuration_restoration"),
                "originalModelReobserved": .bool(true),
                "originalThinkingReobserved": .bool(true),
                "journalRetained": .bool(false),
            ])
        } catch {
            await reportRestorationFailure(journal: journal, error: error)
            throw ProbeError.restoration("\(error); recovery journal retained at \(journalURL.path)")
        }

        if let workerError { throw workerError }
        ProbeOutput.emit([
            "record": .string("configuration_gate"),
            "status": .string("passed"),
            "originalsReobserved": .bool(true),
        ])
    }

    static func runWorker(journalURL: URL) async throws {
        let journal = try ConfigurationJournalStore.load(from: journalURL)
        guard journal.formatVersion == 1 else {
            throw ProbeError.invalidInput("unsupported configuration journal version \(journal.formatVersion)")
        }
        let executable = try VibeLocator().locate(explicitPath: journal.executablePath)
        let cwd = canonicalURL(journal.workingDirectory)

        var snapshot = try await queryConfiguration(
            executable: executable,
            cwd: cwd,
            sessionID: journal.sessionID
        )
        let thinking = try snapshot.option(id: journal.thinking.optionID)
        if let alternate = thinking.alternateValue {
            try await setAndVerify(
                option: thinking,
                value: alternate,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
            ProbeOutput.emit(configurationStep(option: "thinking", status: "alternateValidated"))
            let current = try await queryConfiguration(executable: executable, cwd: cwd, sessionID: journal.sessionID)
            try await setAndVerify(
                option: current.option(id: journal.thinking.optionID),
                value: journal.thinking.value,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
            ProbeOutput.emit(configurationStep(option: "thinking", status: "originalRestoredBeforeModelTest"))
        } else {
            try await setAndVerify(
                option: thinking,
                value: thinking.currentValue,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
            ProbeOutput.emit(configurationStep(
                option: "thinking",
                status: "notValidated(noAlternativeAdvertised)"
            ))
        }

        snapshot = try await queryConfiguration(executable: executable, cwd: cwd, sessionID: journal.sessionID)
        let model = try snapshot.option(id: journal.model.optionID)
        if let alternate = model.alternateValue {
            try await setAndVerify(
                option: model,
                value: alternate,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
            ProbeOutput.emit(configurationStep(option: "model", status: "alternateValidated"))
        } else {
            try await setAndVerify(
                option: model,
                value: model.currentValue,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
            ProbeOutput.emit(configurationStep(
                option: "model",
                status: "notValidated(noAlternativeAdvertised)"
            ))
        }
    }

    static func queryConfiguration(
        executable: VibeExecutable,
        cwd: URL,
        sessionID: String
    ) async throws -> ConfigurationSnapshot {
        let runtime = try await ProbeRuntime.start(
            executable: executable,
            cwd: cwd,
            permissionPolicy: .reject
        )
        do {
            try await runtime.requireReady()
            let loaded = try await runtime.load(sessionID: sessionID)
            let options = loaded.configurationOptions.compactMap(ConfigurationOption.init)
            guard options.count == loaded.configurationOptions.count else {
                throw ProbeError.compatibility("a configuration option had an unsupported shape")
            }
            try await runtime.stop()
            return ConfigurationSnapshot(options: options)
        } catch {
            _ = try? await runtime.stop()
            throw error
        }
    }

    private static func setAndVerify(
        option: ConfigurationOption,
        value: JSONValue,
        executable: VibeExecutable,
        cwd: URL,
        sessionID: String
    ) async throws {
        let runtime = try await ProbeRuntime.start(
            executable: executable,
            cwd: cwd,
            permissionPolicy: .reject
        )
        do {
            try await runtime.requireReady()
            _ = try await runtime.load(sessionID: sessionID)
            var params: [String: JSONValue] = [
                "sessionId": .string(sessionID),
                "configId": .string(option.id),
                "value": value,
            ]
            if option.type == "boolean" { params["type"] = .string("boolean") }
            let requestParameters = JSONValue.object(params)
            _ = try await withTimeout(.seconds(30), operationName: "session/set_config_option") {
                try await runtime.transport.request(
                    method: "session/set_config_option",
                    params: requestParameters
                )
            }
            // A successful write is not proof of persistence. Dispose before the fresh re-query.
            try await runtime.stop()
        } catch {
            _ = try? await runtime.stop()
            throw error
        }

        let fresh = try await queryConfiguration(executable: executable, cwd: cwd, sessionID: sessionID)
        let effective = try fresh.option(id: option.id)
        guard effective.currentValue == value else {
            throw ProbeError.compatibility("configuration option \(option.id) did not retain the requested value after reload")
        }
    }

    private static func restore(journal: ConfigurationJournal, journalURL: URL) async throws {
        let executable = try VibeLocator().locate(explicitPath: journal.executablePath)
        let cwd = canonicalURL(journal.workingDirectory)
        var snapshot = try await queryConfiguration(
            executable: executable,
            cwd: cwd,
            sessionID: journal.sessionID
        )

        let model = try snapshot.option(id: journal.model.optionID)
        if model.currentValue != journal.model.value {
            try await setAndVerify(
                option: model,
                value: journal.model.value,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
        }

        // Re-query after model restoration because thinking is scoped to the active model.
        snapshot = try await queryConfiguration(executable: executable, cwd: cwd, sessionID: journal.sessionID)
        let thinking = try snapshot.option(id: journal.thinking.optionID)
        if thinking.currentValue != journal.thinking.value {
            try await setAndVerify(
                option: thinking,
                value: journal.thinking.value,
                executable: executable,
                cwd: cwd,
                sessionID: journal.sessionID
            )
        }

        let final = try await queryConfiguration(executable: executable, cwd: cwd, sessionID: journal.sessionID)
        guard
            try final.option(id: journal.model.optionID).currentValue == journal.model.value,
            try final.option(id: journal.thinking.optionID).currentValue == journal.thinking.value
        else {
            throw ProbeError.restoration("fresh reload did not re-observe the journaled originals")
        }
        _ = journalURL
    }

    private static func reportRestorationFailure(journal: ConfigurationJournal, error: any Error) async {
        var fields: [String: JSONValue] = [
            "record": .string("configuration_restoration"),
            "originalModel": journal.model.value,
            "originalThinking": journal.thinking.value,
            "journalRetained": .bool(true),
            "error": .string(String(describing: error)),
        ]
        if
            let executable = try? VibeLocator().locate(explicitPath: journal.executablePath),
            let current = try? await queryConfiguration(
                executable: executable,
                cwd: canonicalURL(journal.workingDirectory),
                sessionID: journal.sessionID
            )
        {
            fields["currentModel"] = try? current.option(id: journal.model.optionID).currentValue
            fields["currentThinking"] = try? current.option(id: journal.thinking.optionID).currentValue
        }
        ProbeOutput.emit(fields)
    }

    private static func configurationStep(option: String, status: String) -> [String: JSONValue] {
        [
            "record": .string("configuration_step"),
            "option": .string(option),
            "status": .string(status),
        ]
    }

    private static func runWorker(journalURL: URL, timeout: Duration) async throws {
        let process = Process()
        process.executableURL = canonicalURL(CommandLine.arguments[0])
        process.arguments = ["config-worker", "--journal", journalURL.path]
        process.currentDirectoryURL = URL(filePath: FileManager.default.currentDirectoryPath)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()

        guard let identity = ProcessInspector.snapshot(pid: process.processIdentifier)?.identity else {
            process.terminate()
            throw ProbeError.process("could not establish the configuration worker identity")
        }
        let tracker = ProcessTreeTerminator(root: identity)
        _ = await tracker.refresh()
        let cancellation = SupervisorCancellation()
        let signals = SupervisorSignals(cancellation: cancellation, process: process)
        signals.start()
        defer { signals.stop(resetHandlers: false) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var timedOut = false
        while process.isRunning, clock.now < deadline, !cancellation.isCancelled {
            _ = await tracker.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            timedOut = clock.now >= deadline
            let cleanup = await tracker.terminate(gracePeriod: .seconds(2))
            if !cleanup.survivors.isEmpty {
                throw ProbeError.process("configuration worker cleanup left \(cleanup.survivors.count) survivor(s)")
            }
        } else {
            let cleanup = await tracker.terminate(gracePeriod: .milliseconds(10))
            if !cleanup.survivors.isEmpty {
                throw ProbeError.process("configuration worker left \(cleanup.survivors.count) descendant(s)")
            }
        }
        process.waitUntilExit()

        if timedOut { throw ProbeError.timeout("configuration worker") }
        if cancellation.isCancelled { throw CancellationError() }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ProbeError.process(
                "configuration worker exited with status \(process.terminationStatus)"
            )
        }
    }
}

enum ConfigurationJournalStore {
    static func save(_ journal: ConfigurationJournal, to url: URL) throws {
        try writeJSON(journal, to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func load(from url: URL) throws -> ConfigurationJournal {
        try loadJSON(ConfigurationJournal.self, from: url)
    }

    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = Darwin.close(descriptor)
    }
}

private final class SupervisorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class SupervisorSignals: @unchecked Sendable {
    private let cancellation: SupervisorCancellation
    private let process: Process
    private var sources: [DispatchSourceSignal] = []

    init(cancellation: SupervisorCancellation, process: Process) {
        self.cancellation = cancellation
        self.process = process
    }

    func start() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [cancellation, process] in
                cancellation.cancel()
                if process.isRunning { process.terminate() }
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop(resetHandlers: Bool = true) {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        if resetHandlers {
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
    }
}
