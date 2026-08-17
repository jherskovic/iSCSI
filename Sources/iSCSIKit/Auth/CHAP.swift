import CryptoKit
import Foundation

/// CHAP authentication for the iSCSI security negotiation stage
/// (RFC 7143 §12.1). Algorithm 5 = MD5: R = MD5(I || secret || C).
///
/// MD5 is cryptographically broken in general but is what the iSCSI CHAP
/// exchange specifies and what every deployed target implements.
public enum CHAP {
    /// Whether the app offers mutual CHAP, and whether the daemon acts on
    /// credentials already stored for it.
    ///
    /// **Off since 2026-08-17, and not because this implementation is in
    /// doubt.** It is exercised end to end in `AuthTraceTests`, and against a
    /// real target the wire trace shows a well-formed RFC 7143 §12.1.3
    /// exchange: `CHAP_N CHAP_R CHAP_I CHAP_C` in one Login Request, mirroring
    /// the encodings the target itself chose. One-way and mutual logins were
    /// run minutes apart against the same target with the same credentials —
    /// one-way succeeded, mutual was refused with 0x02/0x01.
    ///
    /// The target is what cannot answer. TrueNAS SCALE writes `OutgoingUser`
    /// into `/etc/scst.conf` and never loads it into `/sys/kernel/scst_tgt/`,
    /// across a service restart, so `iscsi-scstd` logs "CHAP target auth.: no
    /// outgoing credentials configured" and rejects the login without ever
    /// composing an answer. A switch that turns a working target into a broken
    /// one is worse than no switch.
    ///
    /// This gates *use*, not storage. A record that already names a mutual
    /// user keeps it, the keychain keeps the secret, and setting this back to
    /// `true` restores the feature with nothing re-entered. Deleting the
    /// credentials instead would make the retreat one-way.
    public static let mutualIsOffered = false

    public enum CredentialError: Error, LocalizedError, Equatable {
        case emptyName
        case emptySecret(label: String)
        case secretTooShort(label: String, length: Int)

        public var errorDescription: String? {
            switch self {
            case .emptyName:
                return "A CHAP user name is required."
            case .emptySecret(let label):
                return "The \(label) is empty."
            case .secretTooShort(let label, let length):
                return "The \(label) is \(length) characters; "
                     + "at least \(Credentials.minimumSecretLength) are required."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .emptyName:
                return nil
            case .emptySecret, .secretTooShort:
                return "RFC 7143 sets 12 characters as the minimum, and most targets "
                     + "reject anything shorter with an error that says only "
                     + "“authentication failure”."
            }
        }
    }

    public struct Credentials: Sendable, Equatable {
        public var name: String
        public var secret: String
        /// For mutual CHAP: what the *target* must prove it knows.
        public var mutualName: String?
        public var mutualSecret: String?

        /// RFC 7143 §12.1.1's floor. Below this, a captured exchange is
        /// brute-forceable offline: the response is one MD5 over a short input,
        /// and both the id and the challenge that go into it are chosen by
        /// whoever we are talking to.
        public static let minimumSecretLength = 12

        public init(name: String, secret: String, mutualName: String? = nil, mutualSecret: String? = nil) {
            self.name = name
            self.secret = secret
            self.mutualName = mutualName
            self.mutualSecret = mutualSecret
        }

        /// Throws rather than accepting a secret no target should honour.
        ///
        /// The non-throwing initialiser above stays for tests and for callers
        /// holding an already-validated secret; this is what anything taking a
        /// secret from a human or a file should use. The case it exists for is
        /// an *empty* secret: `--chap-user x` with the secret argument forgotten
        /// used to produce `MD5(id ‖ "" ‖ challenge)` — a complete, well-formed
        /// exchange that tells the peer the secret is empty.
        public static func validated(name: String, secret: String,
                                     mutualName: String? = nil,
                                     mutualSecret: String? = nil) throws -> Credentials {
            guard !name.isEmpty else { throw CredentialError.emptyName }
            try check(secret, label: "CHAP secret")
            if let mutualSecret { try check(mutualSecret, label: "mutual CHAP secret") }
            return Credentials(name: name, secret: secret,
                               mutualName: mutualName, mutualSecret: mutualSecret)
        }

        private static func check(_ secret: String, label: String) throws {
            guard !secret.isEmpty else { throw CredentialError.emptySecret(label: label) }
            guard secret.utf8.count >= minimumSecretLength else {
                throw CredentialError.secretTooShort(label: label, length: secret.utf8.count)
            }
        }

        public var wantsMutual: Bool { mutualSecret != nil }
    }

    /// R = MD5(id || secret || challenge)
    public static func response(id: UInt8, secret: String, challenge: Data) -> Data {
        var md5 = Insecure.MD5()
        md5.update(data: Data([id]))
        md5.update(data: Data(secret.utf8))
        md5.update(data: challenge)
        return Data(md5.finalize())
    }

    // MARK: Text-value encoding (RFC 7143 §6.1: hex 0x..., base64 0b..., decimal)

    public static func encodeHex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    public static func decodeValue(_ s: String) throws -> Data {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let hex = s.dropFirst(2)
            guard !hex.isEmpty else { throw NegotiationError.invalidValue(key: "CHAP", value: s) }
            // Odd-length hex strings are left-zero-padded per §6.1.
            let padded = hex.count % 2 == 0 ? String(hex) : "0" + hex
            var out = Data(capacity: padded.count / 2)
            var index = padded.startIndex
            while index < padded.endIndex {
                let next = padded.index(index, offsetBy: 2)
                guard let byte = UInt8(padded[index ..< next], radix: 16) else {
                    throw NegotiationError.invalidValue(key: "CHAP", value: s)
                }
                out.append(byte)
                index = next
            }
            return out
        }
        if s.hasPrefix("0b") || s.hasPrefix("0B") {
            guard let out = Data(base64Encoded: String(s.dropFirst(2))) else {
                throw NegotiationError.invalidValue(key: "CHAP", value: s)
            }
            return out
        }
        // Decimal integer (rare; used for CHAP_I mostly).
        guard let n = UInt64(s) else {
            throw NegotiationError.invalidValue(key: "CHAP", value: s)
        }
        var big = Data()
        var v = n
        repeat {
            big.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return big
    }

    public static func decodeID(_ s: String) throws -> UInt8 {
        guard let n = UInt16(s), n <= 255 else {
            throw NegotiationError.invalidValue(key: "CHAP_I", value: s)
        }
        return UInt8(n)
    }

    // MARK: Initiator-side exchange state

    /// Drives the initiator's half of the CHAP exchange inside the security
    /// negotiation stage.
    public struct InitiatorExchange: Sendable {
        let credentials: Credentials
        /// Our challenge to the target (mutual CHAP), retained for verification.
        private(set) var mutualChallenge: Data?
        private(set) var mutualID: UInt8?

        public init(credentials: Credentials) {
            self.credentials = credentials
        }

        /// Step 1: we declare the algorithm.
        public func algorithmProposal() -> TextParameters {
            var p = TextParameters()
            p.append("CHAP_A", "5")
            return p
        }

        /// Step 2: target sent CHAP_A/CHAP_I/CHAP_C — compute our response,
        /// optionally appending our own challenge for mutual CHAP.
        public mutating func respond(
            to params: TextParameters,
            randomBytes: (Int) -> Data = { count in Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }) }
        ) throws -> TextParameters {
            guard params["CHAP_A"] == "5" else {
                throw NegotiationError.authenticationFailed("target chose CHAP_A=\(params["CHAP_A"] ?? "<missing>")")
            }
            guard let iStr = params["CHAP_I"], let cStr = params["CHAP_C"] else {
                throw NegotiationError.authenticationFailed("target CHAP challenge missing CHAP_I/CHAP_C")
            }
            let id = try decodeID(iStr)
            let challenge = try decodeValue(cStr)
            guard !challenge.isEmpty else {
                throw NegotiationError.authenticationFailed("empty CHAP challenge")
            }

            var out = TextParameters()
            out.append("CHAP_N", credentials.name)
            out.append("CHAP_R", encodeHex(response(id: id, secret: credentials.secret, challenge: challenge)))

            if credentials.wantsMutual {
                let myID = UInt8.random(in: 0 ... 255)
                let myChallenge = randomBytes(16)
                mutualID = myID
                mutualChallenge = myChallenge
                out.append("CHAP_I", String(myID))
                out.append("CHAP_C", encodeHex(myChallenge))
            }
            return out
        }

        /// Step 3 (mutual only): verify the target's CHAP_N/CHAP_R answer.
        public func verifyMutual(_ params: TextParameters) throws {
            guard credentials.wantsMutual else { return }
            guard let mutualSecret = credentials.mutualSecret,
                  let id = mutualID, let challenge = mutualChallenge
            else {
                throw NegotiationError.authenticationFailed("mutual CHAP state missing")
            }
            guard let name = params["CHAP_N"], let rStr = params["CHAP_R"] else {
                throw NegotiationError.authenticationFailed("target did not answer mutual CHAP")
            }
            if let expectedName = credentials.mutualName, expectedName != name {
                throw NegotiationError.authenticationFailed("mutual CHAP name mismatch")
            }
            let expected = response(id: id, secret: mutualSecret, challenge: challenge)
            let got = try decodeValue(rStr)
            // Constant-time-ish comparison; both sides are fixed 16-byte MD5.
            guard got.count == expected.count,
                  zip(got, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0
            else {
                throw NegotiationError.authenticationFailed("mutual CHAP response mismatch")
            }
        }
    }
}
