#if canImport(Network)
import Network
import Testing
@testable import iSCSIKit

/// The TCP options are set where Network.framework reads them. Until
/// 2026-10-05 they were set on a cast of the *IP* options that always failed,
/// so every connection ran with Nagle on and TCP keepalive off.
@Suite("Network transport parameters")
struct NetworkTransportParametersTests {

    private func tcpOptions() throws -> NWProtocolTCP.Options {
        let params = NetworkTransport.connectionParameters()
        return try #require(params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    }

    @Test("Nagle is off: a PDU header is sent without waiting for the previous ACK")
    func noDelay() throws {
        #expect(try tcpOptions().noDelay)
    }

    @Test("TCP keepalive is on, probing after 30 s idle")
    func keepalive() throws {
        let tcp = try tcpOptions()
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 30)
    }
}
#endif
