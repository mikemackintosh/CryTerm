//
//  iTermAppIconController.swift
//  iTerm2
//
//  CryTerm ships its icon in three colors. The bundled icon (what Finder and
//  Launchpad show) is orange; Settings > Appearance > General > App icon picks
//  which one the Dock shows while CryTerm runs, or rotates to the next color at
//  each launch. Only the Dock icon changes: rewriting the icon inside the app
//  bundle would invalidate its code signature.
//

import AppKit

@objc(iTermAppIconController)
class AppIconController: NSObject {
    // Values of kPreferenceKeyAppIcon. Saved in preferences; do not renumber.
    private enum Choice: Int {
        case orange = 0
        case teal = 1
        case purple = 2
        case rotate = 3
    }

    // Index 0 is the bundled icon, so it needs no image of its own.
    private static let variantResourceNames = [nil, "CryTermIcon-teal", "CryTermIcon-purple"]

    // NoSync: remembers rotation position; not a setting.
    private static let lastRotationKey = "NoSyncCryTermAppIconLastRotation"

    // Call once at launch, before anything draws the Dock tile.
    @objc static func applyAtLaunch() {
        apply(advanceRotation: true)
    }

    // Call when the App icon setting changes. Choosing Rotate shows the next
    // color right away, so the choice visibly takes effect.
    @objc static func settingDidChange() {
        apply(advanceRotation: true)
    }

    private static func apply(advanceRotation: Bool) {
        let rawValue = Int(iTermPreferences.int(forKey: kPreferenceKeyAppIcon))
        let choice = Choice(rawValue: rawValue) ?? .orange
        let index: Int
        switch choice {
        case .orange, .teal, .purple:
            index = choice.rawValue
        case .rotate:
            let userDefaults = iTermUserDefaults.userDefaults()
            let last = userDefaults.integer(forKey: lastRotationKey)
            let count = variantResourceNames.count
            index = advanceRotation ? (last + 1) % count : last % count
            userDefaults.set(index, forKey: lastRotationKey)
        }
        DLog("App icon choice \(choice), showing variant \(index)")
        if let name = variantResourceNames[index] {
            guard let image = dockImage(resourceName: name) else {
                DLog("Missing app icon resource \(name); keeping the bundled icon")
                NSApp.applicationIconImage = nil
                return
            }
            NSApp.applicationIconImage = image
        } else {
            // nil restores the bundled icon.
            NSApp.applicationIconImage = nil
        }
        // A custom Dock tile view (the -suite name overlay) draws the current icon itself.
        NSApp.dockTile.contentView?.needsDisplay = true
        NSApp.dockTile.display()
    }

    // The artwork is full-bleed. Draw it the way macOS shows app icons: a rounded
    // square on the standard 1024-point grid (824-point body, 100-point margin).
    private static func dockImage(resourceName: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let artwork = NSImage(contentsOf: url) else {
            return nil
        }
        let canvas = NSSize(width: 1024, height: 1024)
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        return NSImage(size: canvas, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            path.addClip()
            artwork.draw(in: body)
            return true
        }
    }
}
