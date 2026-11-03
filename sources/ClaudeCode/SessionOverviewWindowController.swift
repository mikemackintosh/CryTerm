//
//  SessionOverviewWindowController.swift
//  iTerm2SharedARC
//
//  Window > Session Overview (⌘J, next to Open Quickly's ⌘K): a grid of live
//  thumbnails of every session, each captioned with its status and what it's
//  doing (see SessionGlance), sorted so sessions that need you come first.
//  Type to filter by name, directory, command, or output; arrow keys move the
//  selection; Return, a click, or ⌘1–9 jumps to a session.
//
//  It shares Open Quickly's chrome (translucent rounded panel, borderless
//  query field, key-hint footer, tinted selection) so the two read as one
//  family.
//
//  Thumbnails are the cost here, so they are rendered lazily: a few per
//  runloop turn when the window opens, and afterwards only for visible tiles
//  whose session printed something since the last render. A session that sits
//  idle is rendered once.
//

import AppKit

@objc(iTermSessionOverviewWindowController)
final class SessionOverviewWindowController: NSWindowController {
    @objc static let shared = SessionOverviewWindowController()

    fileprivate struct Entry {
        let guid: String
        let title: String
        let status: String
        let statusColor: NSColor
        let summary: String?
        let lastLine: String?
        let searchText: String
        let terminalBackground: NSColor?
    }

    private struct Snapshot {
        let image: NSImage
        // The session's lastOutputTime when this was rendered.
        let outputTime: TimeInterval
    }

    private static let refreshInterval: TimeInterval = 2
    private static let snapshotsPerTurn = 4
    fileprivate static let tileSize = NSSize(width: 340, height: 270)
    private static let headerHeight = OpenQuicklyPaletteMetrics.headerHeight
    private static let footerHeight = OpenQuicklyPaletteMetrics.footerHeight
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("SessionOverviewTile")

    private let queryField = NSTextField()
    private let clearButton = NSButton()
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var entries: [Entry] = []
    private var snapshots: [String: Snapshot] = [:]
    private var pendingSnapshots: [String] = []
    private var snapshotDrainScheduled = false
    private var selectedGuid: String?
    private var timer: Timer?

    private init() {
        let panel = SessionOverviewPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                         styleMask: [.borderless],
                                         backing: .buffered,
                                         defer: true)
        panel.title = String(localized: "SessionOverview.Title", defaultValue: "Session Overview", comment: "Accessibility title of the window showing a thumbnail of every terminal session")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        super.init(window: panel)
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        buildContent(in: panel)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) is not supported")
    }

    // MARK: - Showing

    @objc func show() {
        guard let window else { return }
        if !window.isVisible {
            sizeToScreen(window)
            queryField.stringValue = ""
            clearButton.isHidden = true
        }
        reload()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(queryField)
        startTimer()
    }

    private func dismiss() {
        window?.orderOut(nil)
        timer?.invalidate()
        timer = nil
        pendingSnapshots.removeAll()
    }

    // Most of the active screen, so many tiles fit at once.
    private func sizeToScreen(_ window: NSWindow) {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: floor(min(visible.width * 0.86, 1700)),
                          height: floor(visible.height * 0.84))
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self, let window = self.window,
                  window.isVisible, window.occlusionState.contains(.visible) else {
                return
            }
            self.reload()
        }
        timer.tolerance = Self.refreshInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Building the window

    private func buildContent(in window: NSWindow) {
        let background = OpenQuicklyPaletteBackgroundView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = background
        let content = background.contentView

        let loupe = NSImageView()
        loupe.image = NSImage(systemSymbolName: SFSymbol.magnifyingglass.rawValue,
                              accessibilityDescription: String(localized: "SessionOverview.SearchIconAccessibility", defaultValue: "Search icon", comment: "Accessibility description for the Session Overview search icon"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        loupe.contentTintColor = .secondaryLabelColor

        queryField.isBezeled = false
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.font = .systemFont(ofSize: 21)
        queryField.textColor = .labelColor
        queryField.cell?.isScrollable = true
        queryField.cell?.usesSingleLineMode = true
        queryField.cell?.lineBreakMode = .byClipping
        queryField.placeholderString = String(localized: "SessionOverview.SearchPlaceholder", defaultValue: "Filter sessions by name, directory, command, or output", comment: "Placeholder in the Session Overview search field")
        queryField.delegate = self

        clearButton.image = NSImage(systemSymbolName: SFSymbol.xmarkCircleFill.rawValue,
                                    accessibilityDescription: String(localized: "SessionOverview.ClearAccessibility", defaultValue: "Clear filter", comment: "Accessibility description for the Session Overview clear-filter button"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        clearButton.isBordered = false
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearQuery(_:))
        clearButton.isHidden = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.tileSize
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(SessionOverviewItem.self, forItemWithIdentifier: Self.itemIdentifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel.stringValue = String(localized: "SessionOverview.NoMatches", defaultValue: "No matches", comment: "Shown in Session Overview when the filter matches no session")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true

        let headerSeparator = OpenQuicklySeparatorView(frame: .zero)
        let footerSeparator = OpenQuicklySeparatorView(frame: .zero)
        let footer = OpenQuicklyHintBar(
            hints: [
                // Localization unneeded: key symbols.
                ("↩", String(localized: "SessionOverview.Hint.Switch", defaultValue: "Switch", comment: "Session Overview footer hint: Return switches to the selected session")),
                ("⌘1–9", String(localized: "SessionOverview.Hint.Jump", defaultValue: "Jump to tile", comment: "Session Overview footer hint: Command-1 through Command-9 jump to that session")),
                ("←↑↓→", String(localized: "SessionOverview.Hint.Move", defaultValue: "Move", comment: "Session Overview footer hint: arrow keys move the selection")),
                ("esc", String(localized: "SessionOverview.Hint.Close", defaultValue: "Close", comment: "Session Overview footer hint: Escape closes the window")),
            ],
            tip: String(localized: "SessionOverview.Hint.Order", defaultValue: "Sessions waiting for you come first", comment: "Session Overview footer note explaining the sort order"))

        for view in [loupe, queryField, clearButton, headerSeparator, scrollView, emptyLabel, footerSeparator, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            loupe.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            loupe.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight / 2),
            loupe.widthAnchor.constraint(equalToConstant: 22),

            queryField.leadingAnchor.constraint(equalTo: loupe.trailingAnchor, constant: 12),
            queryField.centerYAnchor.constraint(equalTo: loupe.centerYAnchor),
            queryField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -10),

            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            clearButton.centerYAnchor.constraint(equalTo: loupe.centerYAnchor),

            headerSeparator.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            headerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
    }

    @objc private func clearQuery(_ sender: Any?) {
        queryField.stringValue = ""
        clearButton.isHidden = true
        reload()
        window?.makeFirstResponder(queryField)
    }

    // MARK: - Model

    private func allSessions() -> [PTYSession] {
        guard let controller = iTermController.sharedInstance() else { return [] }
        let buried = iTermBuriedSessions.sharedInstance().buriedSessions() ?? []
        return controller.allSessions() + buried
    }

    private func makeEntries(from sessions: [PTYSession]) -> [Entry] {
        let needle = queryField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var keyed: [(priority: Int, order: Int, entry: Entry)] = []
        for (order, session) in sessions.enumerated() {
            let glance = SessionGlance(session: session)
            let status = glance.displayStatus(of: session)
            let title = session.name.isEmpty ? session.guid : session.name
            let entry = Entry(guid: session.guid,
                              title: title,
                              status: status.text,
                              statusColor: status.color,
                              summary: glance.summary(),
                              lastLine: glance.lastLine,
                              searchText: (title + "\n" + glance.searchableText).lowercased(),
                              terminalBackground: session.processedBackgroundColor)
            if !needle.isEmpty && !entry.searchText.contains(needle) {
                continue
            }
            keyed.append((SessionGlance.priority(forStatus: status.text), order, entry))
        }
        keyed.sort { ($0.priority, $0.order) < ($1.priority, $1.order) }
        return keyed.map(\.entry)
    }

    private func reload() {
        let sessions = allSessions()
        let newEntries = makeEntries(from: sessions)
        let liveGuids = Set(sessions.map(\.guid))
        snapshots = snapshots.filter { liveGuids.contains($0.key) }
        let sameTiles = newEntries.map(\.guid) == entries.map(\.guid)
        entries = newEntries
        if sameTiles {
            // Same tiles in the same order: update captions in place so the
            // grid doesn't flash or lose its scroll position.
            reconfigureVisibleItems()
        } else {
            collectionView.reloadData()
        }
        emptyLabel.isHidden = !entries.isEmpty
        if selectedGuid == nil || !entries.contains(where: { $0.guid == selectedGuid }) {
            selectedGuid = entries.first?.guid
        }
        applySelection(scroll: false)
        queueStaleSnapshots()
    }

    private func reconfigureVisibleItems() {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            configure(collectionView.item(at: indexPath) as? SessionOverviewItem, at: indexPath.item)
        }
    }

    // MARK: - Thumbnails

    // Visible tiles with no thumbnail yet, or whose session printed since
    // the last one.
    private func queueStaleSnapshots() {
        let visible = collectionView.indexPathsForVisibleItems()
            .map(\.item)
            .sorted()
            .compactMap { $0 < entries.count ? entries[$0].guid : nil }
        let controller = iTermController.sharedInstance()
        for guid in visible where !pendingSnapshots.contains(guid) {
            guard let session = controller?.anySession(withGUID: guid) else { continue }
            if let existing = snapshots[guid], existing.outputTime >= session.lastOutputTime {
                continue
            }
            pendingSnapshots.append(guid)
        }
        scheduleSnapshotDrain()
    }

    private func scheduleSnapshotDrain() {
        guard !snapshotDrainScheduled, !pendingSnapshots.isEmpty else { return }
        snapshotDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainSnapshots()
        }
    }

    // A few per runloop turn, so opening the window with fifty sessions
    // doesn't stall typing in the query field.
    private func drainSnapshots() {
        snapshotDrainScheduled = false
        guard window?.isVisible == true else {
            pendingSnapshots.removeAll()
            return
        }
        let batch = pendingSnapshots.prefix(Self.snapshotsPerTurn)
        pendingSnapshots.removeFirst(batch.count)
        let controller = iTermController.sharedInstance()
        for guid in batch {
            guard let session = controller?.anySession(withGUID: guid) else { continue }
            let outputTime = session.lastOutputTime
            guard let image = session.terminalContentSnapshot() else { continue }
            snapshots[guid] = Snapshot(image: Self.thumbnail(of: image, size: SessionOverviewTileView.snapshotSize),
                                       outputTime: outputTime)
            if let index = entries.firstIndex(where: { $0.guid == guid }) {
                configure(collectionView.item(at: IndexPath(item: index, section: 0)) as? SessionOverviewItem, at: index)
            }
        }
        scheduleSnapshotDrain()
    }

    // Scale the terminal to the thumbnail's width and, when that makes it
    // taller than the thumbnail, keep the bottom: the newest output and the
    // prompt are what identify a session. Only a tile-sized bitmap is kept,
    // since fifty full-window renders would hold hundreds of megabytes.
    static func thumbnail(of image: NSImage, size: NSSize) -> NSImage {
        guard image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 else {
            return image
        }
        let scale = size.width / image.size.width
        let scaledHeight = image.size.height * scale
        let height = min(size.height, scaledHeight)
        let outputSize = NSSize(width: size.width, height: round(height))
        let backing: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(outputSize.width * backing),
                                         pixelsHigh: Int(outputSize.height * backing),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            return image
        }
        rep.size = outputSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // Unflipped coordinates: drawing at y = 0 with the full scaled height
        // keeps the image's bottom and lets the top run off the canvas.
        image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: scaledHeight))
        let result = NSImage(size: outputSize)
        result.addRepresentation(rep)
        return result
    }

    // MARK: - Selection

    private func configure(_ item: SessionOverviewItem?, at index: Int) {
        guard let item, index < entries.count else { return }
        let entry = entries[index]
        item.tile.configure(entry: entry,
                            image: snapshots[entry.guid]?.image,
                            selected: entry.guid == selectedGuid,
                            shortcutNumber: index < 9 ? index + 1 : nil)
        item.onClick = { [weak self] in
            self?.activate(guid: entry.guid)
        }
    }

    private func applySelection(scroll: Bool) {
        reconfigureVisibleItems()
        guard scroll, let index = entries.firstIndex(where: { $0.guid == selectedGuid }) else {
            return
        }
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)],
                                     scrollPosition: .nearestHorizontalEdge)
    }

    private var columnCount: Int {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return 1 }
        let usable = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
        let stride = layout.itemSize.width + layout.minimumInteritemSpacing
        return max(1, Int((usable + layout.minimumInteritemSpacing) / stride))
    }

    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex(where: { $0.guid == selectedGuid }) ?? 0
        let next = min(max(0, current + delta), entries.count - 1)
        selectedGuid = entries[next].guid
        applySelection(scroll: true)
        queueStaleSnapshots()
    }

    // ⌘1 through ⌘9 jump to that tile, as they do to rows in Open Quickly.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad) == .command,
              let characters = event.charactersIgnoringModifiers,
              let digit = Int(characters), (1...9).contains(digit) else {
            return false
        }
        guard digit <= entries.count else {
            NSSound.beep()
            return true
        }
        activate(guid: entries[digit - 1].guid)
        return true
    }

    private func activate(guid: String) {
        guard let session = iTermController.sharedInstance()?.anySession(withGUID: guid) else { return }
        dismiss()
        session.reveal()
    }
}

// MARK: - Window and query field

extension SessionOverviewWindowController: NSWindowDelegate, NSTextFieldDelegate {
    // Like Open Quickly: clicking anywhere else dismisses it.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func controlTextDidChange(_ obj: Notification) {
        clearButton.isHidden = queryField.stringValue.isEmpty
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveLeft(_:)) where textView.string.isEmpty:
            moveSelection(by: -1)
        case #selector(NSResponder.moveRight(_:)) where textView.string.isEmpty:
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -columnCount)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: columnCount)
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if let selectedGuid {
                activate(guid: selectedGuid)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            if textView.string.isEmpty {
                dismiss()
            } else {
                clearQuery(nil)
            }
        default:
            return false
        }
        return true
    }
}

// MARK: - Collection view

extension SessionOverviewWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return entries.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        configure(item as? SessionOverviewItem, at: indexPath.item)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        queueStaleSnapshots()
    }
}

// MARK: - Panel

// Borderless, so it needs to opt in to becoming key for the query field.
private final class SessionOverviewPanel: NSPanel {
    // Gets first refusal on key equivalents (⌘1–9) before the main menu.
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Tile

private final class SessionOverviewItem: NSCollectionViewItem {
    let tile = SessionOverviewTileView()
    var onClick: (() -> Void)?

    override func loadView() {
        view = tile
        tile.onClick = { [weak self] in self?.onClick?() }
    }
}

private final class SessionOverviewTileView: NSView {
    var onClick: (() -> Void)?

    private static let padding: CGFloat = 10
    private static let captionHeight: CGFloat = 64
    // The thumbnail's area inside a tile.
    static var snapshotSize: NSSize {
        let tile = SessionOverviewWindowController.tileSize
        return NSSize(width: tile.width - padding * 2 - 12,
                      height: tile.height - padding - captionHeight - 12)
    }

    private let snapshotFrame = NSView()
    private let imageView = NSImageView()
    private let dot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let summaryField = NSTextField(labelWithString: "")
    private let outputField = NSTextField(labelWithString: "")
    // ⌘1 through ⌘9 on the first nine tiles, as on Open Quickly's rows.
    private let keycap = OpenQuicklyKeycapView(text: "")
    private var isSelected = false
    private var terminalBackground: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        snapshotFrame.wantsLayer = true
        snapshotFrame.layer?.cornerRadius = 10
        snapshotFrame.layer?.masksToBounds = true
        snapshotFrame.layer?.borderWidth = 0.5
        addSubview(snapshotFrame)

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignBottom
        snapshotFrame.addSubview(imageView)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        titleField.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleField.textColor = .labelColor
        statusField.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusField.alignment = .right
        summaryField.font = .systemFont(ofSize: 11.5)
        summaryField.textColor = .secondaryLabelColor
        outputField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        outputField.textColor = .tertiaryLabelColor
        for field in [titleField, statusField, summaryField, outputField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(field)
        }

        // Over the thumbnail's top-right corner, where it doesn't compete
        // with the caption's status word.
        keycap.isHidden = true
        addSubview(keycap)
        NSLayoutConstraint.activate([
            keycap.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding + 8),
            keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.padding + 8)),
        ])
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    fileprivate func configure(entry: SessionOverviewWindowController.Entry,
                               image: NSImage?,
                               selected: Bool,
                               shortcutNumber: Int?) {
        if let shortcutNumber {
            // Localization unneeded: a key symbol and a digit.
            keycap.text = "⌘\(shortcutNumber)"
            keycap.isHidden = false
        } else {
            keycap.isHidden = true
        }
        titleField.stringValue = entry.title
        statusField.stringValue = entry.status
        statusField.textColor = entry.statusColor
        dot.layer?.backgroundColor = entry.statusColor.cgColor
        summaryField.stringValue = entry.summary ?? ""
        outputField.stringValue = entry.lastLine ?? ""
        imageView.image = image
        terminalBackground = entry.terminalBackground
        isSelected = selected
        toolTip = [entry.title, entry.summary, entry.lastLine].compactMap { $0 }.joined(separator: "\n")
        needsDisplay = true
        needsLayout = true
    }

    // The same tinted selection as an Open Quickly row; unselected tiles get
    // just enough fill to read as cards on the translucent panel.
    override func updateLayer() {
        layer?.cornerRadius = 12
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            layer?.borderWidth = 0.5
        }
        snapshotFrame.layer?.backgroundColor = (terminalBackground ?? .textBackgroundColor).cgColor
        snapshotFrame.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func layout() {
        super.layout()
        let pad = Self.padding
        let width = bounds.width
        snapshotFrame.frame = NSRect(x: pad, y: pad,
                                     width: width - pad * 2,
                                     height: bounds.height - pad - Self.captionHeight)
        imageView.frame = snapshotFrame.bounds.insetBy(dx: 6, dy: 6)

        var y = bounds.height - Self.captionHeight + 8
        let statusWidth = ceil(statusField.attributedStringValue.size().width) + 4
        dot.frame = NSRect(x: pad + 2, y: y + 6, width: 8, height: 8)
        titleField.frame = NSRect(x: pad + 16, y: y,
                                  width: max(0, width - pad * 2 - 16 - statusWidth - 8),
                                  height: 19)
        statusField.frame = NSRect(x: width - pad - statusWidth, y: y + 2, width: statusWidth, height: 16)
        y += 20
        summaryField.frame = NSRect(x: pad + 2, y: y, width: width - pad * 2 - 4, height: 16)
        y += 17
        outputField.frame = NSRect(x: pad + 2, y: y, width: width - pad * 2 - 4, height: 15)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    // Clicks go to the tile, not the image view or labels inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point) == nil ? nil : self
    }
}
