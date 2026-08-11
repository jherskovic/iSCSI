//
//  iSCSIFSExtension.swift
//  Backend A: an FSKit module that presents each iSCSI LUN as a regular file
//  whose reads/writes are serviced over iSCSI (via XPC to iscsid). The user
//  then runs `hdiutil attach -imagekey diskimage-class=CRawDiskImage <file>`
//  to obtain a real /dev/diskN — no DriverKit, no throughput ceiling.
//
//  ⚠️ API RECONCILIATION NEEDED AT BUILD TIME: FSKit's documented model is
//  built around *consuming* an FSBlockDeviceResource to implement a
//  filesystem. Producing a block-device-backing file from a network source is
//  the DTS-suggested stopgap (forum thread 837879) but has no shipping
//  reference. Verify the exact resource/probe model against the installed
//  FSKit before filling in the TODOs — the structure below is the intended
//  shape, not a compile-verified implementation.
//

import FSKit
import Foundation
import os

let fsLog = Logger(subsystem: "me.herko.iSCSIInitiator.fsext", category: "fs")

/// Extension entry point. The Info.plist declares this as the principal class.
@main
final class ISCSIFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        ISCSIUnaryFileSystem()
    }
}

/// One iSCSI-backed filesystem instance. Presents a flat volume containing a
/// single file, `lun.img`, sized to the LUN capacity; reading/writing that
/// file maps to SCSI READ/WRITE against the session held by iscsid.
final class ISCSIUnaryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    /// Bridge to the daemon that owns the live iSCSI session. Reads/writes at
    /// the file level become SCSI READ(16)/WRITE(16) over that session; the
    /// FSKit file offset maps directly to LBA × blockSize.
    private let daemon = DaemonBridge()

    // TODO(fskit): implement the probe/load/mount operations required by the
    // installed FSKit version:
    //   - probeResource: claim our resource type (see API note above)
    //   - loadResource / mount: attach to the daemon's session, learn capacity
    //   - the volume's single FSItem read(into:at:)/write(from:at:) forward to
    //     daemon.read(lba:count:) / daemon.write(lba:data:), translating byte
    //     offset ↔ LBA and honoring the block size.
    //   - sync/fsync → SCSI SYNCHRONIZE CACHE (crash consistency; see the
    //     e2e crash-consistency test).
}

/// XPC client to iscsid. The daemon owns the ISCSISession from iSCSIKit and
/// exposes block read/write/flush/capacity over a Mach service.
struct DaemonBridge {
    // TODO: NSXPCConnection to "me.herko.iSCSIInitiator.daemon" with a shared
    // @objc protocol: capacity() -> (blockSize, blockCount),
    // read(lba, count) -> Data, write(lba, Data), flush().
}
