import Foundation

/// JSON-RPC permits either an integer or string identifier. ACP peers use both.
public enum RPCID: Hashable, Sendable {
    case integer(Int64)
    case string(String)
}

extension RPCID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

public extension RPCID {
    init?(jsonValue: JSONValue) {
        switch jsonValue {
        case let .integer(value): self = .integer(value)
        case let .string(value): self = .string(value)
        default: return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case let .integer(value): .integer(value)
        case let .string(value): .string(value)
        }
    }
}
