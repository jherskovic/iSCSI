import ArgumentParser
import Darwin
import Foundation
import NVMeKit
import iSCSIKit

struct NVMeNamespaceOptions: ParsableArguments {
    @Argument(help: "Subsystem host (IP or DNS name).") var host: String
    @Option(help: "NVMe/TCP port.") var port: UInt16 = 4420
    @Option(help: "Subsystem NQN.") var subsystem: String
    @Option(help: "Namespace ID.") var nsid: UInt32 = 1

    func withVolume(_ body: (URL, URL) throws -> Void) throws {
        guard port > 0, nsid > 0, nsid < UInt32.max, NQN.isValid(subsystem),
              !subsystem.contains("/"),
              let base = MountResourceURL.make(host: host, port: port, target: subsystem, lun: UInt64(nsid)),
              var url = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw ValidationError("Invalid portal, subsystem NQN, or namespace ID.") }
        url.port = Int(port)
        guard let resource = url.url else { throw ValidationError("Invalid portal.") }
        let tag = MountpointTag.derive(portal: MountpointTag.portal(host: host, port: port),
                                      targetIQN: subsystem, lun: UInt64(nsid))
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/me.herko.iSCSIInitiator")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appendingPathComponent(tag + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ValidationError("Another operation is using this namespace.")
        }
        try body(resource, root.appendingPathComponent(tag))
    }
}

@discardableResult
func runNamespaceCommand(_ path: String, _ arguments: [String], output: Pipe? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let output { process.standardOutput = output }
    try process.run()
    let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ExitCode(process.terminationStatus) }
    return data
}
