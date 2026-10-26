import Foundation

/// A JSON value with **ordered** object keys, for building request bodies and
/// schemas. Key order matters: providers that constrain output to a schema
/// generate fields in the schema's order (e.g. `reason` before `from`/`to`).
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// The value for `key` in an object.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// An object with `key` set (replaced if present, appended otherwise).
    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index].value = value
        } else {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    // MARK: Serialization

    /// Compact JSON text, keys in their stored order.
    public func serialized() -> String {
        var output = ""
        write(to: &output)
        return output
    }

    public func data() -> Data { Data(serialized().utf8) }

    private func write(to output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
                output += String(Int64(value))
            } else if value.isFinite {
                output += String(value)
            } else {
                output += "null"
            }
        case .string(let value): Self.writeString(value, to: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(to: &output)
            }
            output += "]"
        case .object(let pairs):
            output += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { output += "," }
                Self.writeString(pair.key, to: &output)
                output += ":"
                pair.value.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    // MARK: Parsing

    /// Parses JSON text. Object keys come back sorted (parsing is for reading
    /// values, where order doesn't matter).
    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONValue(foundation: object)
    }

    private init(foundation object: Any) throws {
        switch object {
        case is NSNull: self = .null
        case let number as NSNumber:
            // `JSONSerialization` boxes booleans as NSNumber; tell them apart by type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(try dictionary.keys.sorted().map { ($0, try JSONValue(foundation: dictionary[$0]!)) })
        default:
            throw ProviderError.invalidResponse("Unexpected JSON value")
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements.map { ($0.0, $0.1) }) }
    public init(nilLiteral: ()) { self = .null }
}
