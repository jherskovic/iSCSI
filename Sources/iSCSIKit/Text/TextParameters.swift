import Foundation

/// key=value text parameters carried in Login/Text PDU data segments
/// (RFC 7143 §6.1): UTF-8 `key=value` pairs, each terminated by NUL.
/// Order is preserved — it matters for some negotiations (e.g. AuthMethod
/// preference lists) and for byte-exact golden tests.
public struct TextParameters: Sendable, Equatable {
    public private(set) var pairs: [(key: String, value: String)] = []

    public init() {}

    public init(_ pairs: [(key: String, value: String)]) {
        self.pairs = pairs
    }

    public static func == (lhs: TextParameters, rhs: TextParameters) -> Bool {
        lhs.pairs.count == rhs.pairs.count
            && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public subscript(key: String) -> String? {
        get { pairs.last(where: { $0.key == key })?.value }
        set {
            if let newValue {
                if let i = pairs.firstIndex(where: { $0.key == key }) {
                    pairs[i].value = newValue
                } else {
                    pairs.append((key, newValue))
                }
            } else {
                pairs.removeAll { $0.key == key }
            }
        }
    }

    public mutating func append(_ key: String, _ value: String) {
        pairs.append((key, value))
    }

    public var isEmpty: Bool { pairs.isEmpty }
    public var keys: [String] { pairs.map(\.key) }

    /// Wire form: key=value NUL, concatenated.
    public func encode() -> Data {
        var out = Data()
        for (key, value) in pairs {
            out.append(Data(key.utf8))
            out.append(0x3D) // '='
            out.append(Data(value.utf8))
            out.append(0x00)
        }
        return out
    }

    /// Parse a complete text buffer. `allowUnterminatedFinal` accepts a final
    /// pair without trailing NUL (seen from some targets).
    public static func decode(_ data: Data, allowUnterminatedFinal: Bool = true) throws -> TextParameters {
        var result = TextParameters()
        var start = data.startIndex
        var i = data.startIndex
        func take(_ chunk: Data) throws {
            guard let eq = chunk.firstIndex(of: 0x3D) else {
                throw PDUError.malformed("text pair without '='")
            }
            guard let key = String(data: chunk[chunk.startIndex ..< eq], encoding: .utf8),
                  let value = String(data: chunk[chunk.index(after: eq)...], encoding: .utf8)
            else {
                throw PDUError.malformed("text pair not UTF-8")
            }
            guard !key.isEmpty else { throw PDUError.malformed("empty text key") }
            result.append(key, value)
        }
        while i < data.endIndex {
            if data[i] == 0x00 {
                try take(data[start ..< i])
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        if start < data.endIndex {
            guard allowUnterminatedFinal else {
                throw PDUError.malformed("unterminated final text pair")
            }
            try take(data[start...])
        }
        return result
    }
}
