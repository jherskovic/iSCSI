import Foundation

/// Everything needed to log a new connection into a target.
public struct LoginConfig: Sendable {
    public var initiatorName: String
    public var sessionType: SessionType
    /// Required for normal sessions; ignored for discovery.
    public var targetName: String?
    /// nil → offer AuthMethod=None only.
    ///
    /// Note what that means, because it is not obvious at the call site and it
    /// was the shape of a real bug: a nil here is not "no preference", it is an
    /// instruction to log in unauthenticated. Anything that resolves credentials
    /// and can *fail* to find them must not pass the failure through as nil —
    /// see `requiresAuthentication`.
    public var chap: CHAP.Credentials?
    /// Refuse to log in without CHAP.
    ///
    /// Set by callers who know the target is configured for authentication, so
    /// that a credential lookup which silently returned nothing becomes a
    /// connection error instead of an unauthenticated session. The daemon
    /// already fails closed before it gets here; this is the backstop for any
    /// other caller, present because the failure mode is invisible — an
    /// unauthenticated session looks exactly like an authenticated one from
    /// every layer above.
    public var requiresAuthentication = false
    public var desired = DesiredParameters()
    public var isid: ISID
    public var tsih: UInt16 = 0
    public var cid: UInt16 = 0

    /// Where the authentication exchange narrates itself, or nil for silence.
    ///
    /// A closure rather than an `os.Logger` in this module, for two reasons.
    /// iSCSIKit does not get to name the app's logging subsystem — it is the
    /// half of the codebase that has no platform in it. And the place a CHAP
    /// failure is actually watched is `iscsictl --debug` on a terminal, which
    /// an os_log sink does not reach. The daemon points this at `DaemonLog`,
    /// the CLI points it at stderr next to the PDU trace, and tests leave it
    /// nil and observe no behaviour change at all.
    ///
    /// **Nothing secret may be written here.** User names, algorithm numbers,
    /// stage names and byte counts only — never a secret, never `CHAP_R`, never
    /// challenge bytes. `CHAP_R` is MD5 over the secret with an id and a
    /// challenge the peer chose, so publishing it to a log that outlives the
    /// connection hands an offline attack to anyone who reads the log. Where
    /// the shape of a value matters, log its length in the `<redacted NB>` form
    /// `TracingTransport` already uses.
    public var trace: (@Sendable (String) -> Void)?

    public init(
        initiatorName: String,
        sessionType: SessionType,
        targetName: String? = nil,
        chap: CHAP.Credentials? = nil,
        isid: ISID = .random(),
        trace: (@Sendable (String) -> Void)? = nil
    ) {
        self.initiatorName = initiatorName
        self.sessionType = sessionType
        self.targetName = targetName
        self.chap = chap
        self.isid = isid
        self.trace = trace
    }
}

public struct LoginResult: Sendable, Equatable {
    public var parameters: OperationalParameters
    public var tsih: UInt16
    /// The next StatSN we expect from the target (last login StatSN + 1).
    public var expStatSN: UInt32
    public var expCmdSN: UInt32
    public var maxCmdSN: UInt32
}

/// Initiator login state machine (RFC 7143 §5, §12): drives the security and
/// operational negotiation stages for one connection. Transport-free — the
/// caller sends the PDUs we emit and feeds responses back in.
public struct LoginStateMachine: Sendable {
    public enum Outcome: Sendable {
        case send(LoginRequestPDU)
        case success(LoginResult)
        /// Target redirected us (status class 1): reconnect to `address`
        /// ("ip:port" or "ip:port,tpgt") and start a fresh login.
        case redirect(address: String, permanent: Bool)
    }

    private enum Stage: Equatable {
        case awaitingAuthMethod
        case awaitingChapChallenge
        case awaitingChapResult
        case operational
        case done
    }

    /// Login-phase PDUs are capped at 8192 bytes of text until MRDSL is
    /// negotiated (RFC 7143 §6.3).
    static let loginTextLimit = 8192

    private let config: LoginConfig
    private var engine = NegotiationEngine()
    private var chapExchange: CHAP.InitiatorExchange?
    private var stage: Stage
    private var cmdSN: UInt32
    private var expStatSN: UInt32 = 0
    private var seenFirstResponse = false
    private var tsih: UInt16

    // C-bit handling
    private var incomingText = Data()
    private var outgoingRemainder = Data()
    private var pendingFlags: (transit: Bool, nsg: LoginStage) = (false, .securityNegotiation)
    /// CSG of the request most recently emitted; a success response must echo
    /// it (§11.12.3 ties every exchange to a stage).
    private var lastCSG: LoginStage = .securityNegotiation

    public init(config: LoginConfig, cmdSN: UInt32 = 0) {
        self.config = config
        self.cmdSN = cmdSN
        self.tsih = config.tsih
        self.chapExchange = config.chap.map { CHAP.InitiatorExchange(credentials: $0) }
        self.stage = .awaitingAuthMethod
    }

    // MARK: Building requests

    private func baseRequest() -> LoginRequestPDU {
        var pdu = LoginRequestPDU()
        pdu.versionMax = 0
        pdu.versionMin = 0
        pdu.isid = config.isid
        pdu.tsih = tsih
        pdu.initiatorTaskTag = 0
        pdu.cid = config.cid
        pdu.cmdSN = cmdSN
        pdu.expStatSN = expStatSN
        return pdu
    }

    /// Emit a request carrying `text` (or the next chunk of a split text),
    /// setting stage bits appropriately.
    private mutating func emit(
        text: Data,
        currentStage: LoginStage,
        transit: Bool,
        nsg: LoginStage
    ) -> LoginRequestPDU {
        var pdu = baseRequest()
        pdu.currentStage = currentStage
        lastCSG = currentStage
        // NSG is reserved when T=0 (§11.12.3) and reserved fields go out as
        // zero (§11.1); .securityNegotiation is the zero encoding.
        if text.count > Self.loginTextLimit {
            outgoingRemainder = text.dropFirst(Self.loginTextLimit)
            pendingFlags = (transit, nsg)
            pdu.continued = true
            pdu.transit = false
            pdu.nextStage = .securityNegotiation
            pdu.dataSegment = text.prefix(Self.loginTextLimit)
        } else {
            outgoingRemainder = Data()
            pdu.transit = transit
            pdu.nextStage = transit ? nsg : .securityNegotiation
            pdu.dataSegment = text
        }
        return pdu
    }

    // MARK: Tracing
    //
    // Read the contract on `LoginConfig.trace` before adding a line here. The
    // short version: names and lengths yes, key material never.

    private func note(_ message: String) {
        config.trace?("auth: \(message)")
    }

    /// The shape of a text value, for a log that must not carry its content.
    /// Same phrasing as `TracingTransport` so the two traces read as one.
    private static func shape(_ value: String?) -> String {
        guard let value else { return "<absent>" }
        return "<redacted \(value.utf8.count)B>"
    }

    /// RFC 7143 §11.13.5. Naming the code is the whole point: "status 2/1" sent
    /// a real debugging session looking at the initiator's credentials when the
    /// target was rejecting something else entirely.
    private static func describe(statusClass: UInt8, statusDetail: UInt8) -> String {
        let meaning: String?
        switch (statusClass, statusDetail) {
        case (0x02, 0x01): meaning = "authentication failure"
        case (0x02, 0x02): meaning = "authorization failure"
        case (0x02, 0x03): meaning = "target not found"
        case (0x02, 0x04): meaning = "target removed"
        case (0x02, 0x05): meaning = "unsupported version"
        case (0x02, 0x06): meaning = "too many connections"
        case (0x02, 0x07): meaning = "missing parameter"
        case (0x02, 0x08): meaning = "cannot include in session"
        case (0x02, 0x09): meaning = "session type not supported"
        case (0x02, 0x0A): meaning = "session does not exist"
        case (0x02, 0x0B): meaning = "invalid during login"
        case (0x03, 0x00): meaning = "target error"
        case (0x03, 0x01): meaning = "service unavailable"
        case (0x03, 0x02): meaning = "out of resources"
        default: meaning = nil
        }
        let code = String(format: "status 0x%02X/0x%02X", statusClass, statusDetail)
        return meaning.map { "\(code) (\($0))" } ?? code
    }

    private var stageName: String {
        switch stage {
        case .awaitingAuthMethod:    return "awaiting AuthMethod"
        case .awaitingChapChallenge: return "awaiting CHAP challenge"
        case .awaitingChapResult:    return "awaiting CHAP result"
        case .operational:           return "negotiating operational parameters"
        case .done:                  return "already complete"
        }
    }

    /// First login request.
    public mutating func start() -> LoginRequestPDU {
        var params = TextParameters()
        params.append("InitiatorName", config.initiatorName)
        params.append("SessionType", config.sessionType.rawValue)
        if config.sessionType == .normal, let target = config.targetName {
            params.append("TargetName", target)
        }
        if chapExchange != nil {
            // Whether we will challenge back is decided here and not announced
            // until the response, so it is worth stating up front: a target that
            // rejects only the mutual half fails three PDUs later, and the trace
            // is the only thing that says which half we were attempting.
            note("offering AuthMethod=CHAP as “\(config.chap?.name ?? "?")”, "
                 + "mutual=\(config.chap?.wantsMutual == true ? "yes" : "no")"
                 + (config.chap?.mutualName.map { ", expecting the target to name “\($0)”" } ?? ""))
            params.append("AuthMethod", "CHAP")
            return emit(
                text: params.encode(),
                currentStage: .securityNegotiation,
                transit: false,
                nsg: .securityNegotiation
            )
        } else {
            // Worth a line of its own: an unauthenticated session looks
            // identical to an authenticated one from every layer above, so this
            // is the only place that says the credentials were never there.
            note("offering AuthMethod=None — no credentials configured")
            params.append("AuthMethod", "None")
            stage = .operational // next response should carry us into LO stage
            return emit(
                text: params.encode(),
                currentStage: .securityNegotiation,
                transit: true,
                nsg: .loginOperationalNegotiation
            )
        }
    }

    // MARK: Receiving

    public mutating func receive(_ response: LoginResponsePDU) throws -> Outcome {
        guard stage != .done else {
            throw NegotiationError.protocolViolation("login already complete")
        }

        // Status handling first.
        if response.isRedirect {
            let text = try TextParameters.decode(incomingText + response.dataSegment)
            guard let address = text["TargetAddress"] else {
                throw NegotiationError.protocolViolation("redirect without TargetAddress")
            }
            stage = .done
            return .redirect(address: address, permanent: response.statusDetail == 2)
        }
        // A success response must be an answer to the request we sent: it
        // echoes our ISID and ITT, operates at protocol version 0x00
        // (§11.13.1), and belongs to the stage we are negotiating (§11.12.3).
        if response.isSuccess {
            guard response.isid.bytes == config.isid.bytes else {
                throw NegotiationError.protocolViolation("login response ISID does not echo ours")
            }
            guard response.initiatorTaskTag == 0 else {
                throw NegotiationError.protocolViolation(
                    "login response ITT \(response.initiatorTaskTag), expected 0")
            }
            guard response.versionActive == 0 else {
                throw NegotiationError.protocolViolation(
                    "target active version \(response.versionActive), only 0x00 exists")
            }
            guard response.currentStage == lastCSG else {
                throw NegotiationError.protocolViolation(
                    "login response CSG \(response.currentStage) for a request in \(lastCSG)")
            }
        }

        guard response.isSuccess else {
            // The stage is half the diagnosis. A rejection while awaiting the
            // CHAP *result* means the target took our response and refused it;
            // the same code while awaiting the *challenge* means it refused us
            // before any secret was involved.
            note("target rejected the login while \(stageName): "
                 + Self.describe(statusClass: response.statusClass,
                                 statusDetail: response.statusDetail))
            throw NegotiationError.loginFailed(
                statusClass: response.statusClass,
                statusDetail: response.statusDetail
            )
        }

        // StatSN tracking: adopt the target's StatSN on the first response.
        if !seenFirstResponse {
            seenFirstResponse = true
            expStatSN = response.statSN &+ 1
        } else if response.statSN == expStatSN {
            expStatSN &+= 1
        } else if !response.dataSegment.isEmpty || response.transit {
            // Login responses advance StatSN; a mismatch is a protocol error.
            throw NegotiationError.protocolViolation(
                "login StatSN \(response.statSN), expected \(expStatSN)"
            )
        }
        if response.tsih != 0 { tsih = response.tsih }

        // Outgoing continuation takes precedence: if we still have text queued,
        // the target's (empty) response just acks our chunk.
        if !outgoingRemainder.isEmpty {
            let chunk = outgoingRemainder
            let flags = pendingFlags
            return .send(emit(
                text: chunk,
                currentStage: response.currentStage,
                transit: flags.transit,
                nsg: flags.nsg
            ))
        }

        // Incoming continuation: buffer and ask for the rest.
        //
        // Bounded, because this runs *before* authentication and the peer picks
        // when it stops. `loginTextLimit` was already the right number — RFC 7143
        // §6.3 caps login-phase text until MRDSL is negotiated — but it was only
        // ever applied to what we send (`emit`, below). A target that sets the C
        // bit and never clears it grew this buffer until the daemon died, and
        // the daemon is root and holds every other volume on the machine.
        incomingText.append(response.dataSegment)
        guard incomingText.count <= Self.loginTextLimit else {
            throw NegotiationError.protocolViolation(
                "login text exceeded \(Self.loginTextLimit) bytes "
                + "(\(incomingText.count) buffered); target is not terminating the sequence")
        }
        if response.continued {
            var pdu = baseRequest()
            pdu.currentStage = response.currentStage
            lastCSG = response.currentStage
            pdu.transit = false
            pdu.nextStage = .securityNegotiation // NSG reserved when T=0
            return .send(pdu)
        }
        let text = try TextParameters.decode(incomingText)
        incomingText = Data()

        switch stage {
        case .awaitingAuthMethod:
            guard text["AuthMethod"] == "CHAP" else {
                note("target answered AuthMethod=\(text["AuthMethod"] ?? "<missing>"), "
                     + "which is not CHAP — nothing to authenticate with")
                throw NegotiationError.authenticationFailed(
                    "target answered AuthMethod=\(text["AuthMethod"] ?? "<missing>")"
                )
            }
            note("target selected AuthMethod=CHAP; proposing CHAP_A=5 (MD5)")
            stage = .awaitingChapChallenge
            let proposal = chapExchange!.algorithmProposal()
            return .send(emit(
                text: proposal.encode(),
                currentStage: .securityNegotiation,
                transit: false,
                nsg: .securityNegotiation
            ))

        case .awaitingChapChallenge:
            note("target challenged: CHAP_A=\(text["CHAP_A"] ?? "<absent>") "
                 + "CHAP_I=\(text["CHAP_I"] ?? "<absent>") CHAP_C=\(Self.shape(text["CHAP_C"]))")
            let reply = try chapExchange!.respond(to: text)
            if reply["CHAP_I"] != nil {
                note("answering as “\(config.chap?.name ?? "?")” and challenging the target back "
                     + "(CHAP_I=\(reply["CHAP_I"] ?? "?") CHAP_C=\(Self.shape(reply["CHAP_C"])))")
            } else {
                note("answering as “\(config.chap?.name ?? "?")”, one-way — not challenging the target")
            }
            stage = .awaitingChapResult
            return .send(emit(
                text: reply.encode(),
                currentStage: .securityNegotiation,
                transit: true,
                nsg: .loginOperationalNegotiation
            ))

        case .awaitingChapResult:
            if config.chap?.wantsMutual == true {
                note("target's answer to our challenge: CHAP_N=\(text["CHAP_N"] ?? "<absent>") "
                     + "CHAP_R=\(Self.shape(text["CHAP_R"]))")
            }
            try chapExchange!.verifyMutual(text)
            if config.chap?.wantsMutual == true {
                note("mutual CHAP verified — the target proved it knows the peer secret")
            } else {
                note("target accepted our credentials")
            }
            guard response.transit else {
                // Target wants more security negotiation we don't support.
                throw NegotiationError.authenticationFailed("target did not complete security stage")
            }
            stage = .operational
            let proposal = engine.proposeOperational(
                desired: config.desired,
                sessionType: config.sessionType
            )
            return .send(emit(
                text: proposal.encode(),
                currentStage: .loginOperationalNegotiation,
                transit: true,
                nsg: .fullFeaturePhase
            ))

        case .operational:
            // For the None-auth path the first response is the security-stage
            // transit; detect it and send our operational proposal.
            if response.currentStage == .securityNegotiation {
                guard response.transit else {
                    throw NegotiationError.authenticationFailed("target held us in security stage")
                }
                if let method = text["AuthMethod"], method != "None" {
                    throw NegotiationError.authenticationFailed("target requires AuthMethod=\(method)")
                }
                let proposal = engine.proposeOperational(
                    desired: config.desired,
                    sessionType: config.sessionType
                )
                return .send(emit(
                    text: proposal.encode(),
                    currentStage: .loginOperationalNegotiation,
                    transit: true,
                    nsg: .fullFeaturePhase
                ))
            }

            let replies = try engine.process(text)
            if response.transit && response.nextStage == .fullFeaturePhase {
                guard replies.isEmpty else {
                    throw NegotiationError.protocolViolation(
                        "target offered new keys on its transit response"
                    )
                }
                stage = .done
                let params = try engine.finalParameters(desired: config.desired)
                if config.sessionType == .normal && tsih == 0 {
                    throw NegotiationError.protocolViolation("target assigned TSIH 0")
                }
                return .success(LoginResult(
                    parameters: params,
                    tsih: tsih,
                    expStatSN: expStatSN,
                    expCmdSN: response.expCmdSN,
                    maxCmdSN: response.maxCmdSN
                ))
            }
            // Target is still negotiating: answer its offers (or nudge with
            // an empty request) and re-request transit.
            return .send(emit(
                text: replies.encode(),
                currentStage: .loginOperationalNegotiation,
                transit: true,
                nsg: .fullFeaturePhase
            ))

        case .done:
            fatalError("unreachable")
        }
    }
}
