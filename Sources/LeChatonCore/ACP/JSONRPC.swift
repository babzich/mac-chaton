import Foundation

public enum JSONRPCDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidUTF8
    case invalidJSON(String)
    case rootIsNotObject
    case unsupportedVersion
    case invalidIdentifier
    case invalidRequest
    case invalidResponse
    case invalidErrorObject

    public var description: String {
        switch self {
        case .invalidUTF8: "JSON-RPC frame is not valid UTF-8"
        case let .invalidJSON(reason): "Invalid JSON-RPC JSON: \(reason)"
        case .rootIsNotObject: "JSON-RPC frame must be an object"
        case .unsupportedVersion: "JSON-RPC version must be 2.0"
        case .invalidIdentifier: "JSON-RPC id must be an integer or string"
        case .invalidRequest: "Malformed JSON-RPC request or notification"
        case .invalidResponse: "Malformed JSON-RPC response"
        case .invalidErrorObject: "Malformed JSON-RPC error object"
        }
    }
}

public struct JSONRPCRequest: Hashable, Sendable {
    public let id: RPCID
    public let method: String
    public let params: JSONValue?
    public let metadata: JSONValue?
}

public struct JSONRPCNotification: Hashable, Sendable {
    public let method: String
    public let params: JSONValue?
    public let metadata: JSONValue?
}

public struct JSONRPCErrorObject: Error, Hashable, Sendable, CustomStringConvertible {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "JSON-RPC error \(code): \(message)" }
}

public struct JSONRPCResponse: Hashable, Sendable {
    public let id: RPCID
    public let result: JSONValue?
    public let error: JSONRPCErrorObject?
    public let metadata: JSONValue?
}

public enum JSONRPCMessage: Hashable, Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
}

public extension JSONRPCMessage {
    static func decode(line data: Data) throws -> JSONRPCMessage {
        guard String(data: data, encoding: .utf8) != nil else {
            throw JSONRPCDecodingError.invalidUTF8
        }

        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JSONRPCDecodingError.invalidJSON(String(describing: error))
        }

        guard let object = root.objectValue else {
            throw JSONRPCDecodingError.rootIsNotObject
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            throw JSONRPCDecodingError.unsupportedVersion
        }

        let metadata = object["_meta"]
        if let methodValue = object["method"] {
            guard let method = methodValue.stringValue, !method.isEmpty else {
                throw JSONRPCDecodingError.invalidRequest
            }
            guard object["result"] == nil, object["error"] == nil else {
                throw JSONRPCDecodingError.invalidRequest
            }
            if let rawID = object["id"] {
                guard let id = RPCID(jsonValue: rawID) else {
                    throw JSONRPCDecodingError.invalidIdentifier
                }
                return .request(.init(id: id, method: method, params: object["params"], metadata: metadata))
            }
            return .notification(.init(method: method, params: object["params"], metadata: metadata))
        }

        guard let rawID = object["id"], let id = RPCID(jsonValue: rawID) else {
            throw JSONRPCDecodingError.invalidResponse
        }
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil
        guard hasResult != hasError else {
            throw JSONRPCDecodingError.invalidResponse
        }

        if let rawError = object["error"] {
            guard
                let errorObject = rawError.objectValue,
                let rawCode = errorObject["code"]?.intValue,
                let code = Int(exactly: rawCode),
                let message = errorObject["message"]?.stringValue
            else {
                throw JSONRPCDecodingError.invalidErrorObject
            }
            return .response(.init(
                id: id,
                result: nil,
                error: .init(code: code, message: message, data: errorObject["data"]),
                metadata: metadata
            ))
        }

        return .response(.init(id: id, result: object["result"], error: nil, metadata: metadata))
    }

    static func request(id: RPCID, method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func response(id: RPCID, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id.jsonValue, "result": result])
    }

    static func errorResponse(id: RPCID, error: JSONRPCErrorObject) -> JSONValue {
        var value: [String: JSONValue] = [
            "code": .integer(Int64(error.code)),
            "message": .string(error.message),
        ]
        if let data = error.data { value["data"] = data }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": .object(value),
        ])
    }
}
