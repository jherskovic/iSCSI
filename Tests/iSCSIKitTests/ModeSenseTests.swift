import Foundation
import Testing
@testable import iSCSIKit

@Suite("MODE SENSE parsing")
struct ModeSenseTests {
    /// header(8) + optional block descriptors + pages
    private func response(blockDescLen: Int, pages: [UInt8]) -> Data {
        var d = Data(count: 8)
        d.setBE16(UInt16(blockDescLen), 6)
        d.append(Data(count: blockDescLen))
        d.append(contentsOf: pages)
        return d
    }

    @Test func readsWCESet() {
        // page 0x08, len 18, byte2 bit2 set
        let d = response(blockDescLen: 0, pages: [0x08, 18, 0x04] + [UInt8](repeating: 0, count: 16))
        #expect(ModeSense.writeCacheEnabled(inResponse: d) == true)
    }

    @Test func readsWCEClear() {
        let d = response(blockDescLen: 0, pages: [0x08, 18, 0x00] + [UInt8](repeating: 0, count: 16))
        #expect(ModeSense.writeCacheEnabled(inResponse: d) == false)
    }

    @Test func skipsBlockDescriptors() {
        let d = response(blockDescLen: 8, pages: [0x08, 18, 0x04] + [UInt8](repeating: 0, count: 16))
        #expect(ModeSense.writeCacheEnabled(inResponse: d) == true)
    }

    @Test func skipsEarlierPages() {
        // page 0x01 (read-write error recovery) then the caching page.
        let pages: [UInt8] = [0x01, 4, 0, 0, 0, 0] + [0x08, 18, 0x04] + [UInt8](repeating: 0, count: 16)
        #expect(ModeSense.writeCacheEnabled(inResponse: response(blockDescLen: 0, pages: pages)) == true)
    }

    @Test func missingCachingPageIsUnknown() {
        let pages: [UInt8] = [0x01, 4, 0, 0, 0, 0]
        #expect(ModeSense.writeCacheEnabled(inResponse: response(blockDescLen: 0, pages: pages)) == nil)
    }

    // MARK: hostile / malformed input — must return nil, never trap

    @Test func truncatedHeaderIsUnknown() {
        for n in 0 ..< 8 {
            #expect(ModeSense.writeCacheEnabled(inResponse: Data(count: n)) == nil, "len \(n)")
        }
    }

    @Test func blockDescriptorLengthPastEndIsRejected() {
        // Claims 60000 bytes of descriptors in an 8-byte buffer. Clamping
        // instead of rejecting would parse trailing bytes as a mode page.
        var d = Data(count: 8)
        d.setBE16(60000, 6)
        #expect(ModeSense.writeCacheEnabled(inResponse: d) == nil)
    }

    @Test func zeroLengthPageDoesNotLoopForever() {
        // A page claiming length 0 would leave the cursor unmoved.
        let pages: [UInt8] = [0x01, 0, 0x08, 18, 0x04] + [UInt8](repeating: 0, count: 16)
        #expect(ModeSense.writeCacheEnabled(inResponse: response(blockDescLen: 0, pages: pages)) == nil)
    }

    @Test func pageLengthPastEndTerminates() {
        let pages: [UInt8] = [0x01, 200, 0, 0]
        #expect(ModeSense.writeCacheEnabled(inResponse: response(blockDescLen: 0, pages: pages)) == nil)
    }

    @Test func truncatedCachingPageIsUnknown() {
        // Page header present but byte 2 (the WCE byte) missing.
        let pages: [UInt8] = [0x08, 18]
        #expect(ModeSense.writeCacheEnabled(inResponse: response(blockDescLen: 0, pages: pages)) == nil)
    }

    /// Never trap, whatever arrives. Data's accessors abort on an out-of-range
    /// offset, so a missed bounds check is a crash rather than a wrong answer.
    @Test func arbitraryBytesNeverTrap() {
        var rng = SystemRandomNumberGenerator()
        for len in 0 ... 64 {
            for _ in 0 ..< 20 {
                let bytes = (0 ..< len).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
                _ = ModeSense.writeCacheEnabled(inResponse: Data(bytes))
            }
        }
    }
}
