import Testing
@testable import LeChatonCore

@Suite("ACP compatibility values")
struct ACPCompatibilityTests {
    @Test("Prompt stop reasons use ACP wire spellings")
    func promptStopReasons() {
        let cases: [(String, PromptStopReason)] = [
            ("end_turn", .endTurn),
            ("max_tokens", .maxTokens),
            ("max_turn_requests", .maxTurnRequests),
            ("refusal", .refusal),
            ("cancelled", .cancelled),
        ]

        for (rawValue, expected) in cases {
            let decoded = PromptStopReason(rawValue: rawValue)
            #expect(decoded == expected)
            #expect(decoded.rawValue == rawValue)
        }
        #expect(PromptStopReason(rawValue: "future_reason") == .unknown("future_reason"))
    }
}
