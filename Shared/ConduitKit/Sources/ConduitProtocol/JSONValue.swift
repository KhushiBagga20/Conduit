//
//  JSONValue.swift
//  ConduitProtocol
//
//  A payload is an open JSON object: receivers must ignore fields they do
//  not know (spec §3), so payloads are carried as a JSON tree and decoded
//  into typed structs only by the code that understands them.
//

import Foundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Whole numbers stay integers so a round trip never turns `42` into `42.0`.
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int64(exactly: value)
        default: return nil
        }
    }
}

// MARK: - Codable

private struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension JSONValue: Codable {

    // Null can only be recognised by a parent container (decodeNil), so
    // objects and arrays handle their own null members; a scalar decoded
    // on its own is never null.
    public init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: JSONKey.self) {
            var fields: [String: JSONValue] = [:]
            for key in object.allKeys {
                fields[key.stringValue] = try object.decodeNil(forKey: key)
                    ? .null
                    : try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(fields)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !array.isAtEnd {
                items.append(try array.decodeNil() ? .null : try array.decode(JSONValue.self))
            }
            self = .array(items)
            return
        }

        let scalar = try decoder.singleValueContainer()
        if let value = try? scalar.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? scalar.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? scalar.decode(Double.self) {
            self = .double(value)
        } else if let value = try? scalar.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let fields):
            var object = encoder.container(keyedBy: JSONKey.self)
            for (key, value) in fields {
                if value == .null {
                    try object.encodeNil(forKey: JSONKey(stringValue: key))
                } else {
                    try object.encode(value, forKey: JSONKey(stringValue: key))
                }
            }
        case .array(let items):
            var array = encoder.unkeyedContainer()
            for item in items {
                if item == .null { try array.encodeNil() } else { try array.encode(item) }
            }
        case .null:
            var scalar = encoder.singleValueContainer()
            try scalar.encodeNil()
        case .bool(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .int(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .double(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .string(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        }
    }
}

// MARK: - Typed payloads

extension JSONValue {

    /// Convert any Encodable into a JSON tree.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this tree into a typed payload.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
