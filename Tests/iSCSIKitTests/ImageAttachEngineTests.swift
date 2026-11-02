import Testing
@testable import iSCSIKit

/// Which engine attaches `lun0.img`. `hdiutil` by default; DiskImages2 only by
/// preference, and only where the FSKit volume can make its writes
/// write-through (macOS 27). It was the 27 default until a guest booting from
/// a DiskImages2 volume panicked on a 10 s disk timeout (docs/open-questions.md
/// item 16).
@Suite("Image attach engine")
struct ImageAttachEngineTests {

    @Test("hdiutil by default, on every macOS")
    func hdiutilByDefault() {
        for major in [26, 27, 28] {
            #expect(ImageAttachEngine.choose(osMajor: major, override: nil) == .hdiutil)
        }
    }

    @Test("the preference opts in to DiskImages2 on macOS 27 and later")
    func preferenceOptsIn() {
        #expect(ImageAttachEngine.choose(osMajor: 27, override: "diskimages2") == .diskImages2)
        #expect(ImageAttachEngine.choose(osMajor: 28, override: "diskimages2") == .diskImages2)
    }

    /// Measured on 26.6.2 and 26.7.2: without the grant, writes short of a
    /// full flush waited in RAM. The preference must not reintroduce that.
    @Test("the preference cannot select DiskImages2 where writes cannot be made write-through")
    func preferenceCannotForceNewerEngineOn26() {
        #expect(ImageAttachEngine.choose(osMajor: 26, override: "diskimages2") == .hdiutil)
    }

    @Test("other preference values leave hdiutil")
    func otherValues() {
        #expect(ImageAttachEngine.choose(osMajor: 27, override: "hdiutil") == .hdiutil)
        #expect(ImageAttachEngine.choose(osMajor: 27, override: "fast") == .hdiutil)
        #expect(ImageAttachEngine.choose(osMajor: 27, override: "") == .hdiutil)
    }
}
