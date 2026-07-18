import Foundation
import Testing
@testable import LeChatonCore

@Suite("Session update decoding")
struct SessionUpdateDecodingTests {
    @Test("Unknown fields and enum values are tolerated")
    func forwardCompatibleKnownUpdate() throws {
        let notification = try SessionNotification.decode(params: .object([
            "sessionId": .string("s1"),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tool-1"),
                "title": .string("Future tool"),
                "status": .string("paused_by_future_agent"),
                "futureField": .array([.integer(1)]),
                "_meta": .object(["vendor": .string("value")]),
            ]),
        ]))

        guard case let .toolCallStarted(patch) = notification.update else {
            Issue.record("Expected tool start")
            return
        }
        #expect(patch.status == .unknown("paused_by_future_agent"))
        #expect(patch.metadata?["vendor"]?.stringValue == "value")
    }

    @Test("Malformed required fields in known reducer updates fail")
    func malformedKnownUpdate() {
        #expect(throws: SessionUpdateDecodingError.self) {
            try SessionNotification.decode(params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text")]),
                ]),
            ]))
        }
    }

    @Test("Unknown content block types remain valid")
    func unknownContentBlock() throws {
        let notification = try SessionNotification.decode(params: .object([
            "sessionId": .string("s1"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("hologram"),
                    "payload": .string("future"),
                ]),
            ]),
        ]))
        guard case let .agentMessage(_, content, _) = notification.update else {
            Issue.record("Expected agent message")
            return
        }
        guard case let .unknown(type, raw) = content else {
            Issue.record("Expected unknown content block")
            return
        }
        #expect(type == "hologram")
        #expect(raw["payload"]?.stringValue == "future")
    }

    @Test("Unknown update kinds are preserved even when their body would be malformed for a known kind")
    func unknownUpdateKindIsOpaque() throws {
        let notification = try SessionNotification.decode(params: .object([
            "sessionId": .string("s1"),
            "update": .object([
                "sessionUpdate": .string("future_message_chunk"),
                "content": .integer(42),
                "status": .object(["future": .bool(true)]),
            ]),
        ]))

        guard case let .unknown(kind, raw) = notification.update else {
            Issue.record("Expected opaque unknown update")
            return
        }
        #expect(kind == "future_message_chunk")
        #expect(raw["content"]?.intValue == 42)
    }

    @Test("Explicit null is accepted for optional known-update fields")
    func explicitNullOptionals() throws {
        let notification = try SessionNotification.decode(params: .object([
            "sessionId": .string("s1"),
            "update": .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tool-1"),
                "title": .null,
                "status": .null,
                "content": .null,
            ]),
        ]))
        guard case let .toolCallUpdated(patch) = notification.update else {
            Issue.record("Expected tool update")
            return
        }
        #expect(patch.title == nil)
        #expect(patch.status == nil)
        #expect(patch.content == nil)

        let message = try SessionNotification.decode(params: .object([
            "sessionId": .string("s1"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .null,
                "content": .object(["type": .string("text"), "text": .string("hello")]),
            ]),
        ]))
        guard case let .agentMessage(messageID, _, _) = message.update else {
            Issue.record("Expected agent message")
            return
        }
        #expect(messageID == nil)
    }

    @Test("Structurally malformed update envelopes still fail")
    func malformedEnvelope() {
        #expect(throws: SessionUpdateDecodingError.self) {
            try SessionNotification.decode(params: .object([
                "sessionId": .string("s1"),
                "update": .object(["future": .bool(true)]),
            ]))
        }
        #expect(throws: SessionUpdateDecodingError.self) {
            try SessionNotification.decode(params: .object([
                "sessionId": .string("s1"),
                "update": .string("not-an-object"),
            ]))
        }
    }
}
