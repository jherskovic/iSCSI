//
//  XPCModels.swift
//  Data transfer objects for the daemon's XPC surface.
//
//  These cross the wire as `Data` holding Codable structs, not as
//  NSSecureCoding classes. NSXPC can carry object graphs, but every method that
//  returns a collection then needs its classes allowlisted with
//  setClasses(_:for:argumentIndex:ofReply:) — a step the compiler does not
//  check, that is invisible until the call silently fails at runtime, and that
//  has to be repeated for every new method. Encoding to Data moves the problem
//  into Codable, where the compiler does check it.
//

import Foundation

/// Identity and liveness of the running daemon.
///
/// The setup flow's whole question is "is the thing I registered actually alive
/// and is it the build I shipped?", and neither half is answerable from
/// `SMAppService.status`: launchd reporting `.enabled` only means it is willing
/// to start the job. This is the round trip that distinguishes "approved and
/// working" from "approved and crashing", which need opposite instructions.
public struct DaemonInfo: Codable, Sendable, Equatable {
    /// CFBundleShortVersionString of the app bundle the daemon shipped inside,
    /// or "dev" when it is running loose from `swift run`.
    public let version: String
    /// CFBundleVersion, to tell two builds of the same marketing version apart.
    public let build: String
    public let pid: Int32
    /// True when the daemon skipped its XPC code-signing check because it was
    /// built with DEBUG. Surfaced so the UI can say so rather than looking
    /// identical to a hardened one.
    public let authorizationRelaxed: Bool

    public init(version: String, build: String, pid: Int32, authorizationRelaxed: Bool) {
        self.version = version
        self.build = build
        self.pid = pid
        self.authorizationRelaxed = authorizationRelaxed
    }
}
