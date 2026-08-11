import Foundation

/// Everything needed to log a new connection into a target.
public struct LoginConfig: Sendable {
    public var initiatorName: String
    public var sessionType: SessionType
    /// Required for normal sessions; ignored for discovery.
    public var targetName: String?
    /// nil → offer AuthMethod=None only.
    public var chap: CHAP.Credentials?
    public var desired = DesiredParameters()
    public var isid: ISID
    public var tsih: UInt16 = 0
    public var cid: UInt16 = 0

    public init(
        initiatorName: String,
        sessionType: SessionType,
        targetName: String? = nil,
        chap: CHAP.Credentials? = nil,
        isid: ISID = .random()
    ) {
        self.initiatorName = initiatorName
        self.sessionType = sessionType
        self.targetName = targetName
        self.chap = chap
        self.isid = isid
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
        if text.count > Self.loginTextLimit {
            outgoingRemainder = text.dropFirst(Self.loginTextLimit)
            pendingFlags = (transit, nsg)
            pdu.continued = true
            pdu.transit = false
            pdu.nextStage = currentStage
            pdu.dataSegment = text.prefix(Self.loginTextLimit)
        } else {
            outgoingRemainder = Data()
            pdu.transit = transit
            pdu.nextStage = transit ? nsg : currentStage
            pdu.dataSegment = text
        }
        return pdu
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
            params.append("AuthMethod", "CHAP")
            return emit(
                text: params.encode(),
                currentStage: .securityNegotiation,
                transit: false,
                nsg: .securityNegotiation
            )
        } else {
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
        guard response.isSuccess else {
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
        incomingText.append(response.dataSegment)
        if response.continued {
            var pdu = baseRequest()
            pdu.currentStage = response.currentStage
            pdu.transit = false
            pdu.nextStage = response.currentStage
            return .send(pdu)
        }
        let text = try TextParameters.decode(incomingText)
        incomingText = Data()

        switch stage {
        case .awaitingAuthMethod:
            guard text["AuthMethod"] == "CHAP" else {
                throw NegotiationError.authenticationFailed(
                    "target answered AuthMethod=\(text["AuthMethod"] ?? "<missing>")"
                )
            }
            stage = .awaitingChapChallenge
            let proposal = chapExchange!.algorithmProposal()
            return .send(emit(
                text: proposal.encode(),
                currentStage: .securityNegotiation,
                transit: false,
                nsg: .securityNegotiation
            ))

        case .awaitingChapChallenge:
            let reply = try chapExchange!.respond(to: text)
            stage = .awaitingChapResult
            return .send(emit(
                text: reply.encode(),
                currentStage: .securityNegotiation,
                transit: true,
                nsg: .loginOperationalNegotiation
            ))

        case .awaitingChapResult:
            try chapExchange!.verifyMutual(text)
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
