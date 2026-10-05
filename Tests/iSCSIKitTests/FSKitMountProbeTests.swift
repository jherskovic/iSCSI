import Testing
@testable import iSCSIKit

/// Reading a `mount -F` of the extension's local test store, which Setup
/// falls back on when FSKit's list of extensions leaves the module out.
@Suite("FSKit mount probe")
struct FSKitMountProbeTests {

    @Test("a mount that succeeds means registered and enabled")
    func mounts() {
        #expect(FSKitMountProbe.classify(status: 0, output: "") == .mounts)
    }

    @Test("a disabled module is registered but not enabled")
    func disabled() {
        let output = "mount: Module me.herko.iSCSIInitiator.fsext is disabled!\n"
        #expect(FSKitMountProbe.classify(status: 69, output: output) == .disabled)
    }

    @Test("both ways mount says the module is unknown")
    func notFound() {
        #expect(FSKitMountProbe.classify(status: 69, output: "mount: File system named iSCSI not found\n")
                == .notFound)
        #expect(FSKitMountProbe.classify(status: 1, output: "No extension with fsShortName (iSCSI) found.")
                == .notFound)
    }

    @Test("anything else is reported as it was printed, trimmed")
    func other() {
        let output = "mount: Loading resource: Input/output error\nmount: Unable to invoke task\n"
        #expect(FSKitMountProbe.classify(status: 69, output: output)
                == .failed("mount: Loading resource: Input/output error mount: Unable to invoke task"))
        #expect(FSKitMountProbe.classify(status: 1, output: "  ") == .failed("exited 1"))
    }

    @Test("the test store is the extension's local one, never a network target")
    func testURL() {
        #expect(FSKitMountProbe.testURL.hasPrefix("iscsi://proto/"))
    }
}
