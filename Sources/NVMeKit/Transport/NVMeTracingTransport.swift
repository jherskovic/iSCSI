import Foundation
import iSCSIKit

/// Wraps a transport and prints a one-line summary of every NVMe/TCP PDU in
/// each direction — the `TracingTransport` twin. Unlike iSCSI's, this one
/// knows the negotiated digests: it watches the ICResp go by and rebuilds
/// its deframers to match, so the trace stays readable after initialization.
public final class NVMeTracingTransport: ConnectionTransport, @unchecked Sendable {
    private let inner: any ConnectionTransport
    private let label: String
    private let sink: @Sendable (String) -> Void
    private let discovery: Bool
    private let includeWire: Bool
    // Accessed under the trace lock, scoped to this connection.
    private var requests: [UInt16: SQE] = [:]
    private let lock = NSLock()
    private var txFramer = NVMeTCPDeframer(maxPDUBytes: 4 << 20)
    private var rxFramer = NVMeTCPDeframer(maxPDUBytes: 4 << 20)

    public init(
        _ inner: any ConnectionTransport,
        label: String = "nvme",
        discovery: Bool = false,
        includeWire: Bool = false,
        sink: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.discovery = discovery
        self.includeWire = includeWire
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
            let line = summary(raw, discovery: discovery)
            lines.append(line)
            if discovery && includeWire {
                let wire = summary(raw, discovery: false)
                if wire != line { lines.append(wire) }
            }
            if raw.pduType == .icResp, let icresp = try? ICRespPDU(raw: raw) {
                // From here on both directions carry the negotiated digests.
                txFramer = NVMeTCPDeframer(digests: icresp.digests, maxPDUBytes: 4 << 20)
                rxFramer = NVMeTCPDeframer(digests: icresp.digests, maxPDUBytes: 4 << 20)
            }
        }
        lock.unlock()
        for line in lines {
            sink("[\(label)] \(direction) \(line)")
        }
    }

    private func summary(_ raw: RawNVMeTCPPDU, discovery: Bool) -> String {
        guard let pdu = try? AnyNVMeTCPPDU.decode(raw) else {
            return String(format: "type=0x%02x psh=%dB data=%dB", raw.type, raw.psh.count, raw.data.count)
        }
        switch pdu {
        case .icReq(let p):
            return "ICReq pfv=\(p.pfv) hpda=\(p.hpda) digests=\(digestLabel(p.digests)) maxr2t=\(p.maxR2T)"
        case .icResp(let p):
            return "ICResp pfv=\(p.pfv) cpda=\(p.cpda) digests=\(digestLabel(p.digests)) maxh2cdata=\(p.maxH2CData)"
        case .capsuleCmd(let p):
            guard let sqe = try? SQE(bytes: p.sqe) else { return "CapsuleCmd (bad SQE)" }
            if discovery {
                requests[sqe.commandID] = sqe
                return "cid=\(sqe.commandID) \(discoveryOperation(sqe))"
            }
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
            if discovery, let sqe = requests.removeValue(forKey: cqe.commandID) {
                var line = "cid=\(cqe.commandID) \(discoveryOperation(sqe))"
                guard cqe.status.isSuccess else { return line + " failed: " + cqe.status.description }
                line += " ok"
                if sqe.opcode == NVMeOpcode.Admin.fabrics {
                    switch (sqe.fabricsType, sqe.cdw11) {
                    case (FabricsCommandType.connect, _):
                        line += " controllerID=\(cqe.dw0 & 0xffff)"
                    case (FabricsCommandType.propertyGet, NVMeProperty.csts):
                        let status = ControllerStatus(raw: cqe.dw0)
                        line += " ready=\(status.ready) fatal=\(status.fatal)"
                    case (FabricsCommandType.propertyGet, NVMeProperty.cap):
                        line += " supportsNVM=\(ControllerCapabilities(raw: cqe.result64).supportsNVMCommandSet)"
                    default: break
                    }
                }
                return line
            }
            return String(format: "CapsuleResp cid=%d status=%@ dw0=0x%08x", cqe.commandID,
                          cqe.status.isSuccess ? "ok" : cqe.status.description, cqe.dw0)
        case .c2hData(let p):
            if discovery, let sqe = requests[p.cccid] {
                if p.success { requests.removeValue(forKey: p.cccid) }
                return "cid=\(p.cccid) \(discoveryOperation(sqe)) dataOffset=\(p.dataOffset) received=\(p.data.count)B"
                    + (p.last ? " LAST" : "") + (p.success ? " SUCCESS" : "")
            }
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

    private func discoveryOperation(_ sqe: SQE) -> String {
        if sqe.opcode == NVMeOpcode.Admin.getLogPage, UInt8(truncatingIfNeeded: sqe.cdw10) == NVMeLogPage.discovery {
            let offset = UInt64(sqe.cdw13) << 32 | UInt64(sqe.cdw12)
            let section = offset == 0 ? "header" : "entries"
            return "Get Discovery Log \(section) logOffset=\(offset) length=\(sqe.sgl.length)B"
        }
        guard sqe.opcode == NVMeOpcode.Admin.fabrics else {
            return String(format: "Admin command op=0x%02x", sqe.opcode)
        }
        switch (sqe.fabricsType, sqe.cdw11) {
        case (FabricsCommandType.connect, _): return "Connect discovery controller"
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
