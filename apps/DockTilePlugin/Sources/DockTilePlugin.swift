// Dock tile plug-in: draws the raw, un-squircled app icon into the Dock tile.
//
// macOS 26 (Tahoe) forces regular app icons into a squircle with a backdrop,
// which double-processes an icon that already fills its square edge to edge.
// A dock tile plug-in draws the tile itself, so the flat design survives
// intact. The Dock loads this bundle (named by the app Info.plist's
// NSDockTilePlugIn key) whenever the app's tile is in the Dock but the app
// isn't running; ISCSIInitiatorApp installs the same view itself at launch
// to cover the running case.
import AppKit

// The principal class is looked up by the un-prefixed name in Info.plist.
// The Dock calls into the plug-in on the main thread; @preconcurrency lets
// the MainActor-isolated class satisfy the nonisolated ObjC protocol, with
// the isolation enforced at runtime instead of in the signature.
@objc(DockTilePlugin)
@MainActor
final class DockTilePlugin: NSObject, @preconcurrency NSDockTilePlugIn {
    func setDockTile(_ dockTile: NSDockTile?) {
        guard let dockTile,
              let image = Bundle(for: DockTilePlugin.self).image(forResource: "DockIcon")
        else { return }
        let view = NSImageView(frame: NSRect(origin: .zero, size: dockTile.size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.image = image
        dockTile.contentView = view
        dockTile.display()
    }
}
