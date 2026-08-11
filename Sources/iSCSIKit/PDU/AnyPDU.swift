import Foundation

/// Opcode-dispatched decode of a framed PDU.
public enum AnyPDU: Sendable, Equatable {
    case nopOut(NopOutPDU)
    case scsiCommand(SCSICommandPDU)
    case tmfRequest(TMFRequestPDU)
    case loginRequest(LoginRequestPDU)
    case textRequest(TextRequestPDU)
    case scsiDataOut(DataOutPDU)
    case logoutRequest(LogoutRequestPDU)

    case nopIn(NopInPDU)
    case scsiResponse(SCSIResponsePDU)
    case tmfResponse(TMFResponsePDU)
    case loginResponse(LoginResponsePDU)
    case textResponse(TextResponsePDU)
    case scsiDataIn(DataInPDU)
    case logoutResponse(LogoutResponsePDU)
    case r2t(R2TPDU)
    case asyncMessage(AsyncMessagePDU)
    case reject(RejectPDU)

    public static func decode(_ raw: RawPDU) throws -> AnyPDU {
        guard let opcode = raw.opcode else {
            throw PDUError.unknownOpcode(raw.opcodeByte)
        }
        switch opcode {
        case .nopOut: return .nopOut(try NopOutPDU(raw: raw))
        case .scsiCommand: return .scsiCommand(try SCSICommandPDU(raw: raw))
        case .tmfRequest: return .tmfRequest(try TMFRequestPDU(raw: raw))
        case .loginRequest: return .loginRequest(try LoginRequestPDU(raw: raw))
        case .textRequest: return .textRequest(try TextRequestPDU(raw: raw))
        case .scsiDataOut: return .scsiDataOut(try DataOutPDU(raw: raw))
        case .logoutRequest: return .logoutRequest(try LogoutRequestPDU(raw: raw))
        case .nopIn: return .nopIn(try NopInPDU(raw: raw))
        case .scsiResponse: return .scsiResponse(try SCSIResponsePDU(raw: raw))
        case .tmfResponse: return .tmfResponse(try TMFResponsePDU(raw: raw))
        case .loginResponse: return .loginResponse(try LoginResponsePDU(raw: raw))
        case .textResponse: return .textResponse(try TextResponsePDU(raw: raw))
        case .scsiDataIn: return .scsiDataIn(try DataInPDU(raw: raw))
        case .logoutResponse: return .logoutResponse(try LogoutResponsePDU(raw: raw))
        case .r2t: return .r2t(try R2TPDU(raw: raw))
        case .asyncMessage: return .asyncMessage(try AsyncMessagePDU(raw: raw))
        case .reject: return .reject(try RejectPDU(raw: raw))
        case .snackRequest:
            throw PDUError.malformed("SNACK not supported (ERL0)")
        }
    }

    public func encode() -> RawPDU {
        switch self {
        case .nopOut(let p): return p.encode()
        case .scsiCommand(let p): return p.encode()
        case .tmfRequest(let p): return p.encode()
        case .loginRequest(let p): return p.encode()
        case .textRequest(let p): return p.encode()
        case .scsiDataOut(let p): return p.encode()
        case .logoutRequest(let p): return p.encode()
        case .nopIn(let p): return p.encode()
        case .scsiResponse(let p): return p.encode()
        case .tmfResponse(let p): return p.encode()
        case .loginResponse(let p): return p.encode()
        case .textResponse(let p): return p.encode()
        case .scsiDataIn(let p): return p.encode()
        case .logoutResponse(let p): return p.encode()
        case .r2t(let p): return p.encode()
        case .asyncMessage(let p): return p.encode()
        case .reject(let p): return p.encode()
        }
    }
}
