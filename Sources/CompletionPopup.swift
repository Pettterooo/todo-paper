import AppKit

/// Floating, keyboard-driven tag completion shown while typing an `@tag`.
final class CompletionController: NSObject {
    private weak var textView: OutlineTextView?
    private let panel = CompletionPanel()
    private let cardView = CompletionCardView()
    private let tableView = CompletionTableView()
    private let scrollView = NSScrollView()
    private let effectView = NSVisualEffectView()

    private var candidates: [String] = []
    private var context: NSRange?
    private var selectedTag: String?
    private var suppressCaret: Int?
    private var isAccepting = false
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel.isVisible }

    func attach(to textView: OutlineTextView) {
        self.textView = textView

        panel.contentView = cardView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // A borderless window's system shadow is always rectangular. Drawing the
        // shadow ourselves is the only way to keep the rounded silhouette.
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        cardView.wantsLayer = true
        cardView.layer?.shadowColor = NSColor.black.cgColor
        cardView.layer?.shadowOpacity = 0.12
        cardView.layer?.shadowRadius = 16
        cardView.layer?.shadowOffset = CGSize(width: 0, height: -3)

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = CompletionCardView.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        effectView.autoresizingMask = [.width, .height]
        cardView.addSubview(effectView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onPick = { [weak self] row in
            self?.accept(row: row)
        }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.autoresizingMask = [.width, .height]
        effectView.addSubview(scrollView)

        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.hide() })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hide() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hide() })
    }

    /// Tear down the panel when its editor view is discarded: remove it from the
    /// parent window before that window starts closing.
    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        if panel.isVisible {
            panel.orderOut(nil)
        }
        textView = nil
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: context

    private func tagContext() -> (range: NSRange, prefix: String)? {
        guard let textView else { return nil }
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location <= ns.length else { return nil }

        var index = selection.location
        while index > 0, Self.isTagCharacter(ns.character(at: index - 1)) {
            index -= 1
        }
        guard index > 0, Self.isAtSign(ns.character(at: index - 1)) else { return nil }

        let atLocation = index - 1
        let prefix = ns.substring(with: NSRange(location: index, length: selection.location - index))
        return (NSRange(location: atLocation, length: selection.location - atLocation), prefix)
    }

    /// ASCII `@` plus the full-width `＠` that Chinese input methods emit.
    private static func isAtSign(_ value: unichar) -> Bool {
        value == 0x40 || value == 0xFF20
    }

    private static func isTagCharacter(_ value: unichar) -> Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            || (value >= 0x30 && value <= 0x39) || value == 0x5F || value == 0x2D
    }

    private func candidates(for prefix: String) -> [String] {
        var seen = Set<String>()
        let known = (["done", "due", "start", "today", "tags"] + (textView?.docTags ?? []))
            .filter { seen.insert($0.lowercased()).inserted }
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return known }
        // The token being typed already parses as a tag; don't suggest it back to itself.
        let usable = known.filter { $0.lowercased() != needle }
        let starting = usable.filter { $0.lowercased().hasPrefix(needle) }
        let containing = usable.filter { !starting.contains($0) && $0.lowercased().contains(needle) }
        return starting + containing
    }

    // MARK: presentation

    private var refreshScheduled = false

    /// Coalesces refresh requests into the next runloop turn so TextKit 2 has a
    /// chance to lay the edited text out before we read caret geometry.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard !isAccepting, let textView, textView.window != nil else { return }
        let caret = textView.selectedRange()
        if let suppressCaret {
            if caret.location == suppressCaret { hide(); return }
            self.suppressCaret = nil
        }
        guard let context = tagContext() else {
            hide()
            return
        }
        let matches = candidates(for: context.prefix)
        guard !matches.isEmpty else {
            hide()
            return
        }

        self.context = context.range
        self.candidates = matches
        guard let frame = panelFrame() else { hide(); return }

        let previous = selectedTag
        if let previous, matches.contains(previous) {
            selectedTag = previous
        } else {
            selectedTag = matches.first
        }

        tableView.reloadData()
        let row = matches.firstIndex(of: selectedTag ?? "") ?? 0
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)

        if panel.parent == nil, let parent = textView.window {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.setFrame(frame, display: true)
        layoutChrome()
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func layoutChrome() {
        let margin = CompletionCardView.margin
        let card = cardView.bounds.insetBy(dx: margin, dy: margin)
        effectView.frame = card
        scrollView.frame = effectView.bounds.insetBy(dx: 4, dy: 4)
        cardView.layer?.shadowPath = CGPath(roundedRect: card,
                                            cornerWidth: CompletionCardView.cornerRadius,
                                            cornerHeight: CompletionCardView.cornerRadius,
                                            transform: nil)
    }

    func hide() {
        context = nil
        candidates = []
        selectedTag = nil
        guard panel.isVisible else { return }
        // While the parent window is tearing down, the child panel follows it;
        // ordering the panel out here would queue window work during dealloc.
        guard let window = textView?.window, window.isVisible else { return }
        panel.orderOut(nil)
    }

    private func panelFrame() -> NSRect? {
        guard let textView, let window = textView.window else { return nil }
        guard let caret = caretScreenRect(for: textView) else { return nil }

        let font = NSFont.systemFont(ofSize: 13)
        let widest = candidates.map {
            ("@" + $0).size(withAttributes: [.font: font]).width
        }.max() ?? 90
        let width = min(max(widest + 34, 132), 300)
        let rows = min(candidates.count, 7)
        let height = CGFloat(rows) * tableView.rowHeight + 8
        let margin = CompletionCardView.margin

        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? caret

        var origin = NSPoint(x: caret.minX, y: caret.minY - 8 - height)
        if origin.y < visible.minY + margin {
            origin.y = caret.maxY + 8
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - width - margin)
        origin.y = min(origin.y, visible.maxY - height - margin)

        let column = tableView.tableColumns.first
        column?.width = width - 8
        // The window carries a transparent margin so the rounded layer shadow
        // has room to render; the visible card is the inner rect.
        return NSRect(x: origin.x - margin, y: origin.y - margin,
                      width: width + margin * 2, height: height + margin * 2)
    }

    private func caretScreenRect(for textView: OutlineTextView) -> NSRect? {
        guard let window = textView.window,
              let layout = textView.textLayoutManager,
              let storage = textView.textContentStorage else { return nil }

        let ns = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location <= ns.length else { return nil }

        layout.ensureLayout(for: layout.documentRange)

        let probeIndex = caret.location == ns.length ? max(0, caret.location - 1) : caret.location
        guard let probe = storage.location(storage.documentRange.location, offsetBy: probeIndex),
              let fragment = layout.textLayoutFragment(for: probe) else { return nil }
        let fragmentOffset = storage.offset(from: storage.documentRange.location,
                                            to: fragment.rangeInElement.location)
        guard fragmentOffset != NSNotFound else { return nil }

        for line in fragment.textLineFragments {
            let lineStart = fragmentOffset + line.characterRange.location
            let lineEnd = lineStart + line.characterRange.length
            guard caret.location >= lineStart, caret.location <= lineEnd else { continue }

            let local = caret.location - lineStart
            let x: CGFloat
            if local < line.characterRange.length {
                x = line.locationForCharacter(at: local).x
            } else if line.characterRange.length > 0 {
                let last = line.locationForCharacter(at: line.characterRange.length - 1)
                let lastWidth = line.attributedString
                    .attributedSubstring(from: NSRange(location: line.characterRange.length - 1, length: 1))
                    .size().width
                x = last.x + lastWidth
            } else {
                x = 0
            }

            let frame = fragment.layoutFragmentFrame
            let bounds = line.typographicBounds
            let viewRect = NSRect(x: textView.textContainerOrigin.x + frame.minX + x,
                                  y: textView.textContainerOrigin.y + frame.minY + bounds.minY,
                                  width: 0, height: bounds.height)
            return window.convertToScreen(textView.convert(viewRect, to: nil))
        }
        return nil
    }

    // MARK: keyboard

    /// Returns true when the event was consumed by the completion list.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 126: // up
            moveSelection(by: -1)
            return true
        case 125: // down
            moveSelection(by: 1)
            return true
        case 36, 76: // return, enter
            accept(row: tableView.selectedRow)
            return true
        case 48: // tab
            if event.modifierFlags.contains(.shift) {
                hide()
                return false
            }
            accept(row: tableView.selectedRow)
            return true
        case 53: // escape
            hide()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = (current + delta + candidates.count) % candidates.count
        selectedTag = candidates[next]
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: accepting

    func accept(row: Int) {
        guard isVisible, let textView, let context, row >= 0, row < candidates.count else {
            hide()
            return
        }
        let name = candidates[row]
        let tag = "@" + name
        guard textView.shouldChangeText(in: context, replacementString: tag) else {
            hide()
            return
        }
        isAccepting = true
        let newCaret = context.location + (tag as NSString).length
        textView.textStorage?.replaceCharacters(in: context, with: tag)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.didChangeText()
        isAccepting = false
        suppressCaret = newCaret
        hide()

        if name.lowercased() == "due" {
            textView.presentDueDate(for: NSRange(location: context.location, length: (tag as NSString).length))
        }
    }
}

extension CompletionController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < candidates.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TagCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = "@" + candidates[row]
        return cell
    }
}

final class CompletionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

final class CompletionCardView: NSView {
    static let cornerRadius: CGFloat = 10
    static let margin: CGFloat = 20
}

final class CompletionTableView: NSTableView {
    var onPick: ((Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onPick?(row)
            return
        }
        super.mouseDown(with: event)
    }
}

final class CompletionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        // Never let macOS window restoration resurrect this transient panel:
        // a restored orphan panel tears down without a controller and crashes.
        isRestorable = false
        level = .floating
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
