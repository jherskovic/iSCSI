import Testing
@testable import iSCSIKit

/// What setup may do about `/usr/local/bin/iscsictl`, given what is there.
@Suite("Command-line link")
struct CommandLineLinkTests {
    private let tool = "/Applications/iSCSI Initiator.app/Contents/MacOS/iscsictl"

    @Test("nothing there can be offered")
    func nothingThere() {
        #expect(CommandLineLink.decide(exists: false, destination: nil, tool: tool) == .absent)
    }

    @Test("a link to this copy's tool is ours")
    func ourLink() {
        #expect(CommandLineLink.decide(exists: true, destination: tool, tool: tool) == .ours)
    }

    /// Uninstall removes what is `.ours`, so these are what it must not touch.
    @Test("a link to anything else is not ours", arguments: [
        "/opt/homebrew/bin/iscsictl",
        "/Applications/iSCSI Initiator 2.app/Contents/MacOS/iscsictl",
        "../libexec/iscsictl",
    ])
    func someoneElsesLink(destination: String) {
        #expect(CommandLineLink.decide(exists: true, destination: destination, tool: tool)
                == .otherLink(destination))
    }

    @Test("a file is not ours")
    func aFile() {
        #expect(CommandLineLink.decide(exists: true, destination: nil, tool: tool) == .notALink)
    }
}
