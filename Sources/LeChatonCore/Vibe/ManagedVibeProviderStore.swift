import Foundation
import TOMLKit

public struct ProviderConfigurationClient: Sendable {
    public let read: @Sendable () throws -> Data?
    public let commit: @Sendable (_ expected: Data?, _ replacement: Data) throws -> URL

    public init(
        read: @escaping @Sendable () throws -> Data?,
        commit: @escaping @Sendable (_ expected: Data?, _ replacement: Data) throws -> URL
    ) {
        self.read = read
        self.commit = commit
    }

    public static func live(configURL: URL) -> Self {
        .init(
            read: {
                guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
                return try Data(contentsOf: configURL)
            },
            commit: { expected, replacement in
                try ProviderConfigurationFile.commit(
                    configURL: configURL,
                    expected: expected,
                    replacement: replacement
                )
            }
        )
    }
}

public actor ManagedVibeProviderStore {
    private struct ParsedProvider: Sendable {
        let provider: ManagedVibeProvider
        let modelIdentifiers: [UUID: String]
        let keyReference: String?
    }

    private struct ParsedConfiguration {
        let root: TOMLTable
        let providers: [ParsedProvider]
    }

    private struct Snapshot {
        let data: Data?
        let providers: [ParsedProvider]
    }

    private let configuration: ProviderConfigurationClient
    private let secrets: any ProviderSecretStore
    private let probe: ProviderProbeClient
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    private var snapshot: Snapshot?
    private var testedDrafts: [UUID: ProviderDraft] = [:]

    public init(
        configuration: ProviderConfigurationClient,
        secrets: any ProviderSecretStore,
        probe: ProviderProbeClient,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.secrets = secrets
        self.probe = probe
        self.makeUUID = makeUUID
        self.now = now
    }

    @discardableResult
    public func reload() throws -> [ManagedVibeProvider] {
        let data = try configuration.read()
        let parsed = try Self.parse(data)
        snapshot = .init(data: data, providers: parsed.providers)
        testedDrafts.removeAll()
        return parsed.providers.map(\.provider)
    }

    public func providers() throws -> [ManagedVibeProvider] {
        try currentSnapshot().providers.map(\.provider)
    }

    public func test(
        draft: ProviderDraft,
        executable: VibeExecutable
    ) async throws -> ProviderTestResult {
        _ = try currentSnapshot()
        let normalized = try await normalizedDraft(draft)
        let environmentName = normalized.authMode == .bearer
            ? "LECHATON_PROVIDER_TEST_\(ManagedProviderIdentifiers.compact(makeUUID()).uppercased())"
            : nil
        try await probe.run(.init(
            draft: normalized,
            executable: executable,
            apiKeyEnvironmentName: environmentName
        ))
        let result = ProviderTestResult(
            id: makeUUID(),
            providerID: normalized.id,
            testedAt: now()
        )
        testedDrafts[result.id] = normalized
        return result
    }

    @discardableResult
    public func save(
        draft: ProviderDraft,
        testResultID: UUID
    ) async throws -> ManagedVibeProvider {
        let loaded = try currentSnapshot()
        guard let testedDraft = testedDrafts[testResultID] else {
            throw ManagedVibeProviderError.testRequired
        }
        let normalized = try await normalizedDraft(draft)
        guard testedDraft == normalized else {
            throw ManagedVibeProviderError.testedDraftChanged
        }

        let current = loaded.providers.first { $0.provider.id == normalized.id }
        if let activeModelID = current?.provider.activeModelID,
           !normalized.models.contains(where: { $0.id == activeModelID })
        {
            throw ManagedVibeProviderError.activeModelRemoval
        }
        let oldKeyReference = current?.keyReference
        var stagedKeyReference: String?
        var selectedKeyReference = oldKeyReference

        if normalized.authMode == .bearer, !draft.apiKey.isEmpty {
            let reference = ManagedProviderIdentifiers.key(
                providerID: normalized.id,
                keyID: makeUUID()
            )
            try await secrets.write(normalized.apiKey, account: reference)
            stagedKeyReference = reference
            selectedKeyReference = reference
        } else if normalized.authMode == .keylessLoopback {
            selectedKeyReference = nil
        }

        guard normalized.authMode != .bearer || selectedKeyReference != nil else {
            throw ManagedVibeProviderError.missingAPIKey
        }

        do {
            let parsed = try currentParsedConfiguration()
            let providerTable = Self.providerTable(
                draft: normalized,
                keyReference: selectedKeyReference
            )
            let modelTables = normalized.models.map {
                Self.modelTable(providerID: normalized.id, model: $0)
            }
            Self.replaceManagedProvider(
                in: parsed.root,
                providerID: normalized.id,
                providerTable: providerTable,
                modelTables: modelTables
            )
            let replacement = Data(parsed.root.convert().utf8)
            _ = try configuration.commit(loaded.data, replacement)
            try acceptCommitted(replacement)
        } catch {
            if let stagedKeyReference {
                try? await secrets.delete(account: stagedKeyReference)
            }
            throw error
        }

        if let oldKeyReference, oldKeyReference != selectedKeyReference {
            try await secrets.delete(account: oldKeyReference)
        }
        testedDrafts.removeValue(forKey: testResultID)
        guard let saved = try currentSnapshot().providers.first(where: {
            $0.provider.id == normalized.id
        }) else {
            throw ManagedVibeProviderError.providerNotFound
        }
        return saved.provider
    }

    public func activate(providerID: UUID, modelID: UUID) throws {
        let loaded = try currentSnapshot()
        guard let provider = loaded.providers.first(where: { $0.provider.id == providerID }) else {
            throw ManagedVibeProviderError.providerNotFound
        }
        guard let modelIdentifier = provider.modelIdentifiers[modelID] else {
            throw ManagedVibeProviderError.modelNotFound
        }
        let parsed = try currentParsedConfiguration()
        parsed.root["active_model"] = modelIdentifier
        let replacement = Data(parsed.root.convert().utf8)
        _ = try configuration.commit(loaded.data, replacement)
        try acceptCommitted(replacement)
    }

    public func remove(providerID: UUID) async throws {
        let loaded = try currentSnapshot()
        guard let provider = loaded.providers.first(where: { $0.provider.id == providerID }) else {
            throw ManagedVibeProviderError.providerNotFound
        }
        guard provider.provider.status != .active else {
            throw ManagedVibeProviderError.providerIsActive
        }

        let parsed = try currentParsedConfiguration()
        Self.removeManagedProvider(in: parsed.root, providerID: providerID)
        let replacement = Data(parsed.root.convert().utf8)
        _ = try configuration.commit(loaded.data, replacement)
        try acceptCommitted(replacement)
        if let keyReference = provider.keyReference {
            try await secrets.delete(account: keyReference)
        }
    }

    public func runtimeEnvironment() async throws -> ProviderRuntimeEnvironment? {
        let loaded = try currentSnapshot()
        let current = try configuration.read()
        guard current == loaded.data else { throw ManagedVibeProviderError.staleConfiguration }
        guard let active = loaded.providers.first(where: { $0.provider.status == .active }) else {
            return nil
        }
        guard active.provider.authMode == .bearer else { return nil }
        guard let keyReference = active.keyReference,
              let secret = try await secrets.read(account: keyReference),
              !secret.isEmpty
        else { throw ManagedVibeProviderError.secretUnavailable }
        return .init(name: keyReference, secret: secret)
    }

    private func currentSnapshot() throws -> Snapshot {
        if let snapshot { return snapshot }
        _ = try reload()
        guard let snapshot else { throw ManagedVibeProviderError.malformedConfiguration }
        return snapshot
    }

    private func currentParsedConfiguration() throws -> ParsedConfiguration {
        let loaded = try currentSnapshot()
        let current = try configuration.read()
        guard current == loaded.data else { throw ManagedVibeProviderError.staleConfiguration }
        return try Self.parse(current)
    }

    private func acceptCommitted(_ replacement: Data) throws {
        let parsed = try Self.parse(replacement)
        snapshot = .init(data: replacement, providers: parsed.providers)
        testedDrafts.removeAll()
    }

    private func normalizedDraft(_ draft: ProviderDraft) async throws -> ProviderDraft {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ManagedVibeProviderError.invalidName }
        let endpoint = try Self.normalizedEndpoint(draft.baseURL, authMode: draft.authMode)

        var seenModelIDs: Set<String> = []
        let models = try draft.models.map { model -> ManagedVibeModel in
            let modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else { throw ManagedVibeProviderError.missingModel }
            guard seenModelIDs.insert(modelID).inserted else {
                throw ManagedVibeProviderError.duplicateModelID(modelID)
            }
            let displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                id: model.id,
                modelID: modelID,
                displayName: displayName.isEmpty ? modelID : displayName
            )
        }
        guard !models.isEmpty else { throw ManagedVibeProviderError.missingModel }

        var apiKey = draft.apiKey
        if draft.authMode == .bearer, apiKey.isEmpty {
            let loaded = try currentSnapshot()
            guard let existing = loaded.providers.first(where: { $0.provider.id == draft.id }),
                  let keyReference = existing.keyReference,
                  let retained = try await secrets.read(account: keyReference),
                  !retained.isEmpty
            else { throw ManagedVibeProviderError.missingAPIKey }
            apiKey = retained
        }
        if draft.authMode == .keylessLoopback { apiKey = "" }

        return .init(
            id: draft.id,
            name: name,
            baseURL: endpoint.absoluteString,
            authMode: draft.authMode,
            apiKey: apiKey,
            models: models
        )
    }

    static func normalizedEndpoint(_ raw: String, authMode: ProviderAuthMode) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host,
              !rawHost.isEmpty,
              ["http", "https"].contains(scheme)
        else { throw ManagedVibeProviderError.invalidEndpoint }
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard components.user == nil, components.password == nil else {
            throw ManagedVibeProviderError.endpointContainsCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw ManagedVibeProviderError.endpointContainsQueryOrFragment
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        if scheme == "http", !loopback {
            throw ManagedVibeProviderError.insecureRemoteEndpoint
        }
        if authMode == .keylessLoopback, !loopback {
            throw ManagedVibeProviderError.keylessRequiresLoopback
        }
        components.scheme = scheme
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let normalized = components.url else {
            throw ManagedVibeProviderError.invalidEndpoint
        }
        return normalized
    }

    private static func parse(_ data: Data?) throws -> ParsedConfiguration {
        let string: String
        if let data {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw ManagedVibeProviderError.malformedConfiguration
            }
            string = decoded
        } else {
            string = ""
        }
        let root: TOMLTable
        do {
            root = try TOMLTable(string: string)
        } catch {
            throw ManagedVibeProviderError.malformedConfiguration
        }
        let active = root["active_model"]?.string
        let rawProviders = root["providers"]?.array.map(Array.init) ?? []
        let rawModels = root["models"]?.array.map(Array.init) ?? []

        var managedProviders: [UUID: (table: TOMLTable, identifier: String)] = [:]
        for raw in rawProviders {
            guard let table = raw.table, let identifier = table["name"]?.string else { continue }
            guard identifier.hasPrefix(ManagedProviderIdentifiers.prefix) else { continue }
            guard let idRaw = table["lechaton_id"]?.string,
                  let id = UUID(uuidString: idRaw),
                  identifier == ManagedProviderIdentifiers.provider(id)
            else { throw ManagedVibeProviderError.managedIdentifierCollision(identifier) }
            guard managedProviders[id] == nil else {
                throw ManagedVibeProviderError.managedIdentifierCollision(identifier)
            }
            managedProviders[id] = (table, identifier)
        }

        var managedModels: [UUID: [(ManagedVibeModel, String)]] = [:]
        var seenModelIDs: Set<UUID> = []
        var seenModelAliases: Set<String> = []
        for raw in rawModels {
            guard let table = raw.table else { continue }
            let alias = table["alias"]?.string
            let providerIdentifier = table["provider"]?.string
            let hasManagedAlias = alias?.hasPrefix(ManagedProviderIdentifiers.prefix) == true
            let targetsManagedProvider = providerIdentifier?.hasPrefix(ManagedProviderIdentifiers.prefix) == true
            guard hasManagedAlias || targetsManagedProvider else { continue }
            guard let alias else {
                throw ManagedVibeProviderError.managedIdentifierCollision(providerIdentifier ?? "lechaton_model")
            }
            guard let idRaw = table["lechaton_id"]?.string,
                  let id = UUID(uuidString: idRaw),
                  alias == ManagedProviderIdentifiers.model(id),
                  let providerIdentifier,
                  let provider = managedProviders.first(where: { $0.value.identifier == providerIdentifier }),
                  let modelID = table["name"]?.string,
                  !modelID.isEmpty,
                  seenModelIDs.insert(id).inserted,
                  seenModelAliases.insert(alias).inserted
            else { throw ManagedVibeProviderError.managedIdentifierCollision(alias) }
            let displayName = table["lechaton_display_name"]?.string ?? modelID
            managedModels[provider.key, default: []].append((
                .init(id: id, modelID: modelID, displayName: displayName),
                alias
            ))
        }
        if let active, active.hasPrefix(ManagedProviderIdentifiers.prefix),
           !seenModelAliases.contains(active)
        {
            throw ManagedVibeProviderError.managedIdentifierCollision(active)
        }

        let providers = try managedProviders.map { id, entry -> ParsedProvider in
            let table = entry.table
            guard let name = table["lechaton_name"]?.string,
                  let endpointRaw = table["api_base"]?.string,
                  let authRaw = table["lechaton_auth_mode"]?.string,
                  let authMode = ProviderAuthMode(rawValue: authRaw)
            else { throw ManagedVibeProviderError.malformedConfiguration }
            let endpoint = try normalizedEndpoint(endpointRaw, authMode: authMode)
            let models = managedModels[id] ?? []
            guard !models.isEmpty else { throw ManagedVibeProviderError.missingModel }
            let aliases = Dictionary(uniqueKeysWithValues: models.map { ($0.0.id, $0.1) })
            let isActive = active.map(aliases.values.contains) ?? false
            let activeModelID = aliases.first(where: { $0.value == active })?.key
            let keyReference = table["api_key_env_var"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            if authMode == .bearer, keyReference == nil {
                throw ManagedVibeProviderError.malformedConfiguration
            }
            return .init(
                provider: .init(
                    id: id,
                    name: name,
                    baseURL: endpoint,
                    authMode: authMode,
                    models: models.map(\.0),
                    status: isActive ? .active : .configured,
                    activeModelID: activeModelID
                ),
                modelIdentifiers: aliases,
                keyReference: keyReference
            )
        }
        return .init(
            root: root,
            providers: providers.sorted {
                $0.provider.name.localizedStandardCompare($1.provider.name) == .orderedAscending
            }
        )
    }

    private static func providerTable(
        draft: ProviderDraft,
        keyReference: String?
    ) -> TOMLTable {
        let table = TOMLTable()
        table["name"] = ManagedProviderIdentifiers.provider(draft.id)
        table["api_base"] = draft.baseURL
        table["api_key_env_var"] = keyReference ?? ""
        table["api_style"] = "openai"
        table["backend"] = "generic"
        table["lechaton_id"] = draft.id.uuidString.lowercased()
        table["lechaton_name"] = draft.name
        table["lechaton_auth_mode"] = draft.authMode.rawValue
        return table
    }

    private static func modelTable(providerID: UUID, model: ManagedVibeModel) -> TOMLTable {
        let table = TOMLTable()
        table["name"] = model.modelID
        table["provider"] = ManagedProviderIdentifiers.provider(providerID)
        table["alias"] = ManagedProviderIdentifiers.model(model.id)
        table["lechaton_id"] = model.id.uuidString.lowercased()
        table["lechaton_display_name"] = model.displayName
        return table
    }

    private static func replaceManagedProvider(
        in root: TOMLTable,
        providerID: UUID,
        providerTable: TOMLTable,
        modelTables: [TOMLTable]
    ) {
        removeManagedProvider(in: root, providerID: providerID)
        var providers = root["providers"]?.array.map(Array.init) ?? []
        providers.append(providerTable.tomlValue)
        root["providers"] = TOMLArray(providers)
        var models = root["models"]?.array.map(Array.init) ?? []
        models.append(contentsOf: modelTables.map(\.tomlValue))
        root["models"] = TOMLArray(models)
    }

    private static func removeManagedProvider(in root: TOMLTable, providerID: UUID) {
        let providerIdentifier = ManagedProviderIdentifiers.provider(providerID)
        let providers = (root["providers"]?.array.map(Array.init) ?? []).filter {
            $0.table?["name"]?.string != providerIdentifier
        }
        let models = (root["models"]?.array.map(Array.init) ?? []).filter {
            $0.table?["provider"]?.string != providerIdentifier
        }
        root["providers"] = TOMLArray(providers)
        root["models"] = TOMLArray(models)
    }
}

private enum ProviderConfigurationFile {
    static func commit(configURL: URL, expected: Data?, replacement: Data) throws -> URL {
        let manager = FileManager.default
        let directory = configURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let current = manager.fileExists(atPath: configURL.path)
            ? try Data(contentsOf: configURL)
            : nil
        guard current == expected else { throw ManagedVibeProviderError.staleConfiguration }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = directory.appending(
            path: "config.toml.lechaton-\(timestamp)-\(UUID().uuidString).bak",
            directoryHint: .notDirectory
        )
        try (current ?? Data()).write(to: backup, options: .withoutOverwriting)

        let temporary = directory.appending(
            path: ".config.toml.lechaton-\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        do {
            try replacement.write(to: temporary, options: .withoutOverwriting)
            if let attributes = try? manager.attributesOfItem(atPath: configURL.path),
               let permissions = attributes[.posixPermissions]
            {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            if current == nil {
                try manager.moveItem(at: temporary, to: configURL)
            } else {
                _ = try manager.replaceItemAt(
                    configURL,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            }
            return backup
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}
