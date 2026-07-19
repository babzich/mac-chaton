import Foundation
import Testing
@testable import LeChatonCore

@Suite("JSON-RPC decoding")
struct JSONRPCTests {
    @Test("String IDs and metadata are preserved")
    func stringIdentifierAndMetadata() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission","params":{},"_meta":{"future":true}}"#.utf8)
        let message = try JSONRPCMessage.decode(line: data)
        guard case let .request(request) = message else {
            Issue.record("Expected request")
            return
        }
        #expect(request.id == .string("permission-1"))
        #expect(request.metadata?["future"]?.boolValue == true)
    }

    @Test("Unknown session updates remain lossless no-ops")
    func unknownUpdate() throws {
        let notification = try SessionNotification.decode(params: .object([
            "sessionId": .string("session"),
            "update": .object([
                "sessionUpdate": .string("future_update"),
                "nested": .object(["answer": .integer(42)]),
            ]),
        ]))
        guard case let .unknown(kind, raw) = notification.update else {
            Issue.record("Expected unknown update")
            return
        }
        #expect(kind == "future_update")
        #expect(raw["nested"]?["answer"]?.intValue == 42)
    }

    @Test("Malformed JSON-RPC structure is rejected before method dispatch")
    func malformedFrames() {
        #expect(throws: JSONRPCDecodingError.unsupportedVersion) {
            try JSONRPCMessage.decode(line: Data(#"{"jsonrpc":"1.0","method":"future/event"}"#.utf8))
        }
        #expect(throws: JSONRPCDecodingError.invalidResponse) {
            try JSONRPCMessage.decode(line: Data(
                #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"both"}}"#.utf8
            ))
        }
        #expect(throws: JSONRPCDecodingError.invalidUTF8) {
            try JSONRPCMessage.decode(line: Data([0xFF, 0x0A]))
        }
    }

    @Test("Unknown notification methods remain valid envelopes")
    func unknownNotification() throws {
        let message = try JSONRPCMessage.decode(line: Data(
            #"{"jsonrpc":"2.0","method":"future/event","params":{"answer":42}}"#.utf8
        ))
        guard case let .notification(notification) = message else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.method == "future/event")
        #expect(notification.params?["answer"]?.intValue == 42)
    }

    @Test("Permission requests require an actionable, fully identified option")
    func permissionRequestRequiresAnAction() {
        func request(options: [JSONValue]) -> IncomingACPRequest {
            IncomingACPRequest(
                id: .integer(1),
                method: "session/request_permission",
                params: .object([
                    "sessionId": .string("session"),
                    "toolCall": .object(["toolCallId": .string("tool")]),
                    "options": .array(options),
                ]),
                metadata: nil
            )
        }

        #expect(PermissionRequest(request(options: [])) == nil)
        #expect(PermissionRequest(request(options: [
            .object([
                "optionId": .string(""),
                "name": .string("Allow"),
                "kind": .string("allow_once"),
            ]),
        ])) == nil)

        let decoded = PermissionRequest(request(options: [
            .object([
                "optionId": .string("allow"),
                "name": .string("Allow once"),
                "kind": .string("allow_once"),
            ]),
        ]))
        #expect(decoded?.options.map(\.optionID) == ["allow"])
    }
}
