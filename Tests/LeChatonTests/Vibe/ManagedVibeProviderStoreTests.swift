import Foundation
import Testing
@testable import LeChatonCore

@Suite("Managed Vibe providers", .serialized)
struct ManagedVibeProviderStoreTests {
    @Test("Tested providers preserve unrelated TOML and support multiple models")
    func savePreservesUnknownConfiguration() async throws {
        let initial = Data("""
        enable_notifications = false
        custom_value = "keep-me"

        [[providers]]
        name = "external"
        api_base = "https://example.invalid/v1"
        api_key_env_var = "EXTERNAL_KEY"

        [[models]]
        name = "external-model"
        provider = "external"
        alias = "external-alias"
        """.utf8)
        let config = LockedProviderConfiguration(initial)
        let secrets = FakeProviderSecrets()
        let probe = FakeProviderProbe()
        let store = makeStore(config: config, secrets: secrets, probe: probe)
        _ = try await store.reload()

        let secret = "test-secret-that-must-not-enter-config"
        let draft = ProviderDraft(
            name: "Gateway",
            baseURL: "https://gateway.example/v1/",
            authMode: .bearer,
            apiKey: secret,
            models: [
                .init(modelID: "alpha", displayName: "Alpha"),
                .init(modelID: "beta", displayName: "Beta"),
            ]
        )
        let test = try await store.test(draft: draft, executable: providerTestExecutable())
        let saved = try await store.save(draft: draft, testResultID: test.id)

        #expect(saved.name == "Gateway")
        #expect(saved.baseURL.absoluteString == "https://gateway.example/v1")
        #expect(saved.models.map { $0.modelID } == ["alpha", "beta"])
        let text = try #require(String(data: config.snapshot(), encoding: .utf8))
        #expect(text.contains("custom_value = 'keep-me'") || text.contains("custom_value = \"keep-me\""))
        #expect(text.contains("external-alias"))
        #expect(text.contains("lechaton_"))
        #expect(!text.contains(secret))
        #expect(config.commitCount == 1)
        #expect(await probe.lastDraft?.apiKey == secret)

        let accounts = await secrets.accounts()
        #expect(accounts.count == 1)
        let environment = try await store.runtimeEnvironment()
        #expect(environment == nil)

        try await store.activate(providerID: saved.id, modelID: saved.models[1].id)
        let active = try await store.providers()
        #expect(active.first?.status == .active)
        let activeEnvironment = try #require(try await store.runtimeEnvironment())
        #expect(activeEnvironment.secret == secret)
        #expect(accounts.contains(activeEnvironment.name))
        await #expect(throws: ManagedVibeProviderError.providerIsActive) {
            try await store.remove(providerID: saved.id)
        }
    }

    @Test("Saving requires the exact tested draft and retains an existing blank key")
    func testBeforeSaveAndRetainedKey() async throws {
        let config = LockedProviderConfiguration(Data())
        let secrets = FakeProviderSecrets()
        let probe = FakeProviderProbe()
        let store = makeStore(config: config, secrets: secrets, probe: probe)
        _ = try await store.reload()
        let original = ProviderDraft(
            name: "Provider",
            baseURL: "https://provider.example/v1",
            apiKey: "retained-secret",
            models: [.init(modelID: "model-a", displayName: "Model A")]
        )

        await #expect(throws: ManagedVibeProviderError.testRequired) {
            try await store.save(draft: original, testResultID: UUID())
        }
        let tested = try await store.test(draft: original, executable: providerTestExecutable())
        var changed = original
        changed.name = "Changed"
        await #expect(throws: ManagedVibeProviderError.testedDraftChanged) {
            try await store.save(draft: changed, testResultID: tested.id)
        }
        let saved = try await store.save(draft: original, testResultID: tested.id)
        let accountsBeforeEdit = await secrets.accounts()

        var edit = ProviderDraft(provider: saved)
        edit.models[0].displayName = "Renamed"
        let editTest = try await store.test(draft: edit, executable: providerTestExecutable())
        let edited = try await store.save(draft: edit, testResultID: editTest.id)

        #expect(await secrets.accounts() == accountsBeforeEdit)
        #expect(await probe.lastDraft?.apiKey == "retained-secret")

        var replacement = ProviderDraft(provider: edited)
        replacement.apiKey = "replacement-secret"
        let replacementTest = try await store.test(
            draft: replacement,
            executable: providerTestExecutable()
        )
        let replaced = try await store.save(
            draft: replacement,
            testResultID: replacementTest.id
        )
        let replacementAccounts = await secrets.accounts()
        #expect(replacementAccounts.count == 1)
        #expect(replacementAccounts != accountsBeforeEdit)

        try await store.remove(providerID: replaced.id)
        #expect(await secrets.accounts().isEmpty)
    }

    @Test("Unsafe endpoints, malformed TOML, and reserved collisions fail defensively")
    func defensiveValidation() async throws {
        let cases: [(ProviderDraft, ManagedVibeProviderError)] = [
            (
                ProviderDraft(name: "Remote", baseURL: "http://example.com/v1", apiKey: "key"),
                .insecureRemoteEndpoint
            ),
            (
                ProviderDraft(
                    name: "Keyless",
                    baseURL: "https://example.com/v1",
                    authMode: .keylessLoopback,
                    apiKey: ""
                ),
                .keylessRequiresLoopback
            ),
            (
                ProviderDraft(name: "Credentials", baseURL: "https://user:pass@example.com/v1", apiKey: "key"),
                .endpointContainsCredentials
            ),
            (
                ProviderDraft(name: "Query", baseURL: "https://example.com/v1?key=value", apiKey: "key"),
                .endpointContainsQueryOrFragment
            ),
        ]
        for (draft, expected) in cases {
            let store = makeStore(
                config: LockedProviderConfiguration(Data()),
                secrets: FakeProviderSecrets(),
                probe: FakeProviderProbe()
            )
            _ = try await store.reload()
            do {
                _ = try await store.test(draft: draft, executable: providerTestExecutable())
                Issue.record("Expected \(expected)")
            } catch {
                #expect(error as? ManagedVibeProviderError == expected)
            }
        }

        let malformed = makeStore(
            config: LockedProviderConfiguration(Data("[broken".utf8)),
            secrets: FakeProviderSecrets(),
            probe: FakeProviderProbe()
        )
        await #expect(throws: ManagedVibeProviderError.malformedConfiguration) {
            try await malformed.reload()
        }

        let collision = makeStore(
            config: LockedProviderConfiguration(Data("""
            [[providers]]
            name = "lechaton_reserved"
            api_base = "https://example.com/v1"
            """.utf8)),
            secrets: FakeProviderSecrets(),
            probe: FakeProviderProbe()
        )
        await #expect(throws: ManagedVibeProviderError.self) {
            try await collision.reload()
        }

        let loopback = makeStore(
            config: LockedProviderConfiguration(Data()),
            secrets: FakeProviderSecrets(),
            probe: FakeProviderProbe()
        )
        _ = try await loopback.reload()
        let keyless = ProviderDraft(
            name: "Local",
            baseURL: "http://[::1]:8080/v1/",
            authMode: .keylessLoopback,
            apiKey: "",
            models: [.init(modelID: "local", displayName: "Local")]
        )
        _ = try await loopback.test(draft: keyless, executable: providerTestExecutable())
        #expect(try await loopback.runtimeEnvironment() == nil)
    }

    @Test("Stale and failed config commits roll back staged secrets")
    func commitFailureRollsBackKey() async throws {
        let config = LockedProviderConfiguration(Data())
        let secrets = FakeProviderSecrets()
        let store = makeStore(config: config, secrets: secrets, probe: FakeProviderProbe())
        _ = try await store.reload()
        let draft = ProviderDraft(
            name: "Provider",
            baseURL: "https://provider.example/v1",
            apiKey: "never-leak",
            models: [.init(modelID: "model", displayName: "Model")]
        )
        let tested = try await store.test(draft: draft, executable: providerTestExecutable())
        config.replaceExternally(Data("external = true".utf8))
        await #expect(throws: ManagedVibeProviderError.staleConfiguration) {
            try await store.save(draft: draft, testResultID: tested.id)
        }
        #expect(await secrets.accounts().isEmpty)

        let failingConfig = LockedProviderConfiguration(Data(), failCommit: true)
        let rollbackSecrets = FakeProviderSecrets()
        let failingStore = makeStore(
            config: failingConfig,
            secrets: rollbackSecrets,
            probe: FakeProviderProbe()
        )
        _ = try await failingStore.reload()
        let secondTest = try await failingStore.test(draft: draft, executable: providerTestExecutable())
        await #expect(throws: TestProviderError.commitFailed) {
            try await failingStore.save(draft: draft, testResultID: secondTest.id)
        }
        #expect(await rollbackSecrets.accounts().isEmpty)
        #expect(!String(data: failingConfig.snapshot(), encoding: .utf8)!.contains("never-leak"))

        let lockedSecrets = FakeProviderSecrets(failWrites: true)
        let lockedConfig = LockedProviderConfiguration(Data())
        let lockedStore = makeStore(
            config: lockedConfig,
            secrets: lockedSecrets,
            probe: FakeProviderProbe()
        )
        _ = try await lockedStore.reload()
        let lockedTest = try await lockedStore.test(draft: draft, executable: providerTestExecutable())
        await #expect(throws: TestProviderError.keychainLocked) {
            try await lockedStore.save(draft: draft, testResultID: lockedTest.id)
        }
        #expect(lockedConfig.snapshot().isEmpty)
    }

    @Test("Live file replacement preserves permissions and creates a recoverable backup")
    func atomicReplacementAndBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "lechaton-provider-config-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "config.toml")
        let original = Data("value = 'before'\n".utf8)
        let replacement = Data("value = 'after'\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let client = ProviderConfigurationClient.live(configURL: url)

        let backup = try client.commit(original, replacement)

        #expect(try Data(contentsOf: url) == replacement)
        #expect(try Data(contentsOf: backup) == original)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue == 0o640)
    }
}

private func makeStore(
    config: LockedProviderConfiguration,
    secrets: FakeProviderSecrets,
    probe: FakeProviderProbe
) -> ManagedVibeProviderStore {
    ManagedVibeProviderStore(
        configuration: config.client,
        secrets: secrets,
        probe: probe.client
    )
}

private func providerTestExecutable() -> VibeExecutable {
    .init(url: URL(filePath: "/bin/echo"), source: .explicit)
}

private final class LockedProviderConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private let failCommit: Bool
    private var storedCommitCount = 0

    init(_ data: Data?, failCommit: Bool = false) {
        self.data = data
        self.failCommit = failCommit
    }

    var client: ProviderConfigurationClient {
        .init(
            read: { self.snapshotOptional() },
            commit: { expected, replacement in
                try self.commit(expected: expected, replacement: replacement)
            }
        )
    }

    func snapshot() -> Data { lock.withLock { data ?? Data() } }
    var commitCount: Int { lock.withLock { storedCommitCount } }
    func replaceExternally(_ data: Data?) { lock.withLock { self.data = data } }

    private func snapshotOptional() -> Data? { lock.withLock { data } }

    private func commit(expected: Data?, replacement: Data) throws -> URL {
        try lock.withLock {
            guard data == expected else { throw ManagedVibeProviderError.staleConfiguration }
            if failCommit { throw TestProviderError.commitFailed }
            data = replacement
            storedCommitCount += 1
            return URL(filePath: "/tmp/provider-config.backup")
        }
    }
}

private actor FakeProviderSecrets: ProviderSecretStore {
    private var values: [String: String] = [:]
    private let failWrites: Bool

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    func read(account: String) async throws -> String? { values[account] }
    func write(_ secret: String, account: String) async throws {
        if failWrites { throw TestProviderError.keychainLocked }
        values[account] = secret
    }
    func delete(account: String) async throws { values.removeValue(forKey: account) }
    func accounts() -> Set<String> { Set(values.keys) }
}

private actor FakeProviderProbe {
    private(set) var lastDraft: ProviderDraft?

    nonisolated var client: ProviderProbeClient {
        .init { request in
            await self.record(request.draft)
        }
    }

    private func record(_ draft: ProviderDraft) {
        lastDraft = draft
    }
}

private enum TestProviderError: Error {
    case commitFailed
    case keychainLocked
}
