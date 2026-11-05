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

    func receive(_ pdu: AnyNVMeTCPPDU, corruptDigest: Bool = false) async throws {
        var bytes = serializer.serialize(pdu.encode())
        if corruptDigest { bytes[bytes.count - 1] ^= 1 }
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

    private func connectIOQueue() -> SQE {
        NVMeCommands.connect(commandID: 1, queueID: 1, queueEntries: 32, keepAliveMS: 0,
                             hostID: Data(count: 16), controllerID: 1,
                             subsystemNQN: "nqn.test:disk", hostNQN: "nqn.test").sqe
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

    @Test(arguments: [true, false]) func digestFailureSurvivesCompletion(inline: Bool) async throws {
        let session = TraceSession()
        let digests = NVMeTCPDigests(header: false, data: true)
        try await session.receive(.icResp(ICRespPDU(digests: digests)))
        session.serializer = NVMeTCPSerializer(digests: digests)
        try await session.send(logRead(3))
        try await session.receive(.c2hData(C2HDataPDU(cccid: 3, dataOffset: 0, data: Data(count: 4),
                                                      last: true, success: inline)), corruptDigest: true)
        if !inline { try await session.respond(3) }
        #expect(session.matching("failed: data digest mismatch").count == 1)
        #expect(session.matching(" ok").isEmpty)
        // Reusing the CID must not inherit the earlier failure.
        try await session.send(logRead(3))
        try await session.receive(.c2hData(C2HDataPDU(cccid: 3, dataOffset: 0, data: Data(count: 4),
                                                      last: true, success: true)))
        #expect(session.matching("length=4B ok").count == 1)
    }

    @Test func connectExplainsAuthenticationAndRejection() async throws {
        let session = TraceSession()
        let (sqe, _) = NVMeCommands.connect(commandID: 4, queueID: 0, queueEntries: 32, keepAliveMS: 0,
                                            hostID: Data(count: 16), controllerID: 0xffff,
                                            subsystemNQN: NQN.discovery, hostNQN: "nqn.test")
        try await session.send(sqe)
        try await session.respond(4, dw0: 0x10001)
        try await session.send(sqe)
        try await session.respond(4, status: NVMeStatus(sct: 1, sc: 0x84))
        #expect(session.matching("authentication required").count == 1)
        #expect(session.matching("refused this Mac's host NQN").count == 1)
        #expect(session.matching(" ok").isEmpty)
    }

    @Test func aShortReadIsNotReportedAsSuccess() async throws {
        let session = TraceSession()
        try await session.send(logRead(6))
        try await session.receive(.c2hData(C2HDataPDU(cccid: 6, dataOffset: 0, data: Data(count: 2),
                                                      last: true, success: true)))
        #expect(session.matching("failed: 2 of 4 bytes delivered").count == 1)
        #expect(session.matching(" ok").isEmpty)
        // Data split over several PDUs adds up, and the CID starts again from zero.
        try await session.send(logRead(6))
        for offset: UInt32 in [0, 2] {
            try await session.receive(.c2hData(C2HDataPDU(cccid: 6, dataOffset: offset, data: Data(count: 2),
                                                          last: offset == 2, success: offset == 2)))
        }
        #expect(session.matching("length=4B ok").count == 1)
    }

    @Test func aWriteDeliversNothingAndIsStillOk() async throws {
        let session = TraceSession()
        try await session.send(connectIOQueue())
        try await session.respond(1)
        let write = NVMeCommands.write(commandID: 2, nsid: 1, slba: 0, blocks: 1, blockSize: 4096, fua: false,
                                       inCapsule: false)
        try await session.send(write)
        try await session.respond(2)
        #expect(session.matching("Write nsid=1 ok").count == 1)
    }

    @Test func anIOQueueNamesItsCommands() async throws {
        let session = TraceSession()
        try await session.send(connectIOQueue())
        try await session.respond(1)
        #expect(session.matching("Connect queue=1").count == 2)
        // Read is 0x02, the same opcode as Get Log Page on the admin queue.
        try await session.send(NVMeCommands.read(commandID: 2, nsid: 1, slba: 0, blocks: 1, blockSize: 4096))
        try await session.send(NVMeCommands.flush(commandID: 3, nsid: 1))
        #expect(session.matching("→ cid=2 Read nsid=1").count == 1)
        #expect(session.matching("→ cid=3 Flush nsid=1").count == 1)
        #expect(session.matching("Discovery").isEmpty)
    }

    @Test func aShutdownSaysSoAndSoDoesItsCompletion() async throws {
        let session = TraceSession()
        let enable = NVMeCommands.controllerConfigurationEnable
        try await session.send(NVMeCommands.propertySet(commandID: 7, offset: NVMeProperty.cc, value: enable))
        try await session.respond(7)
        #expect(session.matching("shutdown=normal").isEmpty)
        try await session.send(NVMeCommands.propertySet(commandID: 8, offset: NVMeProperty.cc,
                                                        value: enable | NVMeCommands.shutdownNormal))
        try await session.respond(8)
        #expect(session.matching("enable=1 shutdown=normal").count == 2)
        try await session.send(NVMeCommands.propertyGet(commandID: 9, offset: NVMeProperty.csts, wide: false))
        try await session.respond(9, dw0: 0x9) // RDY, and SHST 10b: shutdown complete.
        #expect(session.matching("ready=true fatal=false shutdownComplete=true").count == 1)
    }

    @Test func aStatusPollIsNotLoggedWhenSent() async throws {
        let session = TraceSession()
        try await session.send(NVMeCommands.propertyGet(commandID: 5, offset: NVMeProperty.csts, wide: false))
        #expect(session.matching("→").isEmpty)
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
