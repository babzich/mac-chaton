import Darwin
import Foundation
import LeChatonCore

@main
struct ACPProbeMain {
    private enum Command: String {
        case smoke
        case create
        case load
        case replayMatrix = "replay-matrix"
        case configGate = "config-gate"
        case configWorker = "config-worker"
        case cancel
        case gate
        case help
    }

    private struct Options {
        var command: Command = .smoke
        var vibePath: String?
        var cwd = FileManager.default.currentDirectoryPath
        var inlinePrompt = "Reply with a short compatibility confirmation."
        var promptFile: String?
        var followUpFile: String?
        var promptSpec: String?
        var sessionID: String?
        var historyKind: HistoryKind?
        var traceID = "manual-load"
        var freshProcessOrdinal = 1
        var manifest: String?
        var manifestOut: String?
        var journal: String?
        var cancelAfter = 2.0
        var workerTimeout = 300.0
        var autoAllowPermissions = false
        var confirmedLiveVibe = false
    }

    static func main() async {
        do {
            let options = try parseArguments()
            if options.command == .help {
                printUsage()
                return
            }
            if options.command != .configWorker {
                guard options.confirmedLiveVibe else {
                    throw ProbeError.invalidInput("pass --confirm-live-vibe to run an opt-in live probe")
                }
            }
            try await run(options)
        } catch {
            ProbeOutput.error("ACPProbe failed: \(error)")
            exit(1)
        }
    }

    private static func run(_ options: Options) async throws {
        if options.command == .configWorker {
            let journalURL = try requiredURL(options.journal, name: "--journal")
            try await ConfigurationGate.runWorker(journalURL: journalURL)
            return
        }

        let executable = try VibeLocator().locate(explicitPath: options.vibePath)
        let cwd = canonicalURL(options.cwd)
        let permissionPolicy: PermissionPolicy = options.autoAllowPermissions ? .allowOnce : .reject

        switch options.command {
        case .smoke:
            if let sessionID = options.sessionID {
                _ = try await HistoryProbe.load(
                    session: .init(kind: options.historyKind ?? .text, sessionID: sessionID),
                    traceID: options.traceID,
                    freshProcessOrdinal: options.freshProcessOrdinal,
                    followUpPrompt: options.inlinePrompt,
                    executable: executable,
                    cwd: cwd,
                    permissionPolicy: permissionPolicy
                )
            } else {
                _ = try await HistoryProbe.create(
                    kind: options.historyKind ?? .text,
                    prompt: options.inlinePrompt,
                    executable: executable,
                    cwd: cwd,
                    permissionPolicy: permissionPolicy
                )
            }

        case .create:
            let kind = try required(options.historyKind, name: "--history-kind")
            let prompt = try readPrompt(from: requiredURL(options.promptFile, name: "--prompt-file"))
            _ = try await HistoryProbe.create(
                kind: kind,
                prompt: prompt,
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )

        case .load:
            let sessionID = try required(options.sessionID, name: "--session-id")
            let kind = try required(options.historyKind, name: "--history-kind")
            let followUp = try options.followUpFile.map { try readPrompt(from: canonicalURL($0)) }
            _ = try await HistoryProbe.load(
                session: .init(kind: kind, sessionID: sessionID),
                traceID: options.traceID,
                freshProcessOrdinal: options.freshProcessOrdinal,
                followUpPrompt: followUp,
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )

        case .replayMatrix:
            let manifest = try loadJSON(
                SessionManifest.self,
                from: requiredURL(options.manifest, name: "--manifest")
            ).validated()
            let prompts = try loadJSON(
                LiveGatePromptSpec.self,
                from: requiredURL(options.promptSpec, name: "--prompt-spec")
            ).validated()
            _ = try await runReplayMatrix(
                manifest: manifest,
                prompts: prompts,
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )

        case .configGate:
            let sessionID = try required(options.sessionID, name: "--session-id")
            try await ConfigurationGate.supervise(
                executable: executable,
                cwd: cwd,
                sessionID: sessionID,
                journalURL: configurationJournalURL(options.journal),
                workerTimeout: .seconds(options.workerTimeout)
            )

        case .cancel:
            let sessionID = try required(options.sessionID, name: "--session-id")
            let prompt = try readPrompt(from: requiredURL(options.promptFile, name: "--prompt-file"))
            let followUp = try options.followUpFile.map { try readPrompt(from: canonicalURL($0)) }
            try await CancellationProbe.run(
                sessionID: sessionID,
                prompt: prompt,
                followUpPrompt: followUp,
                cancelAfter: .seconds(options.cancelAfter),
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )

        case .gate:
            guard options.autoAllowPermissions else {
                throw ProbeError.invalidInput("gate requires --auto-allow-permissions for tool and cancellation coverage")
            }
            let prompts = try loadJSON(
                LiveGatePromptSpec.self,
                from: requiredURL(options.promptSpec, name: "--prompt-spec")
            ).validated()
            let manifest = try await createHistories(
                prompts: prompts,
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )
            if let manifestOut = options.manifestOut {
                try writeJSON(manifest, to: canonicalURL(manifestOut))
            }
            _ = try await runReplayMatrix(
                manifest: manifest,
                prompts: prompts,
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )
            let configurationSession = try manifest.session(for: .text)
            try await ConfigurationGate.supervise(
                executable: executable,
                cwd: cwd,
                sessionID: configurationSession.sessionID,
                journalURL: configurationJournalURL(options.journal),
                workerTimeout: .seconds(options.workerTimeout)
            )
            let cancellationSession = try manifest.session(for: .tool)
            try await CancellationProbe.run(
                sessionID: cancellationSession.sessionID,
                prompt: prompts.cancellationPrompt,
                followUpPrompt: prompts.cancellationFollowUpPrompt,
                cancelAfter: .seconds(options.cancelAfter),
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            )
            ProbeOutput.emit([
                "record": .string("live_gate"),
                "status": .string("passed"),
                "loadTraceCount": .integer(12),
                "configurationOriginalsReobserved": .bool(true),
                "cancellationDescendantsRemaining": .integer(0),
            ])

        case .configWorker, .help:
            break
        }
    }

    private static func createHistories(
        prompts: LiveGatePromptSpec,
        executable: VibeExecutable,
        cwd: URL,
        permissionPolicy: PermissionPolicy
    ) async throws -> SessionManifest {
        var histories: [HistorySession] = []
        for kind in HistoryKind.allCases {
            let prompt = try prompts.prompt(for: kind)
            histories.append(try await HistoryProbe.create(
                kind: kind,
                prompt: prompt.initialPrompt,
                executable: executable,
                cwd: cwd,
                permissionPolicy: permissionPolicy
            ))
        }
        return try SessionManifest(histories: histories).validated()
    }

    @discardableResult
    private static func runReplayMatrix(
        manifest: SessionManifest,
        prompts: LiveGatePromptSpec,
        executable: VibeExecutable,
        cwd: URL,
        permissionPolicy: PermissionPolicy
    ) async throws -> ReplayCoverage {
        var aggregate = ReplayCoverage()
        var coverageByKind: [HistoryKind: ReplayCoverage] = [:]
        var traceCount = 0
        for kind in HistoryKind.allCases {
            let session = try manifest.session(for: kind)
            let prompt = try prompts.prompt(for: kind)
            for processOrdinal in 1...3 {
                let traceID = "\(kind.rawValue)-load-\(processOrdinal)"
                let coverage = try await HistoryProbe.load(
                    session: session,
                    traceID: traceID,
                    freshProcessOrdinal: processOrdinal,
                    followUpPrompt: prompt.followUpPrompt,
                    executable: executable,
                    cwd: cwd,
                    permissionPolicy: permissionPolicy
                )
                switch kind {
                case .text where coverage.messages == 0:
                    throw ProbeError.compatibility("\(traceID) replayed no message history")
                case .reasoning where coverage.reasoning == 0:
                    throw ProbeError.compatibility("\(traceID) replayed no reasoning history")
                case .tool where coverage.tools == 0:
                    throw ProbeError.compatibility("\(traceID) replayed no tool history")
                default:
                    break
                }
                aggregate = aggregate + coverage
                coverageByKind[kind] = (coverageByKind[kind] ?? ReplayCoverage()) + coverage
                traceCount += 1
            }
        }

        guard traceCount == 12 else {
            throw ProbeError.compatibility("expected 12 fresh-process load traces, observed \(traceCount)")
        }
        guard (coverageByKind[.text]?.messages ?? 0) > 0 else {
            throw ProbeError.compatibility("replay had no message coverage")
        }
        guard (coverageByKind[.reasoning]?.reasoning ?? 0) > 0 else {
            throw ProbeError.compatibility("replay had no reasoning coverage")
        }
        guard (coverageByKind[.tool]?.tools ?? 0) > 0 else {
            throw ProbeError.compatibility("replay had no replayable tool coverage")
        }
        ProbeOutput.emit([
            "record": .string("replay_matrix"),
            "status": .string("passed"),
            "traceCount": .integer(Int64(traceCount)),
            "messageEvents": .integer(Int64(aggregate.messages)),
            "reasoningEvents": .integer(Int64(aggregate.reasoning)),
            "toolEvents": .integer(Int64(aggregate.tools)),
            "planReplay": .string(aggregate.plans == 0 ? "unsupported/transient" : "observed/non-authoritative"),
        ])
        return aggregate
    }

    private static func parseArguments() throws -> Options {
        var options = Options()
        var index = 1
        if index < CommandLine.arguments.count, !CommandLine.arguments[index].hasPrefix("-") {
            guard let command = Command(rawValue: CommandLine.arguments[index]) else {
                throw ProbeError.invalidInput("unknown command \(CommandLine.arguments[index])")
            }
            options.command = command
            index += 1
        }

        while index < CommandLine.arguments.count {
            let argument = CommandLine.arguments[index]
            func value() throws -> String {
                guard index + 1 < CommandLine.arguments.count else {
                    throw ProbeError.invalidInput("missing value for \(argument)")
                }
                index += 1
                return CommandLine.arguments[index]
            }

            switch argument {
            case "--vibe-path": options.vibePath = try value()
            case "--cwd": options.cwd = try value()
            case "--prompt": options.inlinePrompt = try value()
            case "--prompt-file": options.promptFile = try value()
            case "--follow-up-file": options.followUpFile = try value()
            case "--prompt-spec": options.promptSpec = try value()
            case "--session-id", "--load-session": options.sessionID = try value()
            case "--history-kind":
                let raw = try value()
                guard let kind = HistoryKind(rawValue: raw) else {
                    throw ProbeError.invalidInput("unknown history kind \(raw)")
                }
                options.historyKind = kind
            case "--trace-id": options.traceID = try value()
            case "--fresh-process-ordinal":
                let raw = try value()
                guard let ordinal = Int(raw), ordinal > 0 else {
                    throw ProbeError.invalidInput("invalid fresh-process ordinal \(raw)")
                }
                options.freshProcessOrdinal = ordinal
            case "--manifest": options.manifest = try value()
            case "--manifest-out": options.manifestOut = try value()
            case "--journal": options.journal = try value()
            case "--cancel-after":
                let raw = try value()
                guard let seconds = Double(raw), seconds >= 0 else {
                    throw ProbeError.invalidInput("invalid cancellation delay \(raw)")
                }
                options.cancelAfter = seconds
            case "--worker-timeout":
                let raw = try value()
                guard let seconds = Double(raw), seconds > 0 else {
                    throw ProbeError.invalidInput("invalid worker timeout \(raw)")
                }
                options.workerTimeout = seconds
            case "--auto-allow-permissions": options.autoAllowPermissions = true
            case "--confirm-live-vibe": options.confirmedLiveVibe = true
            case "--help", "-h": options.command = .help
            default: throw ProbeError.invalidInput("unknown argument \(argument)")
            }
            index += 1
        }
        return options
    }

    private static func configurationJournalURL(_ explicit: String?) -> URL {
        if let explicit { return canonicalURL(explicit) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.vincentbach.LeChaton/Recovery")
            .appending(path: "ACPProbeConfigurationJournal.json")
    }

    private static func required<T>(_ value: T?, name: String) throws -> T {
        guard let value else { throw ProbeError.invalidInput("missing \(name)") }
        return value
    }

    private static func requiredURL(_ value: String?, name: String) throws -> URL {
        canonicalURL(try required(value, name: name))
    }

    private static func printUsage() {
        print("""
        ACPProbe <command> --confirm-live-vibe [options]

          create         Create one history from --history-kind and --prompt-file.
          load           Load one --session-id in a fresh process and emit a sanitized trace.
          replay-matrix  Load four sessions from --manifest three times each using --prompt-spec.
          config-gate    Supervise model/thinking mutation and journal-backed restoration.
          cancel         Cancel a descendant-producing --prompt-file and report tracked identities.
          gate           Create four histories, run 12 loads, config restoration, and cancellation.
          smoke          Create or load one session (default command; accepts --prompt).

        Common: --vibe-path PATH --cwd PATH --auto-allow-permissions
        Gate:   --prompt-spec FILE [--manifest-out FILE] [--journal FILE]

        Prompt-spec JSON contains histories [{kind, initialPrompt, followUpPrompt}],
        cancellationPrompt, and cancellationFollowUpPrompt. Prompt content is never emitted.
        """)
    }
}
