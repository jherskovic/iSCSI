//
//  FSKitSettingsLink.swift
//  Reaching a macOS 27 API without requiring the macOS 27 SDK to build.
//
//  `FSClient.openFileSystemExtensionsSettings()` is the only API in this app
//  newer than the macOS 26 SDK. Calling it directly means the project can only
//  be built with an Xcode beta, which in turn means the app target cannot be
//  built in CI at all — so every SwiftUI change goes uncompiled by anything but
//  the author's machine. That is a worse risk than the one taken here.
//
//  It is Objective-C, declared in FSClient.h as
//
//      -(BOOL)openFileSystemExtensionsSettings FSKIT_API_AVAILABILITY_V3;
//
//  on `@interface FSClient : NSObject`, so it can be reached by selector.
//
//  **The tradeoff, stated plainly:** a selector string is not checked by the
//  compiler. If Apple renames this, a direct call would fail to build and this
//  will silently do nothing instead. Three things bound that: the call returns
//  false rather than pretending it worked, every caller already has a fallback
//  because the API does not exist on macOS 26 anyway, and a test asserts the
//  selector still exists whenever the suite runs on macOS 27 or later.
//

import Foundation
import FSKit
import ObjectiveC

enum FSKitSettingsLink {
    static let selectorName = "openFileSystemExtensionsSettings"

    /// True when the running OS actually has the method. On macOS 26 this is
    /// false, which is correct rather than a failure — there is no such API
    /// there, which is why R7's URL-scheme fallback exists.
    static var isAvailable: Bool {
        let client: AnyObject = FSClient.shared
        return client.responds(to: NSSelectorFromString(selectorName))
    }

    /// Opens System Settings at File System Extensions. Returns whether macOS
    /// accepted the request.
    static func open() -> Bool {
        let client: AnyObject = FSClient.shared
        let selector = NSSelectorFromString(selectorName)
        guard let cls = object_getClass(client),
              let method = class_getInstanceMethod(cls, selector) else { return false }

        // Called through its IMP with the true signature. `perform(_:)` would be
        // wrong here: it declares the return as `id`, and this returns BOOL —
        // reading a one-byte return out of a pointer-sized result is exactly the
        // kind of mismatch that appears to work until it does not.
        typealias Open = @convention(c) (AnyObject, Selector) -> ObjCBool
        let implementation = unsafeBitCast(method_getImplementation(method), to: Open.self)
        return implementation(client, selector).boolValue
    }
}
