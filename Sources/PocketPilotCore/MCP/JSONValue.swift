import Foundation

/// Owner: mcp. A small JSON value type used for JSON-RPC messages and tool schemas.
/// Parsing goes through JSONSerialization (with real Bool detection); serialization is hand-written
/// so output is deterministic (sorted keys) and integers never print as "1.0".
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Parsing

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            throw ParseError(message: detail)
        }
        return try JSONValue(any: any)
    }

    public static func parse(_ string: String) throws -> JSONValue { try parse(Data(string.utf8)) }

    public init(any: Any) throws {
        switch any {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            self = .array(try a.map { try JSONValue(any: $0) })
        case let d as [String: Any]:
            var o: [String: JSONValue] = [:]
            for (k, v) in d { o[k] = try JSONValue(any: v) }
            self = .object(o)
        default:
            throw ParseError(message: "Unsupported JSON value of type \(type(of: any))")
        }
    }

    // MARK: Serialization

    public func serialized() -> Data { Data(serializedString().utf8) }

    public func serializedString() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d): out += JSONValue.format(d)
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(k, into: &out)
                out += ":"
                o[k]!.write(into: &out)
            }
            out += "}"
        }
    }

    static func format(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var isNull: Bool { self == .null }

    /// Short type name for error messages ("a string", "a number", ...).
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .number: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { serializedString() }
}
