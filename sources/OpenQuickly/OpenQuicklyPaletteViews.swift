//
//  OpenQuicklyPaletteViews.swift
//  iTerm2
//
//  Views for the Open Quickly palette: a single wide panel with the search
//  field on top, results on the left, a live preview of the highlighted
//  session on the right, and a key-hint footer. These views are deliberately
//  dumb; iTermOpenQuicklyWindowController computes everything they display.
//

import AppKit

// MARK: - Metrics

@objc(iTermOpenQuicklyPaletteMetrics)
final class OpenQuicklyPaletteMetrics: NSObject {
    @objc static let rowHeight: CGFloat = 50
    @objc static let headerHeight: CGFloat = 60
    @objc static let footerHeight: CGFloat = 34
    @objc static let cornerRadius: CGFloat = 16

    // Size of the palette for a screen's visible frame. Wide enough that the
    // list and preview sit side by side, tall enough to show ~10 rows.
    @objc static func paletteSize(forVisibleFrame visibleFrame: NSRect) -> NSSize {
        let width = min(max(visibleFrame.width * 0.62, 760), 1120)
        let height = min(max(visibleFrame.height * 0.62, 460), 720)
        return NSSize(width: floor(width), height: floor(height))
    }

    // Width of the results column for a given palette width.
    @objc static func listWidth(forPaletteWidth width: CGFloat) -> CGFloat {
        return floor(max(width * 0.44, 340))
    }
}

// MARK: - Background

// The palette's chrome: Liquid Glass on macOS 26, a HUD-style vibrant
// material before that. Subviews go in `contentView`.
@objc(iTermOpenQuicklyPaletteBackgroundView)
final class OpenQuicklyPaletteBackgroundView: NSView {
    @objc let contentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = OpenQuicklyPaletteMetrics.cornerRadius
        layer?.masksToBounds = true

        let effect: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = OpenQuicklyPaletteMetrics.cornerRadius
            glass.tintColor = NSColor.it_dynamicColor(forLightMode: NSColor(white: 0.97, alpha: 0.35),
                                                      darkMode: NSColor(white: 0.07, alpha: 0.5))
            effect = glass
        } else {
            // .fullScreenUI is the most see-through vibrant material; .hudWindow
            // read as a flat grey slab over a busy desktop.
            let visual = NSVisualEffectView()
            visual.blendingMode = .behindWindow
            visual.material = .fullScreenUI
            visual.state = .active
            effect = visual
            layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
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
}

// MARK: - Separator

@objc(iTermOpenQuicklySeparatorView)
final class OpenQuicklySeparatorView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - Keycap

// A small rounded “key” label such as ⌘1 or esc.
@objc(iTermOpenQuicklyKeycapView)
final class OpenQuicklyKeycapView: NSView {
    private let label = NSTextField(labelWithString: "")

    @objc var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    @objc init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 19),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.5
    }
}

// MARK: - Row

@objc(iTermOpenQuicklyPaletteRowView)
final class OpenQuicklyPaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }

    // Keep text in its normal colors on a selected row; the selection is a
    // tint, not a solid fill, so white-on-accent would be wrong.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        path.fill()
        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        stroke.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        stroke.stroke()
    }
}

// MARK: - Session tile

// A tiny terminal: the session's background color with a prompt drawn in its
// foreground color, a cursor in its cursor color, and a tab-color dot. Lets
// you recognize a session by its colors at a glance. Non-session items draw
// their icon instead.
@objc(iTermOpenQuicklyTileView)
final class OpenQuicklyTileView: NSView {
    private var backgroundColor: NSColor?
    private var textColor: NSColor?
    private var cursorColor: NSColor?
    private var tabColor: NSColor?
    private var icon: NSImage?

    override var isFlipped: Bool { true }

    @objc func configureSession(backgroundColor: NSColor?,
                                textColor: NSColor?,
                                cursorColor: NSColor?,
                                tabColor: NSColor?) {
        self.backgroundColor = backgroundColor ?? .black
        self.textColor = textColor ?? .white
        self.cursorColor = cursorColor ?? self.textColor
        self.tabColor = tabColor
        self.icon = nil
        needsDisplay = true
    }

    @objc func configureIcon(_ icon: NSImage?) {
        backgroundColor = nil
        textColor = nil
        cursorColor = nil
        tabColor = nil
        self.icon = icon
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        guard let backgroundColor else {
            icon?.draw(in: rect.insetBy(dx: 3, dy: 3),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1,
                       respectFlipped: true,
                       hints: nil)
            return
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        backgroundColor.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Localization unneeded: a glyph, not a word.
        let prompt = NSAttributedString(string: "$", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: textColor ?? .white,
        ])
        let promptSize = prompt.size()
        let promptOrigin = NSPoint(x: rect.minX + 6, y: rect.midY - promptSize.height / 2)
        prompt.draw(at: promptOrigin)
        let cursorRect = NSRect(x: promptOrigin.x + promptSize.width + 2,
                                y: rect.midY - 6,
                                width: 6,
                                height: 12)
        (cursorColor ?? .white).setFill()
        NSBezierPath(rect: cursorRect).fill()

        if let tabColor {
            let dot = NSRect(x: rect.maxX - 9, y: rect.minY + 3, width: 6, height: 6)
            tabColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

// MARK: - Cell

@objc(iTermOpenQuicklyPaletteCellView)
final class OpenQuicklyPaletteCellView: NSTableCellView {
    @objc static let reuseIdentifier = NSUserInterfaceItemIdentifier("iTermOpenQuicklyPaletteCell")

    @objc let tile = OpenQuicklyTileView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let keycap = OpenQuicklyKeycapView(text: "")
    private lazy var titleAboveCenter = titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
    private lazy var titleCentered = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)

    private static let titleFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    private static let titleMatchFont = NSFont.systemFont(ofSize: 13.5, weight: .bold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 11.5)
    private static let subtitleMatchFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)

        for field in [titleField, subtitleField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(field)
        }
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.textColor = .secondaryLabelColor

        addSubview(keycap)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 32),
            tile.heightAnchor.constraint(equalToConstant: 32),

            titleAboveCenter,
            titleField.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -10),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -10),

            keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    // `shortcut` is the keycap text, or nil to hide it. Bold runs in `title`
    // and `subtitle` mark fuzzy-match characters; they are restyled here in
    // the accent color.
    @objc func configure(title: NSAttributedString,
                         subtitle: NSAttributedString?,
                         shortcut: String?) {
        titleField.attributedStringValue = Self.restyle(title,
                                                        font: Self.titleFont,
                                                        matchFont: Self.titleMatchFont,
                                                        color: .labelColor,
                                                        lineBreakMode: .byTruncatingTail)
        if let subtitle, subtitle.length > 0 {
            subtitleField.attributedStringValue = Self.restyle(subtitle,
                                                               font: Self.subtitleFont,
                                                               matchFont: Self.subtitleMatchFont,
                                                               color: .secondaryLabelColor,
                                                               lineBreakMode: .byTruncatingMiddle)
            subtitleField.isHidden = false
        } else {
            subtitleField.stringValue = ""
            subtitleField.isHidden = true
        }
        if let shortcut {
            keycap.text = shortcut
            keycap.isHidden = false
        } else {
            keycap.isHidden = true
        }
        // With no subtitle, center the title vertically.
        // Deactivate before activating so the two never conflict.
        let (off, on) = subtitleField.isHidden ? (titleAboveCenter, titleCentered) : (titleCentered, titleAboveCenter)
        off.isActive = false
        on.isActive = true
    }

    private static func restyle(_ source: NSAttributedString,
                                font: NSFont,
                                matchFont: NSFont,
                                color: NSColor,
                                lineBreakMode: NSLineBreakMode) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source.string)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let whole = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: font,
                              .foregroundColor: color,
                              .paragraphStyle: paragraph],
                             range: whole)
        // Fuzzy matches arrive as bold runs; buffer-search snippets mark the
        // match with an underline and background color instead.
        source.enumerateAttributes(in: whole) { attributes, range, _ in
            let bold = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let marked = attributes[.underlineStyle] != nil || attributes[.backgroundColor] != nil
            guard bold || marked else {
                return
            }
            result.addAttributes([.font: matchFont,
                                  .foregroundColor: NSColor.controlAccentColor],
                                 range: range)
        }
        return result
    }
}

// MARK: - Preview pane

@objc(iTermOpenQuicklyPreviewFactKind)
enum OpenQuicklyPreviewFactKind: Int {
    case directory
    case command
    case host
    case profile
}

@objc(iTermOpenQuicklyPreviewFact)
final class OpenQuicklyPreviewFact: NSObject {
    @objc let kind: OpenQuicklyPreviewFactKind
    @objc let text: String

    @objc init(kind: OpenQuicklyPreviewFactKind, text: String) {
        self.kind = kind
        self.text = text
    }

    fileprivate var symbol: SFSymbol {
        switch kind {
        case .directory: return .folder
        case .command: return .terminal
        case .host: return .network
        case .profile: return .personCropCircle
        }
    }
}

// The right-hand side of the palette. Shows a large live snapshot of the
// highlighted session with where it lives (window, tab, pane) and what it's
// doing, or a description of a non-session item.
@objc(iTermOpenQuicklyPreviewPane)
final class OpenQuicklyPreviewPane: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let locationField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let snapshotFrame = NSView()
    private let snapshotView = NSImageView()
    private let factsStack = NSStackView()
    private let emptyField = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
        ])

        titleField.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.maximumNumberOfLines = 2
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        locationField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        locationField.textColor = .secondaryLabelColor
        locationField.lineBreakMode = .byTruncatingTail
        locationField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailField.font = NSFont.systemFont(ofSize: 13)
        detailField.textColor = .secondaryLabelColor
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        snapshotFrame.wantsLayer = true
        snapshotFrame.layer?.cornerRadius = 10
        snapshotFrame.layer?.masksToBounds = true
        snapshotFrame.layer?.borderWidth = 0.5
        snapshotFrame.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.imageScaling = .scaleProportionallyUpOrDown
        snapshotView.imageAlignment = .alignTop
        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        snapshotView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snapshotView.setContentHuggingPriority(.defaultLow, for: .vertical)
        snapshotFrame.addSubview(snapshotView)
        NSLayoutConstraint.activate([
            snapshotView.leadingAnchor.constraint(equalTo: snapshotFrame.leadingAnchor, constant: 10),
            snapshotView.trailingAnchor.constraint(equalTo: snapshotFrame.trailingAnchor, constant: -10),
            snapshotView.topAnchor.constraint(equalTo: snapshotFrame.topAnchor, constant: 10),
            snapshotView.bottomAnchor.constraint(equalTo: snapshotFrame.bottomAnchor, constant: -10),
        ])
        snapshotFrame.setContentHuggingPriority(.defaultLow, for: .vertical)

        factsStack.orientation = .vertical
        factsStack.alignment = .leading
        factsStack.spacing = 6

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [iconView, titleField, locationField, detailField, snapshotFrame, factsStack] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(14, after: iconView)
        stack.setCustomSpacing(2, after: titleField)
        stack.setCustomSpacing(14, after: locationField)
        stack.setCustomSpacing(14, after: snapshotFrame)
        addSubview(stack)

        emptyField.font = NSFont.systemFont(ofSize: 13)
        emptyField.textColor = .tertiaryLabelColor
        emptyField.alignment = .center
        emptyField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyField)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            snapshotFrame.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            locationField.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            factsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyField.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Let the snapshot take whatever vertical space the text doesn't.
        let fill = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        fill.priority = .defaultHigh
        fill.isActive = true

        showMessage("")
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    @objc func showSession(title: String,
                           location: String,
                           snapshot: NSImage?,
                           backgroundColor: NSColor?,
                           facts: [OpenQuicklyPreviewFact]) {
        stack.isHidden = false
        emptyField.isHidden = true
        iconView.isHidden = true
        detailField.isHidden = true

        titleField.stringValue = title
        locationField.stringValue = location
        locationField.isHidden = location.isEmpty

        snapshotView.image = snapshot
        snapshotFrame.isHidden = false
        snapshotFrame.layer?.backgroundColor = (backgroundColor ?? .black).cgColor
        snapshotFrame.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor

        setFacts(facts)
    }

    @objc func showItem(title: String, detail: String?, icon: NSImage?) {
        stack.isHidden = false
        emptyField.isHidden = true
        iconView.image = icon
        iconView.isHidden = (icon == nil)
        titleField.stringValue = title
        locationField.isHidden = true
        if let detail, !detail.isEmpty {
            detailField.stringValue = detail
            detailField.isHidden = false
        } else {
            detailField.isHidden = true
        }
        snapshotView.image = nil
        snapshotFrame.isHidden = true
        setFacts([])
    }

    @objc func showMessage(_ message: String) {
        stack.isHidden = true
        snapshotView.image = nil
        emptyField.stringValue = message
        emptyField.isHidden = message.isEmpty
    }

    private func setFacts(_ facts: [OpenQuicklyPreviewFact]) {
        for view in factsStack.arrangedSubviews {
            factsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        factsStack.isHidden = facts.isEmpty
        for fact in facts {
            let image = NSImageView(image: fact.symbol.nsimage)
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            image.contentTintColor = .tertiaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 16).isActive = true

            let label = NSTextField(labelWithString: fact.text)
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [image, label])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            factsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(lessThanOrEqualTo: factsStack.widthAnchor).isActive = true
        }
    }
}

// MARK: - Footer

// Key hints along the bottom edge: what Return, ⌘1–9, arrows, and esc do.
@objc(iTermOpenQuicklyHintBar)
final class OpenQuicklyHintBar: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let hints: [(String, String)] = [
            // Localization unneeded: key symbols.
            ("↩", String(localized: "OpenQuickly.Hint.Switch",
                         defaultValue: "Switch",
                         comment: "Open Quickly footer hint: pressing Return switches to the highlighted item")),
            ("⌘1–9", String(localized: "OpenQuickly.Hint.Jump",
                             defaultValue: "Jump to row",
                             comment: "Open Quickly footer hint: Command-1 through Command-9 open that row")),
            ("↑↓", String(localized: "OpenQuickly.Hint.Move",
                          defaultValue: "Move",
                          comment: "Open Quickly footer hint: arrow keys move the highlight")),
            ("esc", String(localized: "OpenQuickly.Hint.Close",
                           defaultValue: "Close",
                           comment: "Open Quickly footer hint: Escape closes the palette")),
        ]
        let groups: [NSView] = hints.map { key, text in
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11.5)
            label.textColor = .secondaryLabelColor
            let group = NSStackView(views: [OpenQuicklyKeycapView(text: key), label])
            group.orientation = .horizontal
            group.spacing = 6
            return group
        }
        let left = NSStackView(views: groups)
        left.orientation = .horizontal
        left.spacing = 18
        left.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)

        let tip = NSTextField(labelWithString: String(localized: "OpenQuickly.Hint.Commands",
                                                      defaultValue: "Type / for commands",
                                                      comment: "Open Quickly footer hint: typing a slash lists commands such as switching profiles"))
        tip.font = NSFont.systemFont(ofSize: 11.5)
        tip.textColor = .tertiaryLabelColor
        tip.translatesAutoresizingMaskIntoConstraints = false
        tip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(tip)

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            tip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            tip.centerYAnchor.constraint(equalTo: centerYAnchor),
            tip.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }
}
