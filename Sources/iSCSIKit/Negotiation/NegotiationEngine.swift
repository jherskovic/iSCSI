import Foundation

/// Initiator-side text-key negotiation (RFC 7143 §6.2, §13).
///
/// The engine tracks what we proposed, folds in the target's answers and
/// counter-offers according to each key's result function, and produces the
/// final `OperationalParameters`. It is transport-free: the login state
/// machine feeds it decoded text parameters.
public struct NegotiationEngine: Sendable {
    /// Result function per RFC 7143 §6.2 / §13.
    enum ResultFunction {
        case booleanAnd // result Yes only if both Yes (ImmediateData, markers)
        case booleanOr // result Yes if either Yes (InitialR2T, DataPDUInOrder)
        case numericMin // min(ours, theirs)
        case numericMax // max(ours, theirs)
        case declarative // each side states its own; no folding
        case listSelect // we offer an ordered list, they pick one
    }

    struct KeyDef {
        let result: ResultFunction
        let range: ClosedRange<UInt32>?

        init(_ result: ResultFunction, range: ClosedRange<UInt32>? = nil) {
            self.result = result
            self.range = range
        }
    }

    static let keys: [String: KeyDef] = [
        "HeaderDigest": KeyDef(.listSelect),
        "DataDigest": KeyDef(.listSelect),
        "MaxRecvDataSegmentLength": KeyDef(.declarative, range: 512 ... 0xFF_FFFF),
        "MaxConnections": KeyDef(.numericMin, range: 1 ... 65535),
        "InitialR2T": KeyDef(.booleanOr),
        "ImmediateData": KeyDef(.booleanAnd),
        "MaxBurstLength": KeyDef(.numericMin, range: 512 ... 0xFF_FFFF),
        "FirstBurstLength": KeyDef(.numericMin, range: 512 ... 0xFF_FFFF),
        "DefaultTime2Wait": KeyDef(.numericMax, range: 0 ... 3600),
        "DefaultTime2Retain": KeyDef(.numericMin, range: 0 ... 3600),
        "MaxOutstandingR2T": KeyDef(.numericMin, range: 1 ... 65535),
        "DataPDUInOrder": KeyDef(.booleanOr),
        "DataSequenceInOrder": KeyDef(.booleanOr),
        "ErrorRecoveryLevel": KeyDef(.numericMin, range: 0 ... 2),
        "OFMarker": KeyDef(.booleanAnd),
        "IFMarker": KeyDef(.booleanAnd),
    ]

    /// Our proposals: key → value string we sent.
    private(set) var proposed: [String: String] = [:]
    /// Keys the target has answered.
    private(set) var answered: Set<String> = []
    /// Folded results (only keys that were actually negotiated).
    private(set) var results: [String: String] = [:]
    /// Declarative facts the target stated.
    private(set) var targetDeclared: [String: String] = [:]
    /// Keys answered NotUnderstood (fall back to defaults, recorded for logs).
    public private(set) var notUnderstood: Set<String> = []
    /// Keys the target rejected (fall back to defaults, recorded for logs).
    public private(set) var rejected: Set<String> = []
    /// Keys answered Irrelevant (§6.2; fall back to defaults).
    public private(set) var irrelevant: Set<String> = []
    /// Every key the target has used once — renegotiation detection (§6.3).
    private var seenKeys: Set<String> = []
    /// Keys for which repeated declarations are explicitly allowed (§6.3).
    private static let repeatableKeys: Set<String> = ["TargetAddress"]

    public init() {}

    // MARK: Proposing

    /// Build our operational-stage proposal from desired parameters.
    /// Returns ordered text parameters to put in the login request.
    public mutating func proposeOperational(
        desired: DesiredParameters,
        sessionType: SessionType
    ) -> TextParameters {
        var out = TextParameters()
        func add(_ key: String, _ value: String) {
            out.append(key, value)
            proposed[key] = value
        }
        add("HeaderDigest", desired.offerDigests ? "CRC32C,None" : "None")
        add("DataDigest", desired.offerDigests ? "CRC32C,None" : "None")
        add("MaxRecvDataSegmentLength", String(desired.maxRecvDataSegmentLength))
        if sessionType == .normal {
            add("ErrorRecoveryLevel", "0")
            add("InitialR2T", desired.initialR2T ? "Yes" : "No")
            add("ImmediateData", desired.immediateData ? "Yes" : "No")
            add("MaxBurstLength", String(desired.maxBurstLength))
            add("FirstBurstLength", String(desired.firstBurstLength))
            add("MaxConnections", "1")
            add("MaxOutstandingR2T", String(desired.maxOutstandingR2T))
            add("DefaultTime2Wait", "2")
            add("DefaultTime2Retain", "0")
            add("DataPDUInOrder", "Yes")
            add("DataSequenceInOrder", "Yes")
        }
        return out
    }

    // MARK: Processing the target's text

    /// Fold in every key from a target login/text response. Returns the reply
    /// parameters we must send for keys the *target* newly offered.
    public mutating func process(_ params: TextParameters) throws -> TextParameters {
        var replies = TextParameters()
        for (key, value) in params.pairs {
            if let reply = try process(key: key, value: value) {
                replies.append(key, reply)
            }
        }
        return replies
    }

    /// Handle one key from the target. Returns a reply value if one is owed.
    mutating func process(key: String, value: String) throws -> String? {
        // §6.3: renegotiating or redeclaring a key is a protocol error the
        // initiator MUST detect (and drop the connection on); only specific
        // keys — TargetAddress — allow repeated declarations.
        if !Self.repeatableKeys.contains(key) {
            guard seenKeys.insert(key).inserted else {
                throw NegotiationError.protocolViolation("renegotiation of key \(key)")
            }
        }

        // Declarative session facts from the target.
        switch key {
        case "TargetPortalGroupTag", "TargetAlias", "TargetName", "TargetAddress":
            targetDeclared[key] = value
            return nil
        default:
            break
        }

        if value == "NotUnderstood" {
            guard proposed[key] != nil else {
                throw NegotiationError.protocolViolation("NotUnderstood for unproposed key \(key)")
            }
            // §6.2: an implementation MUST comprehend every key this document
            // defines; NotUnderstood for one of them is a protocol error.
            guard Self.keys[key] == nil else {
                throw NegotiationError.protocolViolation(
                    "target answered NotUnderstood for standard key \(key)")
            }
            notUnderstood.insert(key)
            answered.insert(key)
            return nil
        }

        // §6.2: a legal answer for a key made irrelevant by another selection;
        // the key falls back to its default and login continues.
        if value == "Irrelevant" {
            guard proposed[key] != nil else {
                throw NegotiationError.protocolViolation("Irrelevant for unproposed key \(key)")
            }
            irrelevant.insert(key)
            answered.insert(key)
            return nil
        }

        guard let def = Self.keys[key] else {
            return "NotUnderstood"
        }

        if value == "Reject" {
            guard proposed[key] != nil else {
                throw NegotiationError.protocolViolation("Reject for unproposed key \(key)")
            }
            // The negotiation for this key failed: it stays at its default
            // (list-select keys land on None). Login continues.
            answered.insert(key)
            rejected.insert(key)
            if def.result == .listSelect { results[key] = "None" }
            return nil
        }

        if let range = def.range, def.result != .listSelect {
            guard let n = Self.numericValue(value), range.contains(n) else {
                throw NegotiationError.invalidValue(key: key, value: value)
            }
        }

        if let ours = proposed[key] {
            // Answer to our proposal: fold.
            answered.insert(key)
            results[key] = try fold(key: key, def: def, ours: ours, theirs: value)
            return nil
        } else {
            // Target-initiated offer.
            if def.result == .declarative {
                // They declared their own value (e.g. MaxRecvDataSegmentLength);
                // no reply is owed.
                results[key] = value
                return nil
            }
            let reply = try answerOffer(key: key, def: def, theirs: value)
            results[key] = try combineOffer(key: key, def: def, offer: value, reply: reply)
            return reply
        }
    }

    private func fold(key: String, def: KeyDef, ours: String, theirs: String) throws -> String {
        switch def.result {
        case .booleanAnd:
            try requireBool(key, theirs)
            return (ours == "Yes" && theirs == "Yes") ? "Yes" : "No"
        case .booleanOr:
            try requireBool(key, theirs)
            return (ours == "Yes" || theirs == "Yes") ? "Yes" : "No"
        case .numericMin:
            // Fold locally: real targets (LIO) echo their configured value
            // instead of the fold; min() keeps us within our own proposal.
            return String(min(try num(key, ours), try num(key, theirs)))
        case .numericMax:
            return String(max(try num(key, ours), try num(key, theirs)))
        case .declarative:
            return theirs
        case .listSelect:
            // Their pick must be one of our offers.
            let offers = ours.split(separator: ",").map(String.init)
            guard offers.contains(theirs) else {
                throw NegotiationError.invalidValue(key: key, value: theirs)
            }
            return theirs
        }
    }

    /// Result when the *target* opened the negotiation and we replied.
    private func combineOffer(key: String, def: KeyDef, offer: String, reply: String) throws -> String {
        switch def.result {
        case .booleanAnd:
            return (offer == "Yes" && reply == "Yes") ? "Yes" : "No"
        case .booleanOr:
            return (offer == "Yes" || reply == "Yes") ? "Yes" : "No"
        case .numericMin:
            return String(min(try num(key, offer), try num(key, reply)))
        case .numericMax:
            return String(max(try num(key, offer), try num(key, reply)))
        case .declarative:
            return offer
        case .listSelect:
            return reply
        }
    }

    private func answerOffer(key: String, def: KeyDef, theirs: String) throws -> String {
        switch def.result {
        case .booleanAnd:
            // §13: AND + No is determined — the answer must restate it.
            // Otherwise our choice: markers off, everything else Yes.
            try requireBool(key, theirs)
            if theirs == "No" { return "No" }
            return (key == "OFMarker" || key == "IFMarker") ? "No" : "Yes"
        case .booleanOr:
            // OR + Yes is likewise determined; our own preference is No.
            try requireBool(key, theirs)
            return theirs == "Yes" ? "Yes" : "No"
        case .numericMin:
            let t = try num(key, theirs)
            // Keys where we hold a hard preference answer with min(ours, theirs);
            // for the rest we're flexible and accept their value.
            let ourCeiling: UInt32? = key == "ErrorRecoveryLevel" ? 0 : (key == "MaxConnections" ? 1 : nil)
            if let ceiling = ourCeiling { return String(min(ceiling, t)) }
            return theirs
        case .numericMax:
            _ = try num(key, theirs)
            return theirs // accept their value
        case .declarative:
            return theirs
        case .listSelect:
            // They offered a list; pick the first entry we support.
            let supported = ["None", "CRC32C"]
            let offers = theirs.split(separator: ",").map(String.init)
            guard let pick = offers.first(where: { supported.contains($0) }) else {
                throw NegotiationError.invalidValue(key: key, value: theirs)
            }
            return pick
        }
    }

    private func requireBool(_ key: String, _ v: String) throws {
        guard v == "Yes" || v == "No" else {
            throw NegotiationError.invalidValue(key: key, value: v)
        }
    }

    private func num(_ key: String, _ v: String) throws -> UInt32 {
        guard let n = Self.numericValue(v) else {
            throw NegotiationError.invalidValue(key: key, value: v)
        }
        return n
    }

    /// §6.1 numerical-value: a decimal-constant or a hex-constant ("0x...").
    static func numericValue(_ v: String) -> UInt32? {
        if v.hasPrefix("0x") || v.hasPrefix("0X") {
            let digits = v.dropFirst(2)
            guard !digits.isEmpty else { return nil }
            return UInt32(digits, radix: 16)
        }
        return UInt32(v)
    }

    // MARK: Final parameters

    /// Resolve everything into operational parameters. Keys never negotiated
    /// stay at RFC defaults. `desired` supplies our declared MRDSL.
    public func finalParameters(desired: DesiredParameters) throws -> OperationalParameters {
        var p = OperationalParameters()
        p.initiatorMaxRecvDataSegmentLength = desired.maxRecvDataSegmentLength

        func bool(_ key: String, _ into: inout Bool) {
            if let v = results[key] { into = v == "Yes" }
        }
        func number(_ key: String, _ into: inout UInt32) {
            if let v = results[key], let n = Self.numericValue(v) { into = n }
        }

        if let v = results["HeaderDigest"] { p.headerDigest = v == "CRC32C" }
        if let v = results["DataDigest"] { p.dataDigest = v == "CRC32C" }
        number("MaxRecvDataSegmentLength", &p.targetMaxRecvDataSegmentLength)
        number("MaxConnections", &p.maxConnections)
        bool("InitialR2T", &p.initialR2T)
        bool("ImmediateData", &p.immediateData)
        number("MaxBurstLength", &p.maxBurstLength)
        number("FirstBurstLength", &p.firstBurstLength)
        number("DefaultTime2Wait", &p.defaultTime2Wait)
        number("DefaultTime2Retain", &p.defaultTime2Retain)
        number("MaxOutstandingR2T", &p.maxOutstandingR2T)
        bool("DataPDUInOrder", &p.dataPDUInOrder)
        bool("DataSequenceInOrder", &p.dataSequenceInOrder)
        number("ErrorRecoveryLevel", &p.errorRecoveryLevel)

        if let tpgt = targetDeclared["TargetPortalGroupTag"] {
            p.targetPortalGroupTag = Self.numericValue(tpgt).flatMap { UInt16(exactly: $0) }
        }
        p.targetAlias = targetDeclared["TargetAlias"]

        guard p.errorRecoveryLevel == 0 else {
            throw NegotiationError.invalidResult("ERL \(p.errorRecoveryLevel) > proposed 0")
        }
        try p.validate()
        return p
    }
}

/// What the initiator wants going into negotiation.
public struct DesiredParameters: Sendable, Equatable {
    public var offerDigests = true
    public var maxRecvDataSegmentLength: UInt32 = 262_144
    public var initialR2T = false // we prefer unsolicited data allowed
    public var immediateData = true
    public var maxBurstLength: UInt32 = 1 << 20
    /// Ask for as much unsolicited data as a burst can carry: a numericMin
    /// fold, so a target that buffers less answers with less; when it allows
    /// more, a write skips the R2T round trip, which is measurable.
    public var firstBurstLength: UInt32 = 1 << 20
    public var maxOutstandingR2T: UInt32 = 8

    public init() {}
}

public enum SessionType: String, Sendable {
    case normal = "Normal"
    case discovery = "Discovery"
}
