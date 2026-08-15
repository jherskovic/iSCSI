//
//  MountpointTag.swift
//  The name of the hidden directory a LUN is served into.
//
//  This is a **compatibility contract**, not an implementation detail. A volume
//  attached by an older version — including by the bash scripts this replaced —
//  is only recognised as already-attached because its directory name is
//  recomputed to the same string. Change the derivation and every previously
//  attached volume becomes invisible to the app: it will not appear as attached,
//  detach will not find it, and attaching again will stack a second mount on a
//  path that is already in use.
//
//  It lives in iSCSIKit rather than beside the code that uses it purely so that
//  `swift test` can pin it. That is the whole reason.
//

import CryptoKit
import Foundation

public enum MountpointTag {
    /// sha256("portal|targetIQN|lun"), hex, first 16 characters.
    ///
    /// Byte-for-byte the shell derivation it replaces:
    ///
    ///     printf '%s|%s|%s' "$PORTAL" "$TARGET" "$LUN" | shasum -a 256 | cut -c1-16
    ///
    /// A hash rather than the IQN itself because an IQN contains `:` and `.`
    /// and is long, and this directory is a mount point no human is meant to
    /// read. Not for secrecy — it is derived from public information.
    public static func derive(portal: String, targetIQN: String, lun: UInt64) -> String {
        let digest = SHA256.hash(data: Data("\(portal)|\(targetIQN)|\(lun)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// How a portal is spelled when it goes into the tag *and* into the
    /// `iscsi://` URL. The default port is omitted, because the shell scripts
    /// were given a bare host and any target configured before this code existed
    /// hashed a bare host.
    public static func portal(host: String, port: UInt16) -> String {
        port == 3260 ? host : "\(host):\(port)"
    }
}
