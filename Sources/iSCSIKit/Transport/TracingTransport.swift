import Foundation

/// Wraps a transport and prints a one-line summary of every PDU in each
/// direction. Enable by wrapping, or via `ISCSI_DEBUG=1` at a call site.
public final class TracingTransport: ConnectionTransport, @unchecked Sendable {
    private let inner: any ConnectionTransport
    private let label: String
    private let sink: @Sendable (String) -> Void
    // Deframers to interpret the byte stream we're relaying (best-effort;
    // digests off since we can't know the negotiated state here).
    private let lock = NSLock()
    private var txFramer = PDUDeframer()
    private var rxFramer = PDUDeframer()

    public init(
        _ inner: any ConnectionTransport,
        label: String = "iscsi",
        sink: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.inner = inner
        self.label = label
        self.sink = sink
    }

    public func send(_ data: Data) async throws {
        trace(direction: "→", data: data, framer: \.txFramer)
        try await inner.send(data)
    }

    public func receive() async throws -> Data? {
        let data = try await inner.receive()
        if let data, !data.isEmpty {
            trace(direction: "←", data: data, framer: \.rxFramer)
        }
        return data
    }

    public func close() async {
        sink("[\(label)] close")
        await inner.close()
    }

    private func trace(direction: String, data: Data, framer keyPath: ReferenceWritableKeyPath<TracingTransport, PDUDeframer>) {
        lock.lock()
        self[keyPath: keyPath].append(data)
        var lines: [String] = []
        while let raw = try? self[keyPath: keyPath].next() {
            lines.append(summary(raw))
        }
        lock.unlock()
        for line in lines {
            sink("[\(label)] \(direction) \(line)")
        }
    }

    /// Keys whose values must never reach a log: `CHAP_R` beside `CHAP_I` and
    /// `CHAP_C` is the full input for an offline attack on the secret, and the
    /// realistic leak is a `--debug` trace pasted into a bug report. Redaction
    /// lives here, not at call sites, so no caller can forget it.
    private static let sensitiveKeys: Set<String> = [
        "CHAP_R", "CHAP_C", "CHAP_N", "CHAP_I", "CHAP_A",
    ]

    private static func redactIfSensitive(key: String, value: String) -> String {
        guard sensitiveKeys.contains(key.uppercased()) else { return value }
        // Length, not content: it is the one property worth having in a trace
        // (a truncated or empty challenge is a real bug) and it discloses
        // nothing useful about the secret.
        return "<redacted \(value.utf8.count)B>"
    }

    private func summary(_ raw: RawPDU) -> String {
        let opName = raw.opcode.map { "\($0)" } ?? String(format: "op=0x%02x", raw.opcodeByte)
        var parts = [opName, String(format: "itt=0x%08x", raw.initiatorTaskTag)]
        if raw.data.count > 0 {
            if let text = try? TextParameters.decode(raw.data), !text.isEmpty {
                let kv = text.pairs
                    .map { "\($0.key)=\(Self.redactIfSensitive(key: $0.key, value: $0.value))" }
                    .joined(separator: " ")
                parts.append("{\(kv)}")
            } else {
                parts.append("data=\(raw.data.count)B")
            }
        }
        if raw.opcode == .loginResponse {
            let sc = raw.bhs.u8(36)
            let sd = raw.bhs.u8(37)
            parts.append(String(format: "status=%d/%d", sc, sd))
        }
        return parts.joined(separator: " ")
    }
}
