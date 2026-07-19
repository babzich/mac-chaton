import Foundation
import TOMLKit

public enum VibeProviderProbeError: Error, Equatable, Sendable, CustomStringConvertible {
    case noModel
    case repositorySetupFailed
    case permissionUnavailable
    case missingStreamingResponse
    case missingToolInteraction
    case invalidToolResult
    case cleanupFailed

    public var description: String {
        switch self {
        case .noModel: "The provider test needs a model."
        case .repositorySetupFailed: "The disposable provider-test repository could not be prepared."
        case .permissionUnavailable: "Vibe requested a tool permission without an allow choice."
        case .missingStreamingResponse: "The provider did not produce a streamed response through Vibe."
        case .missingToolInteraction: "The provider did not complete the disposable file-tool check."
        case .invalidToolResult: "The disposable file-tool check returned unexpected content."
        case .cleanupFailed: "The disposable provider-test process did not clean up completely."
        }
    }
}

public extension ProviderProbeClient {
    static func live(adapter: VibeAdapter = VibeAdapter()) -> Self {
        .init { request in
            try await VibeProviderProbe(adapter: adapter).run(request)
        }
    }
}

private struct VibeProviderProbe: Sendable {
    private let adapter: VibeAdapter

    init(adapter: VibeAdapter) {
        self.adapter = adapter
    }

    func run(_ request: ProviderProbeRequest) async throws {
        guard let model = request.draft.models.first else {
            throw VibeProviderProbeError.noModel
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(
            path: "LeChaton-ProviderProbe-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let vibeHome = root.appending(path: "VibeHome", directoryHint: .isDirectory)
        let repository = root.appending(path: "Repository", directoryHint: .isDirectory)
        try manager.createDirectory(at: vibeHome, withIntermediateDirectories: true)
        try manager.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try Self.prepareRepository(repository)
        let config = Self.configuration(
            draft: request.draft,
            model: model,
            keyEnvironmentName: request.apiKeyEnvironmentName
        )
        try Data(config.utf8).write(
            to: vibeHome.appending(path: "config.toml", directoryHint: .notDirectory),
            options: .withoutOverwriting
        )

        var environment = ACPProcessEnvironment.sanitized()
        environment["VIBE_HOME"] = vibeHome.path
        if let name = request.apiKeyEnvironmentName {
            environment[name] = request.draft.apiKey
        }
        let transport = ACPTransport(configuration: .init(
            executableURL: request.executable.url,
            workingDirectory: repository,
            environment: environment,
            responseTimeout: .seconds(60),
            promptResponseTimeout: .seconds(180)
        ))

        do {
            _ = try await transport.start()
            _ = try await adapter.initializeAndValidate(
                transport: transport,
                executable: request.executable
            )
            let session = try await transport.newSession(cwd: repository)
            let observation = ProviderProbeObservation()
            let updates = await transport.updates()
            let requests = await transport.incomingRequests()
            let updateTask = Task {
                for await envelope in updates {
                    await observation.observe(envelope.payload)
                }
            }
            let permissionTask = Task {
                for await incoming in requests {
                    guard let permission = PermissionRequest(incoming) else { continue }
                    guard Self.isSafeMarkerWrite(incoming),
                          let option = permission.options.first(where: {
                        $0.kind.lowercased().contains("allow")
                            || $0.optionID.lowercased().contains("allow")
                    }) else {
                        try await transport.respondToPermissionCancellation(id: permission.requestID)
                        await observation.recordPermissionFailure()
                        continue
                    }
                    try await transport.respondToPermission(
                        id: permission.requestID,
                        selectedOptionID: option.optionID
                    )
                }
            }
            defer {
                updateTask.cancel()
                permissionTask.cancel()
            }

            _ = try await transport.prompt(
                sessionID: session.sessionID,
                text: "Create a file named lechaton-provider-probe.txt in the current repository containing exactly LECHATON_PROVIDER_OK, then reply exactly LECHATON_PROVIDER_OK."
            )
            let result = await observation.result()
            if result.permissionFailed { throw VibeProviderProbeError.permissionUnavailable }
            if !result.sawAgentText { throw VibeProviderProbeError.missingStreamingResponse }
            if !result.sawTool { throw VibeProviderProbeError.missingToolInteraction }
            let marker = repository.appending(
                path: "lechaton-provider-probe.txt",
                directoryHint: .notDirectory
            )
            guard let value = try? String(contentsOf: marker, encoding: .utf8),
                  value.trimmingCharacters(in: .whitespacesAndNewlines) == "LECHATON_PROVIDER_OK"
            else { throw VibeProviderProbeError.invalidToolResult }

            let cleanup = await transport.stop()
            guard cleanup?.survivors.isEmpty != false else {
                throw VibeProviderProbeError.cleanupFailed
            }
        } catch {
            let cleanup = await transport.stop()
            if cleanup?.survivors.isEmpty == false { throw VibeProviderProbeError.cleanupFailed }
            throw error
        }
    }

    private static func configuration(
        draft: ProviderDraft,
        model: ManagedVibeModel,
        keyEnvironmentName: String?
    ) -> String {
        let providerID = ManagedProviderIdentifiers.provider(draft.id)
        let modelAlias = ManagedProviderIdentifiers.model(model.id)
        let root = TOMLTable([
            "active_model": modelAlias,
            "enable_auto_update": false,
            "enable_notifications": false,
            "enable_telemetry": false,
            "providers": TOMLArray([
                TOMLTable([
                    "name": providerID,
                    "api_base": draft.baseURL,
                    "api_key_env_var": keyEnvironmentName ?? "",
                    "api_style": "openai",
                    "backend": "generic",
                ]),
            ]),
            "models": TOMLArray([
                TOMLTable([
                    "name": model.modelID,
                    "provider": providerID,
                    "alias": modelAlias,
                ]),
            ]),
        ])
        return root.convert()
    }

    private static func isSafeMarkerWrite(_ request: IncomingACPRequest) -> Bool {
        guard let tool = request.params?.objectValue?["toolCall"]?.objectValue else { return false }
        let operation = [tool["title"]?.stringValue, tool["kind"]?.stringValue]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard operation.contains("write") || operation.contains("edit") else { return false }
        return tool.values.contains { containsMarker($0) }
    }

    private static func containsMarker(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(string):
            string.contains("lechaton-provider-probe.txt")
        case let .array(values):
            values.contains(where: containsMarker)
        case let .object(values):
            values.values.contains(where: containsMarker)
        case .null, .bool, .integer, .double:
            false
        }
    }

    private static func prepareRepository(_ repository: URL) throws {
        let commands = [
            ["init", "--quiet"],
            ["config", "user.email", "provider-probe@lechaton.invalid"],
            ["config", "user.name", "LeChaton Provider Probe"],
            ["commit", "--allow-empty", "--quiet", "-m", "Provider probe baseline"],
        ]
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repository
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw VibeProviderProbeError.repositorySetupFailed
            }
            guard process.terminationStatus == 0 else {
                throw VibeProviderProbeError.repositorySetupFailed
            }
        }
    }
}

private actor ProviderProbeObservation {
    struct Result: Sendable {
        var sawAgentText = false
        var sawTool = false
        var permissionFailed = false
    }

    private var value = Result()

    func observe(_ update: SessionUpdate) {
        switch update {
        case let .agentMessage(_, content, _):
            if content.text?.isEmpty == false { value.sawAgentText = true }
        case .toolCallStarted, .toolCallUpdated:
            value.sawTool = true
        default:
            break
        }
    }

    func recordPermissionFailure() {
        value.permissionFailed = true
    }

    func result() -> Result { value }
}
