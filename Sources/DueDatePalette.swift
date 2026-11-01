import AppKit

/// Floating due-date palette modelled on TaskPaper's "Due Date" window:
/// an editable date phrase, a month calendar, and a live @due(...) preview.
final class DueDateController: NSObject {
    static let cardSize = NSSize(width: 353, height: 203)
    static let margin: CGFloat = 24

    private weak var textView: OutlineTextView?
    private let panel = DueDatePanel()
    private let rootView = DueDateRootView()
    private let effectView = NSVisualEffectView()
    private let titleField = DueTitleField()
    private let calendarView = NSDatePicker()
    private let previewField = NSTextField(labelWithString: "")
    private let headerDivider = NSBox()
    private let columnDivider = NSBox()

    private var tokenRange: NSRange?
    private var chosenDate = Calendar.current.startOfDay(for: Date())
    private var cancelledToken: NSRange?
    private var isClosing = false
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel.isVisible }

    // MARK: setup

    func attach(to textView: OutlineTextView) {
        self.textView = textView

        panel.contentView = rootView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Same rounded-shadow trick as the completion list: a borderless window's
        // system shadow is rectangular, so the card draws its own.
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        rootView.wantsLayer = true
        rootView.layer?.shadowColor = NSColor.black.cgColor
        rootView.layer?.shadowOpacity = 0.14
        rootView.layer?.shadowRadius = 18
        rootView.layer?.shadowOffset = CGSize(width: 0, height: -4)

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = DueDateRootView.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        rootView.addSubview(effectView)

        titleField.delegate = self
        titleField.placeholderAttributedString = NSAttributedString(
            string: "Due Date",
            attributes: [
                .font: NSFont.systemFont(ofSize: 22),
                .foregroundColor: NSColor.tertiaryLabelColor
            ])
        titleField.font = .systemFont(ofSize: 22)
        titleField.textColor = .labelColor
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        effectView.addSubview(titleField)

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendarView.calendar = calendar
        calendarView.locale = Locale(identifier: "en_US")
        calendarView.datePickerStyle = .clockAndCalendar
        calendarView.datePickerElements = [.yearMonthDay]
        calendarView.datePickerMode = .single
        calendarView.dateValue = chosenDate
        calendarView.isBordered = false
        calendarView.drawsBackground = false
        calendarView.target = self
        calendarView.action = #selector(calendarChanged)
        effectView.addSubview(calendarView)

        previewField.font = .systemFont(ofSize: 13)
        previewField.textColor = .secondaryLabelColor
        previewField.alignment = .center
        previewField.lineBreakMode = .byTruncatingTail
        effectView.addSubview(previewField)

        headerDivider.boxType = .separator
        effectView.addSubview(headerDivider)
        columnDivider.boxType = .separator
        effectView.addSubview(columnDivider)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isClosing, self.panel.isVisible else { return }
            self.close(restoreFocus: false)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            self.close(restoreFocus: false)
        })
    }

    /// Tear down the panel when its editor view is discarded: remove it from the
    /// parent window before that window starts closing.
    func detach() {
        removeKeyMonitor()
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
        removeKeyMonitor()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func layoutChrome() {
        let margin = DueDateController.margin
        let card = rootView.bounds.insetBy(dx: margin, dy: margin)
        // Subviews live inside the card, in card coordinates.
        effectView.frame = card
        rootView.layer?.shadowPath = CGPath(roundedRect: card,
                                            cornerWidth: DueDateRootView.cornerRadius,
                                            cornerHeight: DueDateRootView.cornerRadius,
                                            transform: nil)

        let size = DueDateController.cardSize
        let headerHeight: CGFloat = 41
        // NSTextField centers the line box, but "Due Date" has no descenders, so the
        // glyphs sit visually high. Nudged 2pt down to match TaskPaper's header balance.
        titleField.frame = NSRect(x: 12, y: size.height - headerHeight + 3,
                                  width: size.width - 24, height: 31)
        headerDivider.frame = NSRect(x: 0, y: size.height - headerHeight,
                                     width: size.width, height: 1)
        let bodyHeight = size.height - headerHeight
        calendarView.frame = NSRect(x: 8, y: 4, width: 141, height: bodyHeight - 8)
        columnDivider.frame = NSRect(x: 157, y: 0, width: 1, height: bodyHeight)
        previewField.frame = NSRect(x: 158, y: (bodyHeight - 22) / 2,
                                    width: size.width - 158, height: 22)
    }

    // MARK: presentation

    func present(tokenRange: NSRange, defaultDate: Date?, in textView: OutlineTextView) {
        guard textView.window != nil else { return }
        if isVisible, self.tokenRange == tokenRange { return }
        self.textView = textView
        self.tokenRange = tokenRange
        cancelledToken = nil
        chosenDate = Calendar.current.startOfDay(for: defaultDate ?? Date())

        titleField.stringValue = ""
        calendarView.dateValue = chosenDate
        updatePreview()

        textView.completion?.hide()
        if let parent = textView.window, panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        guard let frame = panelFrame() else { return }
        panel.setFrame(frame, display: false)
        layoutChrome()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(titleField)
        installKeyMonitor()
    }

    private func panelFrame() -> NSRect? {
        guard let textView, let window = textView.window, let range = tokenRange else { return nil }
        guard let caret = textView.caretScreenRect(at: NSMaxRange(range)) else { return nil }

        let size = DueDateController.cardSize
        let margin = DueDateController.margin
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? caret

        // TaskPaper centres the palette over the editor window, hanging it just
        // below the line being edited.
        var origin = NSPoint(x: window.frame.midX - size.width / 2,
                             y: caret.minY - 8 - size.height)
        if origin.y < visible.minY + margin {
            origin.y = caret.maxY + 8
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)

        return NSRect(x: origin.x - margin, y: origin.y - margin,
                      width: size.width + margin * 2, height: size.height + margin * 2)
    }

    // MARK: triggers from the editor

    /// Called after text was typed/pasted into the editor. A bare `@due`
    /// followed by a space or an opening paren opens the palette; so does a
    /// pasted chunk that ends with `@due`.
    func editorInserted(_ inserted: String) {
        guard !isVisible, let textView, textView.window != nil else { return }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        let insertedNS = inserted as NSString
        guard insertedNS.length > 0, caret > 0, caret <= ns.length else { return }

        let last = insertedNS.character(at: insertedNS.length - 1)

        if insertedNS.length >= 4, caret >= 4, last != 0x20, last != 0x28 {
            let tailStart = caret - 4
            let tail = ns.substring(with: NSRange(location: tailStart, length: 4)).lowercased()
            if tail == "@due", isTokenStart(tailStart, in: ns) {
                schedulePresent(NSRange(location: tailStart, length: 4))
                return
            }
        }

        guard last == 0x20 || last == 0x28, caret >= 5 else { return }
        let tokenStart = caret - 5
        let token = ns.substring(with: NSRange(location: tokenStart, length: 4)).lowercased()
        guard token == "@due", isTokenStart(tokenStart, in: ns) else { return }
        let length = last == 0x28 ? 5 : 4
        schedulePresent(NSRange(location: tokenStart, length: length))
    }

    /// TaskPaper picks tags up anywhere in a line, so any boundary that is not
    /// part of another tag/word starts a token.
    private func isTokenStart(_ index: Int, in ns: NSString) -> Bool {
        guard index > 0 else { return true }
        let before = ns.character(at: index - 1)
        let isWord = (before >= 0x41 && before <= 0x5A)
            || (before >= 0x61 && before <= 0x7A)
            || (before >= 0x30 && before <= 0x39)
        return !isWord && before != 0x5F && before != 0x2D && before != 0x40
    }

    private func schedulePresent(_ range: NSRange) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView, !self.isVisible, textView.window != nil else { return }
            if let cancelled = self.cancelledToken, NSEqualRanges(cancelled, range) { return }
            let caret = textView.selectedRange()
            let end = NSMaxRange(range)
            guard caret.location == end || (caret.location == end + 1 && end < textView.string.count) else { return }
            let ns = textView.string as NSString
            guard end <= ns.length, range.location >= 0,
                  ns.substring(with: NSRange(location: range.location, length: 4)).lowercased() == "@due" else { return }
            self.present(tokenRange: range, defaultDate: nil, in: textView)
        }
    }

    // MARK: actions

    @objc private func calendarChanged() {
        chosenDate = Calendar.current.startOfDay(for: calendarView.dateValue)
        titleField.stringValue = Self.isoString(chosenDate)
        updatePreview()
    }

    private func updatePreview() {
        previewField.stringValue = "@due(\(Self.isoString(chosenDate)))"
    }

    func commit() {
        guard let textView, let range = tokenRange else {
            close(restoreFocus: true)
            return
        }
        let tag = "@due(\(Self.isoString(chosenDate)))"
        var replaceRange = range
        let ns = textView.string as NSString
        // A user who typed "@due(" already has the opening paren at the end.
        if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == 0x29 {
            replaceRange.length += 1
        }
        guard NSMaxRange(replaceRange) <= ns.length,
              textView.shouldChangeText(in: replaceRange, replacementString: tag) else {
            close(restoreFocus: true)
            return
        }
        textView.textStorage?.replaceCharacters(in: replaceRange, with: tag)
        let caret = replaceRange.location + (tag as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.didChangeText()
        close(restoreFocus: true)
    }

    func cancel() {
        if let range = tokenRange { cancelledToken = range }
        close(restoreFocus: true)
    }

    private func close(restoreFocus: Bool) {
        guard !isClosing else { return }
        isClosing = true
        removeKeyMonitor()
        let parent = textView?.window
        let parentAlive = parent?.isVisible == true
        if parentAlive {
            panel.orderOut(nil)
            if let parent, panel.parent === parent {
                parent.removeChildWindow(panel)
            }
        }
        tokenRange = nil
        isClosing = false
        if restoreFocus, let textView, let parent, parentAlive {
            parent.makeKey()
            parent.makeFirstResponder(textView)
        }
    }

    // MARK: keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: // escape
                self.cancel()
                return nil
            case 36, 76: // return, enter
                self.commit()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: date phrases

    static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func isoString(_ date: Date) -> String { isoFormatter.string(from: date) }

    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7
    ]

    static func parse(_ text: String, base: Date = Date()) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: base)

        if raw == "today" { return today }
        if raw == "tomorrow" { return calendar.date(byAdding: .day, value: 1, to: today) }
        if raw == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: today) }

        if raw.hasPrefix("+") {
            let body = raw.dropFirst()
            let digits = body.prefix { $0.isNumber }
            if let count = Int(digits), count > 0 {
                let unit = body.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
                switch unit {
                case "", "d", "day", "days":
                    return calendar.date(byAdding: .day, value: count, to: today)
                case "w", "week", "weeks":
                    return calendar.date(byAdding: .day, value: count * 7, to: today)
                case "m", "month", "months":
                    return calendar.date(byAdding: .month, value: count, to: today)
                case "y", "year", "years":
                    return calendar.date(byAdding: .year, value: count, to: today)
                default:
                    return nil
                }
            }
        }

        var weekdayText = raw
        let forceNext = weekdayText.hasPrefix("next ")
        if forceNext || weekdayText.hasPrefix("this ") {
            weekdayText = String(weekdayText.drop(while: { $0 != " " }).dropFirst())
        }
        if let target = weekdays[weekdayText] {
            let current = calendar.component(.weekday, from: today)
            var delta = (target - current + 7) % 7
            if forceNext, delta == 0 { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: today)
        }

        if let date = isoFormatter.date(from: raw) {
            return calendar.startOfDay(for: date)
        }

        let slash = try? NSRegularExpression(pattern: "^(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?$")
        let ns = raw as NSString
        if let match = slash?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let month = Int(ns.substring(with: match.range(at: 1))) ?? 1
            let day = Int(ns.substring(with: match.range(at: 2))) ?? 1
            var year = calendar.component(.year, from: today)
            if match.range(at: 3).location != NSNotFound {
                year = Int(ns.substring(with: match.range(at: 3))) ?? year
                if year < 100 { year += 2000 }
            }
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                return calendar.startOfDay(for: date)
            }
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let full = NSRange(location: 0, length: ns.length)
            if let match = detector.firstMatch(in: raw, range: full), let date = match.date {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }
}

extension DueDateController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let date = Self.parse(titleField.stringValue) else { return }
        chosenDate = date
        calendarView.dateValue = date
        updatePreview()
    }
}

final class DueDateRootView: NSView {
    static let cornerRadius: CGFloat = 12
}

final class DueTitleField: NSTextField {
    override func cancelOperation(_ sender: Any?) {
        // Handled by the panel's key monitor; swallow so the field editor does
        // not just revert its text.
    }
}

final class DueDatePanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        // Never let macOS window restoration resurrect this transient panel:
        // a restored orphan panel tears down without a controller and crashes.
        isRestorable = false
        level = .floating
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
