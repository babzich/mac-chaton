import Foundation
import LeChatonCore

enum HistoryKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case reasoning
    case tool
    case plan
}

struct HistoryPrompt: Codable, Sendable {
    let kind: HistoryKind
    let initialPrompt: String
    let followUpPrompt: String
}

struct LiveGatePromptSpec: Codable, Sendable {
    let histories: [HistoryPrompt]
    let cancellationPrompt: String
    let cancellationFollowUpPrompt: String

    func validated() throws -> Self {
        guard Set(histories.map(\.kind)) == Set(HistoryKind.allCases), histories.count == HistoryKind.allCases.count else {
            throw ProbeError.invalidInput("prompt spec must contain exactly one text, reasoning, tool, and plan history")
        }
        guard histories.allSatisfy({ !$0.initialPrompt.isEmpty && !$0.followUpPrompt.isEmpty }) else {
            throw ProbeError.invalidInput("history prompts must not be empty")
        }
        guard !cancellationPrompt.isEmpty, !cancellationFollowUpPrompt.isEmpty else {
            throw ProbeError.invalidInput("cancellation prompts must not be empty")
        }
        return self
    }

    func prompt(for kind: HistoryKind) throws -> HistoryPrompt {
        guard let prompt = histories.first(where: { $0.kind == kind }) else {
            throw ProbeError.invalidInput("prompt spec is missing \(kind.rawValue)")
        }
        return prompt
    }
}

struct HistorySession: Codable, Sendable {
    let kind: HistoryKind
    let sessionID: String
}

struct SessionManifest: Codable, Sendable {
    let formatVersion: Int
    let histories: [HistorySession]

    init(histories: [HistorySession]) {
        formatVersion = 1
        self.histories = histories
    }

    func validated() throws -> Self {
        guard formatVersion == 1 else {
            throw ProbeError.invalidInput("unsupported session manifest version \(formatVersion)")
        }
        guard Set(histories.map(\.kind)) == Set(HistoryKind.allCases), histories.count == HistoryKind.allCases.count else {
            throw ProbeError.invalidInput("session manifest must contain exactly one session per history kind")
        }
        guard histories.allSatisfy({ !$0.sessionID.isEmpty }) else {
            throw ProbeError.invalidInput("session IDs must not be empty")
        }
        guard Set(histories.map(\.sessionID)).count == histories.count else {
            throw ProbeError.compatibility("the four histories do not have independent Vibe session IDs")
        }
        return self
    }

    func session(for kind: HistoryKind) throws -> HistorySession {
        guard let session = histories.first(where: { $0.kind == kind }) else {
            throw ProbeError.invalidInput("session manifest is missing \(kind.rawValue)")
        }
        return session
    }
}

struct ReplayCoverage: Codable, Equatable, Sendable {
    var messages = 0
    var reasoning = 0
    var tools = 0
    var plans = 0
    var metadata = 0
    var unknown = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            messages: lhs.messages + rhs.messages,
            reasoning: lhs.reasoning + rhs.reasoning,
            tools: lhs.tools + rhs.tools,
            plans: lhs.plans + rhs.plans,
            metadata: lhs.metadata + rhs.metadata,
            unknown: lhs.unknown + rhs.unknown
        )
    }

    mutating func record(_ update: SessionUpdate) {
        switch update {
        case .userMessage, .agentMessage: messages += 1
        case .reasoning: reasoning += 1
        case .toolCallStarted, .toolCallUpdated: tools += 1
        case .plan, .planRemoved: plans += 1
        case .metadata: metadata += 1
        case .unknown: unknown += 1
        }
    }
}

struct SanitizedReplayEvent: Encodable, Sendable {
    let record = "replay_event"
    let traceID: String
    let historyKind: HistoryKind
    let freshProcessOrdinal: Int
    let frameOrdinal: UInt64
    let eventKind: String
    let localSequence: UInt64
    let loadResponsePosition: String
    let reducedThroughSequence: UInt64
    let barrierAcknowledged: Bool
}

struct SanitizedBarrierRecord: Encodable, Sendable {
    let record = "replay_barrier"
    let traceID: String
    let historyKind: HistoryKind
    let freshProcessOrdinal: Int
    let responseAfterSequence: UInt64
    let throughSequence: UInt64
    let reducedThroughSequence: UInt64
    let acknowledged: Bool
}

struct ConfigurationOption: Equatable, Sendable {
    let id: String
    let currentValue: JSONValue
    let values: [JSONValue]
    let type: String

    init?(_ raw: JSONValue) {
        guard
            let object = raw.objectValue,
            let id = object["id"]?.stringValue,
            !id.isEmpty,
            let currentValue = object["currentValue"],
            let type = object["type"]?.stringValue
        else { return nil }

        let values: [JSONValue]
        if type == "select" {
            guard let choices = object["options"]?.arrayValue else { return nil }
            values = choices.compactMap { $0.objectValue?["value"] }
        } else if type == "boolean" {
            values = [.bool(false), .bool(true)]
        } else {
            return nil
        }
        self.id = id
        self.currentValue = currentValue
        self.values = values
        self.type = type
    }

    var alternateValue: JSONValue? { values.first(where: { $0 != currentValue }) }
}

struct ConfigurationJournal: Codable, Sendable {
    struct OriginalValue: Codable, Sendable {
        let optionID: String
        let value: JSONValue
    }

    let formatVersion: Int
    let executablePath: String
    let workingDirectory: String
    let sessionID: String
    let createdAtUnixMilliseconds: Int64
    let model: OriginalValue
    let thinking: OriginalValue
}

struct ConfigurationSnapshot: Sendable {
    let options: [ConfigurationOption]

    func option(id: String) throws -> ConfigurationOption {
        guard let option = options.first(where: { $0.id == id }) else {
            throw ProbeError.compatibility("configuration option \(id) was not advertised")
        }
        return option
    }
}

enum PermissionPolicy: Sendable {
    case allowOnce
    case reject
}

enum ProbeError: Error, CustomStringConvertible, Sendable {
    case invalidInput(String)
    case compatibility(String)
    case timeout(String)
    case process(String)
    case restoration(String)

    var description: String {
        switch self {
        case let .invalidInput(message): "Invalid input: \(message)"
        case let .compatibility(message): "Compatibility gate failed: \(message)"
        case let .timeout(message): "Timed out: \(message)"
        case let .process(message): "Process failure: \(message)"
        case let .restoration(message): "Configuration restoration failed: \(message)"
        }
    }
}

enum ProbeOutput {
    private static let lock = NSLock()

    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func emit(_ fields: [String: JSONValue]) {
        guard var data = try? JSONValue.object(fields).encodedData() else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    static func error(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func readPrompt(from url: URL) throws -> String {
    let prompt = try String(contentsOf: url, encoding: .utf8)
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProbeError.invalidInput("prompt file is empty")
    }
    return prompt
}

func canonicalURL(_ path: String) -> URL {
    URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
}

func withTimeout<T: Sendable>(
    _ duration: Duration,
    operationName: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw ProbeError.timeout(operationName)
        }
        guard let result = try await group.next() else {
            throw ProbeError.timeout(operationName)
        }
        group.cancelAll()
        return result
    }
}
