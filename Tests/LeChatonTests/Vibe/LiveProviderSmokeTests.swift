import Foundation
import Testing
@testable import LeChatonCore

@Suite("Live provider smoke", .serialized)
struct LiveProviderSmokeTests {
    @Test(
        "Disposable Vibe provider prompt and file-tool interaction",
        .enabled(if: ProcessInfo.processInfo.environment["LECHATON_LIVE_PROVIDER_SMOKE"] == "1")
    )
    func disposableProviderProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try #require(environment["LECHATON_PROVIDER_BASE_URL"])
        let modelID = try #require(environment["LECHATON_PROVIDER_MODEL_ID"])
        let key = environment["LECHATON_PROVIDER_API_KEY"] ?? ""
        let keyless = environment["LECHATON_PROVIDER_KEYLESS"] == "1"
        let executable = try VibeLocator().locate(
            explicitPath: environment["LECHATON_VIBE_EXECUTABLE"]
        )
        let draft = ProviderDraft(
            name: "Opt-in smoke",
            baseURL: endpoint,
            authMode: keyless ? .keylessLoopback : .bearer,
            apiKey: key,
            models: [.init(modelID: modelID, displayName: modelID)]
        )

        try await ProviderProbeClient.live().run(.init(
            draft: draft,
            executable: executable,
            apiKeyEnvironmentName: keyless ? nil : "LECHATON_PROVIDER_SMOKE_KEY"
        ))
    }
}
