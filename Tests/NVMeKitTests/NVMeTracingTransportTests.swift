import Foundation
import Synchronization
import Testing
import iSCSIKit
@testable import NVMeKit

private final class TraceLines: Sendable {
    let values = Mutex<[String]>([])
}

private final class TraceSession {
    let lines = TraceLines()
    let trace: NVMeTracingTransport
    let peer: MemoryPipe
    var serializer = NVMeTCPSerializer()

    init(_ level: NVMeTracingTransport.Level = .useful) {
        let (client, server) = MemoryPipe.pair()
        peer = server
        trace = NVMeTracingTransport(client, level: level) { [lines] line in
            lines.values.withLock { $0.append(line) }
        }
    }

    func send(_ sqe: SQE) async throws {
        try await trace.send(serializer.serialize(CapsuleCmdPDU(sqe: sqe.bytes).encode()))
    }

    func receive(_ pdu: AnyNVMeTCPPDU) async throws {
        let bytes = serializer.serialize(pdu.encode())
        try await peer.send(bytes)
        _ = try await trace.receive()
    }

    func respond(_ cid: UInt16, dw0: UInt32 = 0, status: NVMeStatus = .success) async throws {
        let cqe = CQE(dw0: dw0, commandID: cid, status: status)
        try await receive(.capsuleResp(CapsuleRespPDU(cqe: cqe.encoded)))
    }

    func matching(_ text: String) -> [String] {
        lines.values.withLock { $0.filter { $0.contains(text) } }
    }
}

@Suite struct NVMeTracingTransportTests {
    private func logRead(_ cid: UInt16, offset: UInt64 = 0) -> SQE {
        NVMeCommands.getLogPage(commandID: cid, logID: NVMeLogPage.discovery, offset: offset, length: 4)
    }

    @Test func correlatesOutOfOrderResponsesAndDecodes64BitOffset() async throws {
        let session = TraceSession()
        try await session.send(logRead(1))
        try await session.send(logRead(2, offset: 0x1_0000_0400))
        try await session.receive(.c2hData(C2HDataPDU(cccid: 2, dataOffset: 0, data: Data(count: 4),
                                                      last: true, success: true)))
        try await session.receive(.c2hData(C2HDataPDU(cccid: 1, dataOffset: 0, data: Data(count: 4),
                                                      last: true, success: false)))
        try await session.respond(1)
        #expect(session.matching("← cid=2 Get Discovery Log entries logOffset=4294968320 length=4B ok").count == 1)
        #expect(session.matching("← cid=1 Get Discovery Log header logOffset=0 length=4B ok").count == 1)
    }

    @Test func levelsShowStatusChangesAndDebugAddsWireDetailsOnce() async throws {
        for level in [NVMeTracingTransport.Level.useful, .debug] {
            let session = TraceSession(level)
            try await session.receive(.icResp(ICRespPDU()))
            for value: UInt32 in [0, 0, 1] {
                try await session.send(NVMeCommands.propertyGet(commandID: 5, offset: NVMeProperty.csts, wide: false))
                try await session.respond(5, dw0: value)
            }
            try await session.receive(.c2hTermReq(C2HTermReqPDU(fes: .pduSequenceError)))
            #expect(session.matching("NVMe/TCP negotiated").count == 1)
            #expect(session.matching("ready=false").count == 1)
            #expect(session.matching("ready=true").count == 1)
            #expect(session.matching("C2HTermReq").count == 1)
            #expect(session.matching("ICResp pfv=").count == (level == .debug ? 1 : 0))
            #expect(session.matching("CapsuleResp").count == (level == .debug ? 3 : 0))
        }
    }
}
