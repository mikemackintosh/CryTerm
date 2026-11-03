//
//  FrostedCardView.swift
//  iTerm2SharedARC
//
//  A rounded, translucent card that floats over a terminal: Liquid Glass on
//  macOS 26, a vibrant material blended with the window's own content before
//  that. Matches Open Quickly's palette so announcements and the palettes read
//  as one family. Content goes in `contentView`.
//

import AppKit

@objc(iTermFrostedCardView)
final class FrostedCardView: NSView {
    @objc let contentView = NSView()
    private let effect: NSView

    @objc init(frame frameRect: NSRect, cornerRadius: CGFloat) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor.it_dynamicColor(forLightMode: NSColor(white: 0.97, alpha: 0.45),
                                                      darkMode: NSColor(white: 0.07, alpha: 0.55))
            effect = glass
        } else {
            let visual = NSVisualEffectView()
            // Within the window: the card sits over the terminal, not the desktop.
            visual.blendingMode = .withinWindow
            visual.material = .popover
            visual.state = .active
            visual.maskImage = Self.roundedMask(radius: cornerRadius)
            effect = visual
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        if #unavailable(macOS 26) {
            layer?.borderWidth = 0.5
        }

        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A hairline so the card's edge reads on any terminal background.
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }

    // A stretchable rounded rectangle, the standard way to round a visual
    // effect view's corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
