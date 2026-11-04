//
//  CommandLineLink.swift
//  What is at /usr/local/bin/iscsictl, and so what setup may do about it.
//
//  That directory belongs to everything on the Mac and `iscsictl` is not a name
//  only this app could use, so the rule is that nothing there is this app's
//  unless it provably is: a link to the tool in this copy of the app. Anything
//  else is left alone, including a link that dangles, which setup cannot tell
//  from a link to a volume that is not mounted right now.
//

import Foundation

public enum CommandLineLink: Sendable, Equatable {
    /// Nothing there: setup may offer to add the link.
    case absent
    /// A link to this copy's tool. The only case uninstall may remove.
    case ours
    /// A link to anything else.
    case otherLink(String)
    /// A file or a directory.
    case notALink

    public static let path = "/usr/local/bin/iscsictl"

    /// - Parameters:
    ///   - exists: `lstat` found something, which a dangling link counts as.
    ///   - destination: where it points; nil when it is not a link.
    ///   - tool: the tool in this copy of the app.
    public static func decide(exists: Bool, destination: String?, tool: String) -> CommandLineLink {
        guard exists else { return .absent }
        guard let destination else { return .notALink }
        return destination == tool ? .ours : .otherLink(destination)
    }
}
