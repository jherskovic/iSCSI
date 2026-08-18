import Foundation
import Testing
@testable import iSCSIKit

/// The deframer reclaims its consumed prefix, and this asserts it in the only
/// way that would have caught the original bug: by watching the process.
///
/// The old `compactIfNeeded` called `buffer.removeFirst(consumed)` and looked
/// correct — `count` dropped, the tests passed, and every PDU decoded fine.
/// But `Data` is a slice type: `removeFirst` advances the slice's start and
/// keeps the backing store, so each `append` reallocated that same store
/// larger and the buffer grew by every byte the connection ever received.
/// Reading a file off a LUN cost resident memory 1:1 with the bytes read; one
/// daemon peaked at 37 GB. Nothing about the decoded PDUs was ever wrong, which
/// is why only a memory assertion catches it.
@Suite("PDU deframer memory")
struct FramerMemoryTests {
    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// A well-formed PDU with `dataBytes` of payload. Only the length fields
    /// matter here; the framer does not interpret the opcode.
    private func pdu(dataBytes: Int) -> Data {
        var out = Data(count: 48)
        out[5] = UInt8((dataBytes >> 16) & 0xFF)
        out[6] = UInt8((dataBytes >> 8) & 0xFF)
        out[7] = UInt8(dataBytes & 0xFF)
        out.append(Data(repeating: 0xCD, count: dataBytes))
        let pad = (4 - dataBytes % 4) % 4
        if pad > 0 { out.append(Data(count: pad)) }
        return out
    }

    @Test func consumedBytesAreReclaimed() throws {
        var deframer = PDUDeframer(maxDataSegmentLength: 1 << 20)
        let onePDU = pdu(dataBytes: 64 << 10)          // 64 KiB payload
        let rounds = 4096                               // 256 MiB total

        let before = footprintBytes()
        for _ in 0 ..< rounds {
            deframer.append(onePDU)
            while let raw = try deframer.next() {
                #expect(raw.data.count == 64 << 10)
            }
        }
        let grew = footprintBytes() &- before

        // 256 MiB pushed through. Before the fix this grew by the full amount;
        // the margin here is wide enough that it fails only on a real
        // regression, not on allocator noise.
        let grewMiB = grew / (1 << 20)
        #expect(grew < 32 << 20,
                "deframer grew \(grewMiB) MiB while consuming 256 MiB; the consumed prefix is not being reclaimed")
    }
}
