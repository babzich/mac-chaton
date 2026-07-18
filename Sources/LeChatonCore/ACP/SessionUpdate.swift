import Foundation

public enum DeliveryPhase: String, Codable, Hashable, Sendable {
    case loadPending
    case postLoadGuard
    case live
}

public struct EventEnvelope<Payload: Sendable>: Sendable {
    public let runtimeGeneration: UUID
    public let loadAttemptID: UUID?
    public let sequence: UInt64
    public let deliveryPhase: DeliveryPhase
    public let payload: Payload

    public init(
        runtimeGeneration: UUID,
        loadAttemptID: UUID?,
        sequence: UInt64,
        deliveryPhase: DeliveryPhase,
        payload: Payload
    ) {
        self.runtimeGeneration = runtimeGeneration
        self.loadAttemptID = loadAttemptID
        self.sequence = sequence
        self.deliveryPhase = deliveryPhase
        self.payload = payload
    }
}

extension EventEnvelope: Equatable where Payload: Equatable {}
extension EventEnvelope: Hashable where Payload: Hashable {}

public struct ReplayBarrier: Equatable, Hashable, Sendable {
    public let runtimeGeneration: UUID
    public let loadAttemptID: UUID
    public let throughSequence: UInt64

    public init(runtimeGeneration: UUID, loadAttemptID: UUID, throughSequence: UInt64) {
        self.runtimeGeneration = runtimeGeneration
        self.loadAttemptID = loadAttemptID
        self.throughSequence = throughSequence
    }
}

public enum ACPContentBlock: Equatable, Hashable, Sendable {
    case text(String, metadata: JSONValue?)
    case image(raw: JSONValue)
    case audio(raw: JSONValue)
    case resource(raw: JSONValue)
    case unknown(type: String, raw: JSONValue)

    public var text: String? {
        guard case let .text(text, _) = self else { return nil }
        return text
    }
}

public enum ToolCallStatus: Equatable, Hashable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case cancelled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case let .unknown(value): value
        }
    }
}

public enum PlanEntryStatus: Equatable, Hashable, Sendable {
    case pending
    case inProgress
    case completed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        default: self = .unknown(rawValue)
        }
    }
}

public enum PlanEntryPriority: Equatable, Hashable, Sendable {
    case high
    case medium
    case low
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        default: self = .unknown(rawValue)
        }
    }
}

public struct PlanEntry: Equatable, Hashable, Sendable {
    public let content: String
    public let priority: PlanEntryPriority
    public let status: PlanEntryStatus
    public let metadata: JSONValue?

    public init(
        content: String,
        priority: PlanEntryPriority,
        status: PlanEntryStatus,
        metadata: JSONValue? = nil
    ) {
        self.content = content
        self.priority = priority
        self.status = status
        self.metadata = metadata
    }
}

public struct ToolCallPatch: Equatable, Hashable, Sendable {
    public let toolCallID: String
    public let title: String?
    public let kind: String?
    public let status: ToolCallStatus?
    public let content: [JSONValue]?
    public let locations: [JSONValue]?
    public let rawInput: JSONValue?
    public let rawOutput: JSONValue?
    public let metadata: JSONValue?

    public init(
        toolCallID: String,
        title: String? = nil,
        kind: String? = nil,
        status: ToolCallStatus? = nil,
        content: [JSONValue]? = nil,
        locations: [JSONValue]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        metadata: JSONValue? = nil
    ) {
        self.toolCallID = toolCallID
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.metadata = metadata
    }
}

public enum SessionUpdate: Equatable, Hashable, Sendable {
    case userMessage(messageID: String?, content: ACPContentBlock, metadata: JSONValue?)
    case agentMessage(messageID: String?, content: ACPContentBlock, metadata: JSONValue?)
    case reasoning(messageID: String?, content: ACPContentBlock, metadata: JSONValue?)
    case toolCallStarted(ToolCallPatch)
    case toolCallUpdated(ToolCallPatch)
    case plan(id: String?, entries: [PlanEntry], metadata: JSONValue?)
    case planRemoved(id: String?, metadata: JSONValue?)
    case metadata(kind: String, raw: JSONValue)
    case unknown(kind: String, raw: JSONValue)

    public var kind: String {
        switch self {
        case .userMessage: "user_message_chunk"
        case .agentMessage: "agent_message_chunk"
        case .reasoning: "agent_thought_chunk"
        case .toolCallStarted: "tool_call"
        case .toolCallUpdated: "tool_call_update"
        case .plan: "plan"
        case .planRemoved: "plan_removed"
        case let .metadata(kind, _), let .unknown(kind, _): kind
        }
    }

    public var isReducerBoundHistory: Bool {
        switch self {
        case .userMessage, .agentMessage, .reasoning, .toolCallStarted, .toolCallUpdated, .plan, .planRemoved:
            true
        case .metadata, .unknown:
            false
        }
    }
}

public struct SessionNotification: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let update: SessionUpdate
    public let metadata: JSONValue?
}

public enum SessionUpdateDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    case paramsMustBeObject
    case missingSessionID
    case updateMustBeObject
    case missingDiscriminator
    case malformedKnownUpdate(String)

    public var description: String {
        switch self {
        case .paramsMustBeObject: "session/update params must be an object"
        case .missingSessionID: "session/update is missing sessionId"
        case .updateMustBeObject: "session/update update must be an object"
        case .missingDiscriminator: "session/update is missing sessionUpdate"
        case let .malformedKnownUpdate(kind): "Malformed known session update: \(kind)"
        }
    }
}

public extension SessionNotification {
    static func decode(params: JSONValue?) throws -> SessionNotification {
        guard let paramsObject = params?.objectValue else {
            throw SessionUpdateDecodingError.paramsMustBeObject
        }
        guard let sessionID = paramsObject["sessionId"]?.stringValue, !sessionID.isEmpty else {
            throw SessionUpdateDecodingError.missingSessionID
        }
        guard let rawUpdate = paramsObject["update"], let object = rawUpdate.objectValue else {
            throw SessionUpdateDecodingError.updateMustBeObject
        }
        guard let kind = object["sessionUpdate"]?.stringValue, !kind.isEmpty else {
            throw SessionUpdateDecodingError.missingDiscriminator
        }

        let metadata = object["_meta"]
        let update: SessionUpdate
        switch kind {
        case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
            guard let rawContent = object["content"] else {
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            let content = try decodeContentBlock(rawContent, updateKind: kind)
            let messageID: String?
            switch object["messageId"] {
            case nil, .some(.null):
                messageID = nil
            case let .some(.string(id)):
                messageID = id
            default:
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            switch kind {
            case "user_message_chunk": update = .userMessage(messageID: messageID, content: content, metadata: metadata)
            case "agent_message_chunk": update = .agentMessage(messageID: messageID, content: content, metadata: metadata)
            default: update = .reasoning(messageID: messageID, content: content, metadata: metadata)
            }

        case "tool_call", "tool_call_update":
            guard let toolCallID = object["toolCallId"]?.stringValue, !toolCallID.isEmpty else {
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            let title = try optionalString(object["title"], kind: kind)
            if kind == "tool_call", title == nil {
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            let toolKind = try optionalString(object["kind"], kind: kind)
            let status = try optionalString(object["status"], kind: kind).map(ToolCallStatus.init(rawValue:))
            let content = try optionalArray(object["content"], kind: kind)
            let locations = try optionalArray(object["locations"], kind: kind)
            let patch = ToolCallPatch(
                toolCallID: toolCallID,
                title: title,
                kind: toolKind,
                status: status,
                content: content,
                locations: locations,
                rawInput: object["rawInput"],
                rawOutput: object["rawOutput"],
                metadata: metadata
            )
            update = kind == "tool_call" ? .toolCallStarted(patch) : .toolCallUpdated(patch)

        case "plan":
            guard let entries = object["entries"]?.arrayValue else {
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            update = .plan(id: nil, entries: try entries.map { try decodePlanEntry($0, kind: kind) }, metadata: metadata)

        case "plan_update":
            guard let plan = object["plan"]?.objectValue, let type = plan["type"]?.stringValue else {
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            if type == "items" {
                guard let planID = plan["id"]?.stringValue, let entries = plan["entries"]?.arrayValue else {
                    throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
                }
                update = .plan(
                    id: planID,
                    entries: try entries.map { try decodePlanEntry($0, kind: kind) },
                    metadata: metadata
                )
            } else {
                // File, markdown, and future plan variants are known but not item reducers.
                update = .metadata(kind: kind, raw: rawUpdate)
            }

        case "plan_removed":
            guard let id = object["id"]?.stringValue, !id.isEmpty else {
                throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
            }
            update = .planRemoved(id: id, metadata: metadata)

        case "available_commands_update", "config_option_update", "current_mode_update", "session_info_update", "usage_update":
            update = .metadata(kind: kind, raw: rawUpdate)

        default:
            update = .unknown(kind: kind, raw: rawUpdate)
        }

        return SessionNotification(sessionID: sessionID, update: update, metadata: paramsObject["_meta"])
    }

    private static func decodeContentBlock(_ raw: JSONValue, updateKind: String) throws -> ACPContentBlock {
        guard let object = raw.objectValue, let type = object["type"]?.stringValue else {
            throw SessionUpdateDecodingError.malformedKnownUpdate(updateKind)
        }
        switch type {
        case "text":
            guard let text = object["text"]?.stringValue else {
                throw SessionUpdateDecodingError.malformedKnownUpdate(updateKind)
            }
            return .text(text, metadata: object["_meta"])
        case "image": return .image(raw: raw)
        case "audio": return .audio(raw: raw)
        case "resource", "resource_link": return .resource(raw: raw)
        default: return .unknown(type: type, raw: raw)
        }
    }

    private static func decodePlanEntry(_ raw: JSONValue, kind: String) throws -> PlanEntry {
        guard
            let object = raw.objectValue,
            let content = object["content"]?.stringValue,
            let priority = object["priority"]?.stringValue,
            let status = object["status"]?.stringValue
        else {
            throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
        }
        return PlanEntry(
            content: content,
            priority: .init(rawValue: priority),
            status: .init(rawValue: status),
            metadata: object["_meta"]
        )
    }

    private static func optionalString(_ value: JSONValue?, kind: String) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let result = value.stringValue else {
            throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
        }
        return result
    }

    private static func optionalArray(_ value: JSONValue?, kind: String) throws -> [JSONValue]? {
        guard let value, value != .null else { return nil }
        guard let result = value.arrayValue else {
            throw SessionUpdateDecodingError.malformedKnownUpdate(kind)
        }
        return result
    }
}
