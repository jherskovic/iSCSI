import ArgumentParser
import Darwin
import Foundation
import os
import NVMeKit
import iSCSIKit

struct NVMeNamespaceOptions: ParsableArguments {
    @Argument(help: "Subsystem host (IP or DNS name).") var host: String
    @Option(help: "NVMe/TCP port.") var port: UInt16 = 4420
    @Option(help: "Subsystem NQN.") var subsystem: String
    @Option(help: "Namespace ID.") var nsid: UInt32 = 1

    func validate() throws {
        guard geteuid() != 0 else { throw NamespaceError("Run as the logged-in user without sudo. Targets belong to each account.") }
        guard port > 0, nsid > 0, nsid < UInt32.max, NQN.isValid(subsystem),
              !subsystem.contains("/"),
              MountResourceURL.make(host: host, port: port, target: subsystem, lun: UInt64(nsid)) != nil
        else { throw ValidationError("Invalid portal, subsystem NQN, or namespace ID.") }
    }

    func withVolume(_ body: (URL, URL) throws -> Void) throws {
        try validate()
        let records = try namespaceTargets()
        guard let record = NamespaceLifecycle.record(in: records, host: host, port: port,
                                                     subsystem: subsystem, nsid: UInt64(nsid)),
              let resource = MountResourceURL.make(host: record.host, port: record.port,
                                                   target: record.targetIQN, lun: record.lun)
        else { throw NamespaceError("Namespace is not configured. Add it with nvme add first.") }
        let host = record.host
        let port = record.port
        let subsystem = record.targetIQN
        let nsid = record.lun
        let tag = MountpointTag.derive(portal: MountpointTag.portal(host: host, port: port),
                                      targetIQN: subsystem, lun: UInt64(nsid))
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/me.herko.iSCSIInitiator")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appendingPathComponent(tag + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw NamespaceError("Another operation is using this namespace.")
        }
        try body(resource, root.appendingPathComponent(tag))
    }
}

struct NamespaceError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func namespaceTargets() throws -> [TargetRecord] {
    let connection = NSXPCConnection(machServiceName: iscsiDaemonServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: ISCSIDaemonProtocol.self)
    connection.resume()
    defer { connection.invalidate() }
    let semaphore = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<Result<Data, Error>?>(initialState: nil)
    let finish: @Sendable (Data?, Error?) -> Void = { data, error in
        result.withLock { value in
            guard value == nil else { return }
            value = error.map { .failure($0) } ?? .success(data ?? Data())
            semaphore.signal()
        }
    }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish(nil, $0) }) as? ISCSIDaemonProtocol
    else { throw NamespaceError("Cannot connect to iscsid.") }
    proxy.listTargets(reply: finish)
    guard semaphore.wait(timeout: .now() + 30) == .success else { throw NamespaceError("iscsid did not reply.") }
    return try JSONDecoder().decode([TargetRecord].self, from: result.withLock { try $0!.get() })
}

func namespaceMounts() throws -> [MountTableEntry] {
    var buffer: UnsafeMutablePointer<statfs>?
    let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
    guard count > 0, let buffer else { throw NamespaceError("Cannot read mount table.") }
    defer { free(buffer) }
    return (0..<Int(count)).map { index in
        var entry = buffer[index]
        let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let on = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return MountTableEntry(from: from, on: on)
    }
}

func namespaceDevice(image: String) throws -> String? {
    let data = try runNamespaceCommand("/usr/bin/hdiutil", ["info", "-plist"], output: Pipe())
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let images = plist["images"] as? [[String: Any]] else { throw NamespaceError("Cannot read image list.") }
    for entry in images where entry["image-path"] as? String == image {
        guard let entities = entry["system-entities"] as? [[String: Any]],
              let disk = entities.compactMap({ $0["dev-entry"] as? String }).first(where: {
                  $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
              }) else { throw NamespaceError("Cannot identify disk for \(image).") }
        return disk
    }
    return nil
}

func detachNamespaceDevice(image: String) throws {
    guard let disk = try namespaceDevice(image: image) else { return }
    do { try runNamespaceCommand("/usr/bin/hdiutil", ["detach", disk]) }
    catch { if try namespaceDevice(image: image) != nil { throw error } }
}

func unmountNamespace(_ path: String) throws {
    for attempt in 0..<3 {
        guard try namespaceMounts().contains(where: { $0.on == path }) else { return }
        do { try runNamespaceCommand("/sbin/umount", [path]); return }
        catch {
            if try !namespaceMounts().contains(where: { $0.on == path }) { return }
            if attempt == 2 { throw error }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

@discardableResult
func runNamespaceCommand(_ path: String, _ arguments: [String], output: Pipe? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    // A temporary file avoids pipe backpressure while the child is monitored.
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
    if output != nil { process.standardOutput = handle }
    try process.run()
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        process.terminate()
        let grace = Date().addingTimeInterval(2)
        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
                throw NamespaceError("Cannot terminate \(path): \(String(cString: strerror(errno))).")
            }
        }
        // Reap the terminated child before callers inspect or tear down the
        // state it may have created. Sending a signal alone is asynchronous.
        process.waitUntilExit()
        throw NamespaceError("\(path) timed out after 60 seconds. Inspect attachment state before retrying.")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NamespaceError("\(path) failed with status \(process.terminationStatus).") }
    return output == nil ? Data() : try Data(contentsOf: file)
}
