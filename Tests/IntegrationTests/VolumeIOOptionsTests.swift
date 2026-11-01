import Foundation
import Testing
@testable import iSCSIKit
@testable import iSCSIVolume

/// The FSKit volume's read and cache behaviour per mount: the shipping
/// behaviour unless the app attached with DiskImages2, and the overrides kept
/// for measurement.
@Suite("Volume I/O options")
struct VolumeIOOptionsTests {

    private func resolve(_ query: String, osMajor: Int) -> VolumeIOOptions {
        let items = URLComponents(string: "nvme://h/t/1" + query)?.queryItems ?? []
        return VolumeIOOptions.resolve(query: items, osMajor: osMajor)
    }

    @Test("no query: blocking replies and no grant, as every release shipped")
    func shippingByDefault() {
        for major in [26, 27, 28] {
            #expect(resolve("", osMajor: major) == .shipping)
        }
    }

    @Test("the DiskImages2 profile on macOS 27: async replies and a write-through grant")
    func diskImages2ProfileOn27() {
        #expect(resolve("?engine=diskimages2", osMajor: 27)
                == VolumeIOOptions(asyncReads: true, cacheGrant: .writeThrough))
    }

    @Test("the DiskImages2 profile is ignored on macOS 26")
    func diskImages2ProfileIgnoredOn26() {
        #expect(resolve("?engine=diskimages2", osMajor: 26) == .shipping)
    }

    /// The grant is what makes DiskImages2 safe, so every macOS where the app
    /// would attach with it must give the volume the grant when asked.
    @Test("wherever the app can pick DiskImages2, its mount query gets the grant")
    func engineAndProfileAgree() {
        let query = "?\(ImageAttachEngine.mountQuery.name)=\(ImageAttachEngine.mountQuery.value!)"
        for major in 25 ... 29 {
            let canPick = ImageAttachEngine.choose(osMajor: major, override: "diskimages2") == .diskImages2
            let granted = resolve(query, osMajor: major).cacheGrant == .writeThrough
            #expect(canPick == granted, "macOS \(major)")
        }
    }

    @Test("overrides apply on top")
    func overrides() {
        #expect(resolve("?engine=diskimages2&reads=blocking", osMajor: 27).asyncReads == false)
        #expect(resolve("?engine=diskimages2&cache=nocache", osMajor: 27).cacheGrant == .noCache)
        #expect(resolve("?engine=diskimages2&cache=fskit", osMajor: 27).cacheGrant == nil)
        #expect(resolve("?reads=async", osMajor: 26).asyncReads == true)
        #expect(resolve("?cache=readcache", osMajor: 27).cacheGrant == .readCache)
    }

    @Test("an unrecognised value leaves the profile")
    func typosFallBack() {
        #expect(resolve("?engine=diskimages2&reads=fast&cache=wt", osMajor: 27)
                == VolumeIOOptions.diskImages2Profile(osMajor: 27))
        #expect(resolve("?engine=dmg", osMajor: 27) == .shipping)
    }
}
