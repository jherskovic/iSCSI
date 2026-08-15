//
//  FSKitSettingsLinkCheck.swift
//  A startup assertion for the one API we reach by name.
//
//  FSKitSettingsLink trades a compile-time check for a selector string, so that
//  the app can be built against the macOS 26 SDK and therefore be built in CI at
//  all. The cost is that a rename by Apple becomes a silent no-op instead of a
//  build failure.
//
//  This is the tripwire. On a machine that *should* have the API — macOS 27 or
//  later — its absence means the selector is wrong, and that gets logged loudly
//  rather than discovered by a user wondering why a button does nothing. On
//  macOS 26 its absence is simply the truth and nothing is said.
//

import Foundation
import os

enum FSKitSettingsLinkCheck {
    private static let log = Logger(subsystem: "me.herko.iSCSIInitiator",
                                    category: "compatibility")

    static func verify() {
        guard #available(macOS 27, *) else { return }
        if !FSKitSettingsLink.isAvailable {
            log.error("""
                FSClient no longer responds to \(FSKitSettingsLink.selectorName, privacy: .public) \
                on macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public). \
                The deep link to File System Extensions has silently stopped working; \
                see FSKitSettingsLink.
                """)
        }
    }
}
