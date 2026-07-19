import Darwin
import Foundation
import LeChatonCore

@main
struct FakeACPAgentMain {
    private struct State {
        var scenario = "standard"
        var sessionID = "fake-session"
        var pendingPromptID: RPCID?
        var pendingPermissionID: RPCID?
        var pendingLatePermissionID: RPCID?
        var descendantProcess: Process?
        var model = "fake-model"
        var authenticated = true
        var authenticationStatusRequestCount = 0
        var pendingAuthenticationAttemptID: String?
        var persistedSessionIDs: Set<String> = []
        var sessionListRequestCount = 0
        var workspaceTrusted = false
        var stopReadingStandardInput = false
    }

    static func main() {
        var state = State()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--descendant-worker"), arguments.indices.contains(index + 1) {
            runDescendantWorker(mode: arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) {
            state.scenario = arguments[index + 1]
        }
        if state.scenario == "auth-unauthenticated" {
            state.authenticated = false
        } else if state.scenario == "auth-provider-environment" {
            state.authenticated = ProcessInfo.processInfo.environment["LECHATON_TEST_PROVIDER_KEY"]
                == "provider-secret"
        }

        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let message = try JSONRPCMessage.decode(line: data)
                try handle(message, state: &state)
                if state.stopReadingStandardInput {
                    while true { pause() }
                }
            } catch {
                write(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(0),
                    "error": .object([
                        "code": .integer(-32700),
                        "message": .string("Parse error"),
                    ]),
                ]))
            }
        }
    }

    private static func handle(_ message: JSONRPCMessage, state: inout State) throws {
        switch message {
        case let .request(request):
            switch request.method {
            case "initialize":
                guard validInitializeRequest(request.params) else {
                    write(JSONRPCMessage.errorResponse(
                        id: request.id,
                        error: .init(code: -32602, message: "Invalid initialize capabilities")
                    ))
                    return
                }
                write(JSONRPCMessage.response(id: request.id, result: .object([
                    "protocolVersion": .integer(state.scenario == "protocol-two" ? 2 : 1),
                    "agentCapabilities": .object([
                        "loadSession": .bool(state.scenario != "missing-load-capability"),
                        "sessionCapabilities": state.scenario == "missing-list-capability"
                            ? .object([:])
                            : .object(["list": .object([:])]),
                        "promptCapabilities": .object([
                            "audio": .bool(false),
                            "embeddedContext": .bool(true),
                            "image": .bool(false),
                        ]),
                    ]),
                    "agentInfo": .object([
                        "name": .string(state.scenario == "wrong-agent" ? "another-agent" : "@mistralai/mistral-vibe"),
                        "title": .string("Fake Mistral Vibe"),
                        "version": .string(state.scenario == "wrong-version" ? "2.21.1" : "2.21.0"),
                    ]),
                    "authMethods": .array([.object([
                        "id": .string("browser-auth-delegated"),
                        "name": .string("Sign in through Mistral AI Studio"),
                        "futureField": .string("preserved"),
                    ])]),
                ])))
                if state.scenario == "malformed" {
                    FileHandle.standardOutput.write(Data("{not-json}\n".utf8))
                }
                if state.scenario == "stdin-backpressure" {
                    state.stopReadingStandardInput = true
                }

            case "_auth/status":
                if state.scenario == "no-auth-response" { return }
                state.authenticationStatusRequestCount += 1
                if state.scenario == "auth-drops-before-promotion",
                   state.authenticationStatusRequestCount > 1
                {
                    state.authenticated = false
                }
                let status: JSONValue
                if state.scenario == "auth-legacy-status" {
                    status = .object([
                        "status": .string("authenticated"),
                        "futureField": .object(["preserved": .bool(true)]),
                    ])
                } else if state.scenario == "auth-unknown-status" {
                    status = .object([
                        "authState": .string("future_auth_state"),
                        "signOutAvailable": .bool(true),
                    ])
                } else if state.scenario == "auth-nonobject-status" {
                    status = .string("future-status-shape")
                } else {
                    status = .object([
                        "authenticated": .bool(state.authenticated),
                        "authState": .string(state.authenticated ? "os_keyring" : "signed_out"),
                        "signOutAvailable": .bool(state.authenticated),
                        "futureField": .integer(1),
                    ])
                }
                write(JSONRPCMessage.response(id: request.id, result: status))

            case "authenticate":
                guard
                    request.params?["methodId"]?.stringValue == "browser-auth-delegated",
                    let action = request.params?["_meta"]?["action"]?.stringValue
                else {
                    write(JSONRPCMessage.errorResponse(
                        id: request.id,
                        error: .init(code: -32602, message: "Invalid authentication request")
                    ))
                    return
                }
                if action == "start" {
                    let attemptID = "fake-attempt-\(getpid())"
                    state.pendingAuthenticationAttemptID = attemptID
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "_meta": .object([
                            "browser-auth-delegated": .object([
                                "attemptId": .string(attemptID),
                                "expiresAt": .string("2030-01-01T00:00:00Z"),
                                "signInUrl": .string("https://console.mistral.ai/sign-in/fake"),
                                "futureField": .bool(true),
                            ]),
                        ]),
                    ])))
                } else if
                    action == "complete",
                    let attemptID = request.params?["_meta"]?["attemptId"]?.stringValue,
                    attemptID == state.pendingAuthenticationAttemptID
                {
                    state.pendingAuthenticationAttemptID = nil
                    state.authenticated = true
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "_meta": .object([
                            "browser-auth-delegated": .object([
                                "attemptId": .string(attemptID),
                                "persistResult": .object(["destination": .string("fake")]),
                                "status": .string("completed"),
                            ]),
                        ]),
                    ])))
                } else {
                    write(JSONRPCMessage.errorResponse(
                        id: request.id,
                        error: .init(code: -32602, message: "Unknown authentication attempt")
                    ))
                }

            case "_trust/status":
                if state.scenario == "trust-untrusted", !state.workspaceTrusted {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "trust_status": .string("untrusted"),
                        "details": .object([
                            "cwd": .string(request.params?["cwd"]?.stringValue ?? ""),
                            "availableDecisions": .array([
                                .string("trust_repo"),
                                .string("decline"),
                            ]),
                            "futureField": .bool(true),
                        ]),
                    ])))
                } else if state.scenario == "trust-unknown" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "trust_status": .string("future_trust_state"),
                        "options": .array([.object(["id": .string("future")])]),
                    ])))
                } else {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "trusted": .bool(true),
                        "options": .array([]),
                    ])))
                }

            case "_trust/decision":
                guard state.scenario == "trust-untrusted",
                      let decision = request.params?["decision"]?.stringValue,
                      ["trust_repo", "trust_cwd", "decline"].contains(decision)
                else {
                    write(JSONRPCMessage.errorResponse(
                        id: request.id,
                        error: .init(code: -32602, message: "Unsupported trust decision")
                    ))
                    return
                }
                state.workspaceTrusted = decision != "decline"
                write(JSONRPCMessage.response(id: request.id, result: .object([
                    "trust_status": .string(state.workspaceTrusted ? "trusted" : "untrusted"),
                    "details": state.workspaceTrusted ? .null : .object([
                        "cwd": .string(request.params?["cwd"]?.stringValue ?? ""),
                        "availableDecisions": .array([
                            .string("trust_repo"),
                            .string("trust_cwd"),
                            .string("decline"),
                        ]),
                    ]),
                ])))

            case "session/new":
                write(JSONRPCMessage.response(id: request.id, result: sessionResult(state: state)))

            case "session/list":
                let processCWD = FileManager.default.currentDirectoryPath
                state.sessionListRequestCount += 1
                if state.scenario == "malformed-session-list" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "sessions": .string("not-an-array"),
                    ])))
                    return
                }

                if state.scenario == "session-list-paginated" {
                    let cursor = request.params?["cursor"]?.stringValue
                    if cursor == nil {
                        write(JSONRPCMessage.response(id: request.id, result: .object([
                            "sessions": .array([.object([
                                "sessionId": .string("another-session"),
                                "cwd": .string(processCWD),
                                "additionalDirectories": .array([]),
                                "title": .string("Another session"),
                                "updatedAt": .string("2030-01-01T00:00:00Z"),
                                "_meta": .object(["itemFuture": .bool(true)]),
                                "futureItemField": .integer(1),
                            ])]),
                            "nextCursor": .string("page-2"),
                            "_meta": .object(["pageFuture": .bool(true)]),
                            "futurePageField": .integer(2),
                        ])))
                    } else if cursor == "page-2" {
                        write(JSONRPCMessage.response(id: request.id, result: .object([
                            "sessions": .array([.object([
                                "sessionId": .string("persisted-session"),
                                "cwd": .string(processCWD),
                                "futureItemField": .integer(3),
                            ])]),
                        ])))
                    } else {
                        write(JSONRPCMessage.response(id: request.id, result: .object([
                            "sessions": .array([]),
                        ])))
                    }
                    return
                }

                if state.scenario == "session-list-cursor-loop" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "sessions": .array([]),
                        "nextCursor": .string("same-cursor"),
                    ])))
                    return
                }

                if state.scenario == "session-list-unique-cursors" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "sessions": .array([]),
                        "nextCursor": .string("page-\(state.sessionListRequestCount)"),
                    ])))
                    return
                }

                let requestedCWD = request.params?["cwd"]?.stringValue
                let sessions: [JSONValue] = requestedCWD == nil || requestedCWD == processCWD
                    ? state.persistedSessionIDs.sorted().map { sessionID in
                        .object([
                            "sessionId": .string(sessionID),
                            "cwd": .string(processCWD),
                        ])
                    }
                    : []
                write(JSONRPCMessage.response(id: request.id, result: .object([
                    "sessions": .array(sessions),
                ])))

            case "session/load":
                if state.scenario == "no-load-response" { return }
                if let requestedID = request.params?["sessionId"]?.stringValue {
                    if state.scenario.hasPrefix("session-not-found") {
                        var data: JSONValue = .object(["session_id": .string(requestedID)])
                        var message = "Session not found: \(requestedID)"
                        if state.scenario == "session-not-found-wrong-data" {
                            data = .object(["session_id": .string("another-session")])
                        } else if state.scenario == "session-not-found-extra-data" {
                            data = .object([
                                "session_id": .string(requestedID),
                                "future": .bool(true),
                            ])
                        } else if state.scenario == "session-not-found-wrong-message" {
                            message = "Session missing: \(requestedID)"
                        }
                        write(JSONRPCMessage.errorResponse(
                            id: request.id,
                            error: .init(code: -32602, message: message, data: data)
                        ))
                        return
                    }
                    state.sessionID = requestedID
                }
                if state.scenario == "malformed-load-response" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "configOptions": .string("not-an-array"),
                    ])))
                } else if state.scenario == "malformed-known-replay" {
                    writeUpdate(sessionID: state.sessionID, update: .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["type": .string("text")]),
                    ]))
                    write(JSONRPCMessage.response(id: request.id, result: sessionResult(state: state)))
                } else if state.scenario == "unknown-only-load" {
                    writeUpdate(sessionID: state.sessionID, update: .object([
                        "sessionUpdate": .string("future_update"),
                        "malformedIfKnown": .integer(42),
                    ]))
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "futureResponseField": .object(["preserved": .bool(true)]),
                    ])))
                } else if state.scenario == "replay-after-response" {
                    write(JSONRPCMessage.response(id: request.id, result: sessionResult(state: state)))
                    writeReplay(sessionID: state.sessionID)
                } else {
                    writeReplay(sessionID: state.sessionID)
                    write(JSONRPCMessage.response(id: request.id, result: sessionResult(state: state)))
                }

            case "session/prompt":
                if let sessionID = request.params?["sessionId"]?.stringValue {
                    state.persistedSessionIDs.insert(sessionID)
                }
                state.pendingPromptID = request.id
                if state.scenario == "descendant-graceful" {
                    state.descendantProcess = spawnDescendant(mode: "graceful")
                } else if state.scenario == "descendant-resistant" {
                    state.descendantProcess = spawnDescendant(mode: "resistant")
                }
                writeUpdate(sessionID: state.sessionID, update: .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "messageId": .string("thought-live"),
                    "content": textBlock("Considering the request. "),
                ]))
                writeUpdate(sessionID: state.sessionID, update: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("tool-live"),
                    "title": .string("Fake edit"),
                    "kind": .string("edit"),
                    "status": .string("pending"),
                ]))
                if state.scenario == "no-permission" {
                    completePrompt(state: &state, cancelled: false)
                } else {
                    let permissionID = RPCID.string("permission-1")
                    state.pendingPermissionID = permissionID
                    write(JSONRPCMessage.request(
                        id: permissionID,
                        method: "session/request_permission",
                        params: .object([
                            "sessionId": .string(state.sessionID),
                            "toolCall": .object(["toolCallId": .string("tool-live")]),
                            "options": .array([
                                .object([
                                    "optionId": .string("allow-once"),
                                    "name": .string("Allow once"),
                                    "kind": .string("allow_once"),
                                ]),
                                .object([
                                    "optionId": .string("reject-once"),
                                    "name": .string("Reject"),
                                    "kind": .string("reject_once"),
                                ]),
                            ]),
                        ])
                    ))
                }

            case "session/set_config_option":
                if state.scenario == "no-config-response" { return }
                if let value = request.params?["value"]?.stringValue { state.model = value }
                if state.scenario == "config-empty-response" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([:])))
                } else if state.scenario == "config-null-response" {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "configOptions": .null,
                    ])))
                } else {
                    write(JSONRPCMessage.response(id: request.id, result: .object([
                        "configOptions": configOptions(state.model),
                    ])))
                }

            default:
                write(JSONRPCMessage.errorResponse(
                    id: request.id,
                    error: .init(code: -32601, message: "Method not found")
                ))
            }

        case let .notification(notification):
            if notification.method == "session/cancel" {
                completePrompt(state: &state, cancelled: true)
                if state.scenario == "late-permission-on-cancel" {
                    let permissionID = RPCID.string("permission-late")
                    state.pendingLatePermissionID = permissionID
                    writePermissionRequest(
                        id: permissionID,
                        sessionID: state.sessionID,
                        toolCallID: "tool-late"
                    )
                }
            }

        case let .response(response):
            if response.id == state.pendingPermissionID {
                state.pendingPermissionID = nil
                completePrompt(state: &state, cancelled: false)
            } else if response.id == state.pendingLatePermissionID {
                state.pendingLatePermissionID = nil
                let outcome = response.result?["outcome"]?["outcome"]?.stringValue ?? "missing"
                write(JSONRPCMessage.notification(
                    method: outcome == "cancelled"
                        ? "_fake/late_permission_cancelled"
                        : "_fake/late_permission_not_cancelled"
                ))
            }
        }
    }

    private static func writeReplay(sessionID: String) {
        writeUpdate(sessionID: sessionID, update: .object([
            "sessionUpdate": .string("user_message_chunk"),
            "messageId": .string("user-1"),
            "content": textBlock("Earlier question"),
        ]))
        writeUpdate(sessionID: sessionID, update: .object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "messageId": .string("thought-1"),
            "content": textBlock("Earlier reasoning"),
        ]))
        writeUpdate(sessionID: sessionID, update: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "messageId": .string("agent-1"),
            "content": textBlock("Earlier answer"),
        ]))
        writeUpdate(sessionID: sessionID, update: .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("tool-1"),
            "title": .string("Earlier tool"),
            "status": .string("completed"),
        ]))
        writeUpdate(sessionID: sessionID, update: .object([
            "sessionUpdate": .string("future_update"),
            "futureField": .string("preserved"),
        ]))
    }

    private static func validInitializeRequest(_ params: JSONValue?) -> Bool {
        guard
            params?["protocolVersion"]?.intValue == Int64(ACPProtocol.supportedVersion),
            params?["clientCapabilities"]?["terminal"]?.boolValue == false,
            params?["clientCapabilities"]?["auth"]?["terminal"]?.boolValue == false,
            params?["clientCapabilities"]?["session"]?["configOptions"]?.objectValue != nil,
            params?["clientCapabilities"]?["plan"]?.objectValue != nil,
            params?["clientCapabilities"]?["_meta"]?["browser-auth-delegated"]?.boolValue == true
        else { return false }
        return true
    }

    private static func completePrompt(state: inout State, cancelled: Bool) {
        guard let promptID = state.pendingPromptID else { return }
        state.pendingPromptID = nil
        state.pendingPermissionID = nil
        writeUpdate(sessionID: state.sessionID, update: .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("tool-live"),
            "status": .string(cancelled ? "cancelled" : "completed"),
        ]))
        if !cancelled {
            writeUpdate(sessionID: state.sessionID, update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("agent-live"),
                "content": textBlock("Fake response"),
            ]))
        }
        write(JSONRPCMessage.response(id: promptID, result: .object([
            "stopReason": .string(cancelled ? "cancelled" : "end_turn"),
        ])))
    }

    private static func writePermissionRequest(id: RPCID, sessionID: String, toolCallID: String) {
        write(JSONRPCMessage.request(
            id: id,
            method: "session/request_permission",
            params: .object([
                "sessionId": .string(sessionID),
                "toolCall": .object(["toolCallId": .string(toolCallID)]),
                "options": .array([.object([
                    "optionId": .string("reject-once"),
                    "name": .string("Reject"),
                    "kind": .string("reject_once"),
                ])]),
            ])
        ))
    }

    private static func spawnDescendant(mode: String) -> Process? {
        let child = Process()
        child.executableURL = URL(filePath: CommandLine.arguments[0])
        child.arguments = ["--descendant-worker", mode]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            return child
        } catch {
            return nil
        }
    }

    private static func runDescendantWorker(mode: String) {
        if mode == "resistant" {
            signal(SIGTERM, SIG_IGN)
            while true { pause() }
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    private static func sessionResult(state: State) -> JSONValue {
        .object([
            "sessionId": .string(state.sessionID),
            "configOptions": configOptions(state.model),
            "_meta": .object(["workspace_trust": .string("trusted")]),
        ])
    }

    private static func configOptions(_ model: String) -> JSONValue {
        .array([.object([
            "id": .string("model"),
            "name": .string("Model"),
            "type": .string("select"),
            "currentValue": .string(model),
            "options": .array([
                .object(["value": .string("fake-model"), "name": .string("Fake model")]),
                .object(["value": .string("fake-model-2"), "name": .string("Fake model 2")]),
            ]),
        ])])
    }

    private static func textBlock(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    private static func writeUpdate(sessionID: String, update: JSONValue) {
        write(JSONRPCMessage.notification(
            method: "session/update",
            params: .object(["sessionId": .string(sessionID), "update": update])
        ))
    }

    private static func write(_ value: JSONValue) {
        guard var data = try? value.encodedData() else { return }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
