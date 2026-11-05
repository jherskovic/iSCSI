import Foundation
import iSCSIKit

/// Describes queue operations and their outcomes. Debug tracing also reports the
/// wire fields, including the controller's original status on locally failed reads.
public final class NVMeTracingTransport: ConnectionTransport, @unchecked Sendable {
    private let inner: any ConnectionTransport
    private let label: String
    private let sink: @Sendable (String) -> Void
    public enum Level: Sendable { case useful, debug }
    private let level: Level
    private var queueID: UInt16 = 0
    private var lastControllerStatus: UInt32?
    private var badDigests: Set<UInt16> = []
    // Accessed under the trace lock, scoped to this connection.
    private var requests: [UInt16: SQE] = [:]
    private let lock = NSLock()
    private var txFramer = NVMeTCPDeframer(maxPDUBytes: 4 << 20)
    private var rxFramer = NVMeTCPDeframer(maxPDUBytes: 4 << 20)

    public init(
        _ inner: any ConnectionTransport,
        label: String = "nvme",
        level: Level = .debug,
        sink: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.level = level
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

    private func trace(direction: String, data: Data,
                       framer keyPath: ReferenceWritableKeyPath<NVMeTracingTransport, NVMeTCPDeframer>) {
        lock.lock()
        self[keyPath: keyPath].append(data)
        var lines: [String] = []
        while let raw = try? self[keyPath: keyPath].next() {
            guard let pdu = try? AnyNVMeTCPPDU.decode(raw) else {
                lines.append(String(format: "Undecodable PDU type=0x%02x", raw.type))
                continue
            }
            let line = summary(pdu, dataDigestFailed: raw.dataDigestFailed)
            if let line { lines.append(line) }
            if level == .debug {
                let wire = wireDescription(pdu)
                if wire != line { lines.append(wire) }
            }
            if case .icResp(let icresp) = pdu {
                // From here on both directions carry the negotiated digests.
                txFramer.digests = icresp.digests
                rxFramer.digests = icresp.digests
            }
        }
        lock.unlock()
        for line in lines {
            sink("[\(label)] \(direction) \(line)")
        }
    }

    private func wireDescription(_ pdu: AnyNVMeTCPPDU) -> String {
        switch pdu {
        case .icReq(let p):
            return "ICReq pfv=\(p.pfv) hpda=\(p.hpda) digests=\(digestLabel(p.digests)) maxr2t=\(p.maxR2T)"
        case .icResp(let p):
            return "ICResp pfv=\(p.pfv) cpda=\(p.cpda) digests=\(digestLabel(p.digests)) maxh2cdata=\(p.maxH2CData)"
        case .capsuleCmd(let p):
            guard let sqe = try? SQE(bytes: p.sqe) else { return "CapsuleCmd (bad SQE)" }
            var parts = [String(format: "CapsuleCmd op=0x%02x cid=%d", sqe.opcode, sqe.commandID)]
            if sqe.opcode == NVMeOpcode.Admin.fabrics {
                parts.append(String(format: "fctype=0x%02x", sqe.fabricsType))
            } else {
                parts.append("nsid=\(sqe.nsid)")
            }
            parts.append(String(format: "cdw10=0x%08x", sqe.cdw10))
            parts.append("sgl=\(sqe.sgl.isInCapsule ? "icd" : "transport")/\(sqe.sgl.length)B")
            if !p.inCapsuleData.isEmpty { parts.append("icd=\(p.inCapsuleData.count)B") }
            return parts.joined(separator: " ")
        case .capsuleResp(let p):
            guard let cqe = try? CQE(bytes: p.cqe) else { return "CapsuleResp (bad CQE)" }
            return String(format: "CapsuleResp cid=%d status=%@ dw0=0x%08x", cqe.commandID,
                          cqe.status.isSuccess ? "ok" : cqe.status.description, cqe.dw0)
        case .c2hData(let p):
            return "C2HData cid=\(p.cccid) off=\(p.dataOffset) len=\(p.data.count)"
                + (p.last ? " LAST" : "") + (p.success ? " SUCCESS" : "")
        case .h2cData(let p):
            return "H2CData cid=\(p.cccid) ttag=\(p.ttag) off=\(p.dataOffset) len=\(p.data.count)"
                + (p.last ? " LAST" : "")
        case .r2t(let p):
            return "R2T cid=\(p.cccid) ttag=\(p.ttag) off=\(p.offset) len=\(p.length)"
        case .h2cTermReq(let p):
            return String(format: "H2CTermReq fes=0x%04x fei=0x%08x", p.fes.rawValue, p.fei)
        case .c2hTermReq(let p):
            return String(format: "C2HTermReq fes=0x%04x fei=0x%08x", p.fes.rawValue, p.fei)
        }
    }

    private func summary(_ pdu: AnyNVMeTCPPDU, dataDigestFailed: Bool) -> String? {
        switch pdu {
        case .icReq:
            return "Negotiating NVMe/TCP connection"
        case .icResp(let response):
            return "NVMe/TCP negotiated digests=\(digestLabel(response.digests))"
        case .capsuleCmd(let capsule):
            guard let sqe = try? SQE(bytes: capsule.sqe) else { return "Invalid command capsule" }
            requests[sqe.commandID] = sqe
            if sqe.opcode == NVMeOpcode.Admin.fabrics, sqe.fabricsType == FabricsCommandType.connect {
                queueID = UInt16(sqe.cdw10 >> 16)
            }
            if isStatusPoll(sqe) { return nil } // Report status changes on the response.
            return "cid=\(sqe.commandID) \(operation(sqe))"
        case .capsuleResp(let response):
            guard let cqe = try? CQE(bytes: response.cqe) else { return "Invalid completion capsule" }
            return completion(cqe)
        case .c2hData(let data):
            if dataDigestFailed { badDigests.insert(data.cccid) }
            if data.success { return completion(CQE(commandID: data.cccid)) }
            if dataDigestFailed { return "cid=\(data.cccid) data digest mismatch" }
            return nil
        case .r2t, .h2cData:
            return nil
        case .h2cTermReq, .c2hTermReq:
            return wireDescription(pdu)
        }
    }

    private func isStatusPoll(_ sqe: SQE) -> Bool {
        sqe.opcode == NVMeOpcode.Admin.fabrics && sqe.fabricsType == FabricsCommandType.propertyGet
            && sqe.cdw11 == NVMeProperty.csts
    }

    private func completion(_ cqe: CQE) -> String? {
        let badDigest = badDigests.remove(cqe.commandID) != nil
        guard let sqe = requests.removeValue(forKey: cqe.commandID) else {
            return "Unexpected completion cid=\(cqe.commandID)"
        }
        let prefix = "cid=\(cqe.commandID) \(operation(sqe))"
        if !cqe.status.isSuccess {
            let error = BlockDeviceError.nvmeStatus(sct: cqe.status.sct, sc: cqe.status.sc, opcode: sqe.opcode)
            return prefix + " failed: " + ISCSIError.nsError(from: error).localizedDescription
        }
        if badDigest { return prefix + " failed: data digest mismatch" }
        guard sqe.opcode == NVMeOpcode.Admin.fabrics else { return prefix + " ok" }
        switch (sqe.fabricsType, sqe.cdw11) {
        case (FabricsCommandType.connect, _):
            if cqe.dw0 >> 16 != 0 { return prefix + " failed: in-band authentication required" }
            return prefix + " ok controllerID=\(cqe.dw0 & 0xffff)"
        case (FabricsCommandType.propertyGet, NVMeProperty.cap):
            return prefix + " supportsNVM=\(ControllerCapabilities(raw: cqe.result64).supportsNVMCommandSet)"
        case (FabricsCommandType.propertyGet, NVMeProperty.csts):
            guard lastControllerStatus != cqe.dw0 else { return nil }
            lastControllerStatus = cqe.dw0
            let status = ControllerStatus(raw: cqe.dw0)
            return prefix + " ready=\(status.ready) fatal=\(status.fatal)"
        default:
            return prefix + " ok"
        }
    }

    private func operation(_ sqe: SQE) -> String {
        if queueID != 0 && sqe.opcode != NVMeOpcode.Admin.fabrics {
            let name: String
            switch sqe.opcode {
            case NVMeOpcode.NVM.read: name = "Read"
            case NVMeOpcode.NVM.write: name = "Write"
            case NVMeOpcode.NVM.flush: name = "Flush"
            default: name = String(format: "I/O op=0x%02x", sqe.opcode)
            }
            return "\(name) nsid=\(sqe.nsid)"
        }
        if sqe.opcode == NVMeOpcode.Admin.getLogPage, UInt8(truncatingIfNeeded: sqe.cdw10) == NVMeLogPage.discovery {
            let offset = UInt64(sqe.cdw13) << 32 | UInt64(sqe.cdw12)
            let section = offset == 0 ? "header" : "entries"
            return "Get Discovery Log \(section) logOffset=\(offset) length=\(sqe.sgl.length)B"
        }
        guard sqe.opcode == NVMeOpcode.Admin.fabrics else {
            switch sqe.opcode {
            case NVMeOpcode.Admin.identify: return "Identify nsid=\(sqe.nsid) cns=\(sqe.cdw10 & 0xff)"
            case NVMeOpcode.Admin.setFeatures: return "Set Features"
            case NVMeOpcode.Admin.getFeatures: return "Get Features"
            case NVMeOpcode.Admin.keepAlive: return "Keep Alive"
            default: break
            }
            return String(format: "Admin command op=0x%02x", sqe.opcode)
        }
        switch (sqe.fabricsType, sqe.cdw11) {
        case (FabricsCommandType.connect, _): return "Connect queue=\(queueID)"
        case (FabricsCommandType.propertyGet, NVMeProperty.cap): return "Property Get CAP"
        case (FabricsCommandType.propertySet, NVMeProperty.cc): return "Property Set CC enable=\(sqe.cdw12 & 1)"
        case (FabricsCommandType.propertyGet, NVMeProperty.csts): return "Property Get CSTS"
        default: return String(format: "Fabrics command fctype=0x%02x", sqe.fabricsType)
        }
    }

    private func digestLabel(_ d: NVMeTCPDigests) -> String {
        switch (d.header, d.data) {
        case (true, true): return "hdr+data"
        case (true, false): return "hdr"
        case (false, true): return "data"
        case (false, false): return "none"
        }
    }
}
