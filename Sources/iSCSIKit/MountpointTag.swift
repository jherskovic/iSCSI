//
//  MountpointTag.swift
//  The name of the hidden directory a LUN is served into.
//
//  A **compatibility contract**: a volume attached by any older version is
//  recognised only because its directory name recomputes to the same string.
//  Change the derivation and existing mounts become invisible — detach can't
//  find them and attach stacks a second mount on a busy path. Lives in
//  iSCSIKit so `swift test` can pin it.
//

import CryptoKit
import Foundation

public enum MountpointTag {
    /// sha256("portal|targetIQN|lun"), hex, first 16 characters — byte-for-byte
    /// the shell derivation it replaces:
    ///
    ///     printf '%s|%s|%s' "$PORTAL" "$TARGET" "$LUN" | shasum -a 256 | cut -c1-16
    ///
    /// A hash because an IQN is long and contains `:` and `.`; not for secrecy.
    public static func derive(portal: String, targetIQN: String, lun: UInt64) -> String {
        let digest = SHA256.hash(data: Data("\(portal)|\(targetIQN)|\(lun)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// How a portal is spelled in the tag *and* the `iscsi://` URL. The
    /// default port is omitted: pre-existing tags hashed a bare host.
    public static func portal(host: String, port: UInt16) -> String {
        port == 3260 ? host : "\(host):\(port)"
    }
}
