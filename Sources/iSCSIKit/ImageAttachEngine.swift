//
//  ImageAttachEngine.swift
//  Which disk-image engine turns `lun0.img` into a /dev/diskN.
//
//  Two engines, measured 2026-10-31 (docs/open-questions.md items 16-17):
//  - `hdiutil` with `diskimage-class=CRawDiskImage` (the old DiskImages
//    framework) reads `lun0.img` one request at a time and caches nothing above
//    the FSKit volume. Through a mount that capped reads at about 600 IOPS
//    however many were issued.
//  - DiskImages2 (`diskutil image attach`, or its framework for a block size
//    `diskutil` cannot set) reads concurrently: 8 reads in flight and about 7x
//    the IOPS of one reader on a cold region. But it reads and writes
//    `lun0.img` through the page cache, so writes short of a full flush waited
//    10-30 s in RAM, unless the FSKit volume grants write-through, which only
//    macOS 27's FSKit can. With the grant, every write was on the target
//    before its call returned.
//
//  `hdiutil` is the default everywhere. DiskImages2 was the macOS 27 default
//  until a FreeBSD guest booting from a DiskImages2 volume panicked: a disk
//  command did not complete within 10 s, and writes averaged 120-140 ms (the
//  same VM booted cleanly on `hdiutil` earlier the same day). Until that is
//  understood DiskImages2 is opt-in, and only where its writes can be made
//  write-through:
//
//      defaults write me.herko.iSCSIInitiator ImageAttachEngine diskimages2
//

import Foundation

public enum ImageAttachEngine: String, Sendable, Equatable {
    case hdiutil
    case diskImages2 = "diskimages2"

    /// The preference that opts in to DiskImages2, in the app's defaults.
    public static let preferenceKey = "ImageAttachEngine"

    /// The first macOS whose FSKit lets a volume grant the kernel
    /// write-through caching (FSKit V3, `FSVolume.DataCacheHandler`).
    /// DiskImages2 never runs below it: nothing there can stop its page cache
    /// holding acknowledged writes.
    public static let firstWriteThroughMajor = 27

    /// The mount-URL query the app adds when it attaches with DiskImages2, so
    /// the FSKit volume serves that engine the way it needs: async replies,
    /// and a write-through grant (`VolumeIOOptions`). The volume cannot see
    /// which engine attached it any other way.
    public static let mountQuery = URLQueryItem(name: "engine", value: ImageAttachEngine.diskImages2.rawValue)

    /// `hdiutil` unless `override` asks for DiskImages2 on a macOS that can
    /// make its writes write-through.
    public static func choose(osMajor: Int, override: String?) -> ImageAttachEngine {
        guard override.flatMap(ImageAttachEngine.init(rawValue:)) == .diskImages2,
              osMajor >= firstWriteThroughMajor else { return .hdiutil }
        return .diskImages2
    }
}
