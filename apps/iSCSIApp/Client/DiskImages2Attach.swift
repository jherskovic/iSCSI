//
//  DiskImages2Attach.swift
//  Attaching a LUN image through DiskImages2 at a block size of our choosing.
//
//  `diskutil image attach` is the public face of DiskImages2, the engine that
//  reads `lun0.img` concurrently (docs/open-questions.md item 17), but it has
//  no block-size option, not even hidden. A LUN whose GPT was written with
//  4096-byte blocks is invisible at 512 (GitHub issue #2). The framework under
//  `diskutil` can: `DIAttachParams` inherits a writable `blockSize`, and
//  `+[DiskImages2 attachWithParams:handle:error:]` attaches with it. Measured
//  2026-10-31 on macOS 26.6.2, 26.7.2 and 27.2: 512 and only the protective
//  MBR by default, 4096 and the GPT with `blockSize` set, no entitlement
//  needed.
//
//  Private API, so everything is looked up at runtime and any absence is an
//  `unavailable` error, never a crash: the caller falls back to `hdiutil`.
//

import Foundation
import ObjectiveC

enum DiskImages2Attach {

    enum Failure: Error, CustomStringConvertible {
        /// The framework, a class or a selector is missing: this macOS does
        /// not offer the call. Fall back.
        case unavailable(String)
        /// The call exists and refused.
        case refused(String)

        var description: String {
            switch self {
            case .unavailable(let why): return "DiskImages2 attach unavailable: \(why)"
            case .refused(let why): return "DiskImages2 attach failed: \(why)"
            }
        }
    }

    /// Attach `image` with the device's logical block size set to
    /// `blockSize`. With `autoMount`, mountable volumes are mounted the way
    /// `diskutil image attach --mountPolicy autoMount` does it: EFI left alone,
    /// and an image with nothing mountable simply attached. Returns the
    /// whole-disk BSD name, such as "disk9".
    static func attach(image: URL, blockSize: Int, autoMount: Bool) throws -> String {
        guard dlopen("/System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2", RTLD_NOW) != nil else {
            throw Failure.unavailable("could not load DiskImages2.framework")
        }
        guard let paramsClass = NSClassFromString("DIAttachParams") else {
            throw Failure.unavailable("no DIAttachParams")
        }
        guard let facade = NSClassFromString("DiskImages2") else {
            throw Failure.unavailable("no DiskImages2 class")
        }
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithURL:error:")
        let attachSel = NSSelectorFromString("attachWithParams:handle:error:")
        guard class_getInstanceMethod(paramsClass, initSel) != nil else {
            throw Failure.unavailable("no -[DIAttachParams initWithURL:error:]")
        }
        guard class_getClassMethod(facade, attachSel) != nil else {
            throw Failure.unavailable("no +[DiskImages2 attachWithParams:handle:error:]")
        }
        // Set through key-value coding, not a typed call: `blockSize` is a
        // 32-bit `unsigned int` on macOS 26 and a 64-bit `unsigned long long`
        // on 27, and KVC unboxes the NSNumber into whichever the setter takes.
        guard class_getInstanceMethod(paramsClass, NSSelectorFromString("setBlockSize:")) != nil,
              class_getInstanceMethod(paramsClass, NSSelectorFromString("setAutoMount:")) != nil else {
            throw Failure.unavailable("no setBlockSize:/setAutoMount: on DIAttachParams")
        }

        // alloc returns +1; init consumes it and returns +1 or nil. Called
        // through their implementations with Unmanaged, so ARC adds nothing.
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (Unmanaged<AnyObject>, Selector, NSURL,
                                           AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
        typealias AttachFn = @convention(c) (AnyClass, Selector, AnyObject,
                                             AutoreleasingUnsafeMutablePointer<AnyObject?>,
                                             AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

        guard let metaclass = object_getClass(paramsClass),
              let allocIMP = class_getMethodImplementation(metaclass, allocSel),
              let initIMP = class_getMethodImplementation(paramsClass, initSel),
              let facadeMeta = object_getClass(facade),
              let attachIMP = class_getMethodImplementation(facadeMeta, attachSel) else {
            throw Failure.unavailable("could not resolve method implementations")
        }
        let alloc = unsafeBitCast(allocIMP, to: AllocFn.self)
        let initialise = unsafeBitCast(initIMP, to: InitFn.self)
        let attachCall = unsafeBitCast(attachIMP, to: AttachFn.self)

        var error: NSError?
        guard let made = initialise(alloc(paramsClass, allocSel), initSel, image as NSURL, &error) else {
            throw Failure.refused("DIAttachParams: \(error?.localizedDescription ?? "nil without an error")")
        }
        let params = made.takeRetainedValue() as! NSObject
        params.setValue(autoMount, forKey: "autoMount")
        params.setValue(NSNumber(value: blockSize), forKey: "blockSize")
        // The setter records an override rather than changing `blockSize`'s
        // getter, which still reads 512; check the override took.
        guard (params.value(forKey: "overrideBlockSize") as? NSNumber)?.intValue == blockSize else {
            throw Failure.unavailable("blockSize was not accepted (overrideBlockSize unchanged)")
        }

        var handle: AnyObject?
        error = nil
        guard attachCall(facade, attachSel, params, &handle, &error) else {
            throw Failure.refused(error?.localizedDescription ?? "returned NO without an error")
        }
        guard let bsd = (handle as? NSObject)?.value(forKey: "BSDName") as? String, !bsd.isEmpty else {
            throw Failure.refused("attached, but the handle carries no BSD name")
        }
        return bsd
    }
}
