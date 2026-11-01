import SwiftUI
import AppKit

struct OutlineEditor: NSViewRepresentable {
    @ObservedObject var model: DocumentModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // The TextKit 2 initializer is unavailable to this subclass in Swift,
        // so use the ObjC factory. It follows the +0 factory convention
        // (objc_autoreleaseReturnValue), so the result must be unretained.
        let selector = NSSelectorFromString("textViewUsingTextLayoutManager:")
        let made = (OutlineTextView.self as AnyObject).perform(selector, with: true)!
        let textView = made.takeUnretainedValue() as! OutlineTextView
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.drawsBackground = false
        // +4.76 because line spacing is also applied above the first line,
        // which would otherwise pull the whole document up.
        textView.textContainerInset = NSSize(width: 0, height: 25)

        textView.string = model.text
        textView.configure(model: model)
        textView.restyle()

        scroll.documentView = textView

        let completion = CompletionController()
        completion.attach(to: textView)
        textView.completion = completion
        let dueDate = DueDateController()
        dueDate.attach(to: textView)
        textView.dueDates = dueDate

        DispatchQueue.main.async {
            model.editor = textView
            textView.window?.makeFirstResponder(textView)
            if let window = textView.window, window.title == "Untitled" {
                window.title = "未命名"
            }
        }

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // DocumentGroup titles untitled windows "Untitled"; retitle in Chinese.
        if let window = nsView.window, window.title == "Untitled" {
            window.title = "未命名"
        }
    }

    func dismantleNSView(_ nsView: NSScrollView, coordinator: ()) {
        guard let textView = nsView.documentView as? OutlineTextView else { return }
        textView.completion?.detach()
        textView.dueDates?.detach()
        textView.completion = nil
        textView.dueDates = nil
    }
}

final class OutlineTextView: NSTextView {
    private weak var model: DocumentModel?
    private var hiddenRanges: [NSRange] = []
    private var foldedLines: Set<Int> = []
    private var isStyling = false
    private let tabWidth: CGFloat = 22

    var completion: CompletionController?
    var dueDates: DueDateController?
    var docTags: [String] { model?.outline.allTags ?? [] }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(model: DocumentModel) {
        self.model = model
        isRichText = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(forKey: "BCheckSpellingAsYouType")
        isAutomaticSpellingCorrectionEnabled = UserDefaults.standard.bool(forKey: "BCorrectSpellingAutomatically")
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        insertionPointColor = .controlAccentColor
        font = NSFont.systemFont(ofSize: 14)
        typingAttributes = baseAttributes
        delegate = self
        if let storage = textContentStorage {
            storage.delegate = self
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let defaults = UserDefaults.standard
            self.isContinuousSpellCheckingEnabled = defaults.bool(forKey: "BCheckSpellingAsYouType")
            self.isAutomaticSpellingCorrectionEnabled = defaults.bool(forKey: "BCorrectSpellingAutomatically")
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private var defaultsObserver: NSObjectProtocol?

    private let textLeftInset: CGFloat = 32

    private var baseAttributes: [NSAttributedString.Key: Any] {
        // Leading is expressed as lineSpacing, not lineHeightMultiple: TextKit 2
        // draws the insertion point over the whole line fragment, so an inflated
        // line box makes the caret taller than the text. 17pt line + 4.76pt
        // spacing is the same 1.28 rhythm as before, but the fragment now ends
        // where the text does.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4.76
        paragraph.paragraphSpacing = 2
        paragraph.firstLineHeadIndent = textLeftInset
        paragraph.headIndent = textLeftInset
        paragraph.defaultTabInterval = tabWidth
        paragraph.tabStops = []
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    // MARK: styling

    func restyle() {
        guard let storage = textStorage, let model else { return }
        isStyling = true
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes, range: full)

        for item in model.outline.items where item.range.length > 0 {
            switch item.kind {
            case .project:
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                ], range: item.range)
            case .note:
                let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14),
                                                          toHaveTrait: .italicFontMask)
                storage.addAttributes([.font: italic], range: item.range)
            case .task:
                break
            }
            if item.isDone {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.secondaryLabelColor,
                    .foregroundColor: NSColor.secondaryLabelColor
                ], range: item.range)
            }
            for tagRange in tagRanges(in: item) {
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: tagRange)
            }
        }
        storage.endEditing()
        typingAttributes = baseAttributes
        isStyling = false
        if let layout = textLayoutManager {
            layout.invalidateLayout(for: layout.documentRange)
        }
    }

    private func tagRanges(in item: OutlineItem) -> [NSRange] {
        let pattern = try! NSRegularExpression(pattern: "@[A-Za-z0-9_-]+(\\([^)]*\\))?")
        let ns = item.raw as NSString
        return pattern.matches(in: item.raw, range: NSRange(location: 0, length: ns.length)).map {
            NSRange(location: item.range.location + $0.range.location, length: $0.range.length)
        }
    }

    // MARK: text changes

    override func didChangeText() {
        super.didChangeText()
        guard !isStyling else { return }
        model?.updateText(string)
        restyle()
        needsDisplay = true
        completion?.scheduleRefresh()
    }

    /// Swap the whole document content (Revert To, reopen). didChangeText is
    /// suppressed via isStyling so the model doesn't echo it back.
    func replaceText(with newText: String) {
        guard !isStyling else { return }
        isStyling = true
        string = newText
        restyle()
        needsDisplay = true
        isStyling = false
        completion?.scheduleRefresh()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !isStyling else { return }
        let inserted: String?
        if let value = string as? String {
            inserted = value
        } else if let value = string as? NSAttributedString {
            inserted = value.string
        } else {
            inserted = nil
        }
        if let inserted {
            dueDates?.editorInserted(inserted)
        }
    }

    // MARK: visibility / folding

    func applyHiddenRanges(_ ranges: [NSRange], folded: Set<Int>) {
        guard ranges != hiddenRanges || folded != foldedLines else {
            needsDisplay = true
            return
        }
        hiddenRanges = ranges
        foldedLines = folded
        guard let layout = textLayoutManager else { return }
        layout.invalidateLayout(for: layout.documentRange)
        layout.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }

    private func isHidden(_ range: NSRange) -> Bool {
        hiddenRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if let completion, completion.isVisible, completion.handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        completion?.hide()
        return super.resignFirstResponder()
    }

    override func insertNewline(_ sender: Any?) {
        let item = currentItem()
        let indent = String(repeating: "\t", count: item?.indent ?? 0)
        let prefix = item?.kind == .task ? indent + "- " : indent
        super.insertNewline(sender)
        if !prefix.isEmpty {
            insertText(prefix, replacementRange: selectedRange())
        }
    }

    override func insertTab(_ sender: Any?) {
        shiftIndent(outdent: false)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftIndent(outdent: true)
    }

    private func shiftIndent(outdent: Bool) {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let selection = selectedRange()
        let starts = paragraphStarts(touching: selection, in: ns)
        guard !starts.isEmpty else { return }

        let originalStart = selection.location
        let originalEnd = NSMaxRange(selection)
        var deltas: [(location: Int, delta: Int)] = []

        // Edit bottom-up so earlier offsets stay valid.
        for lineStart in starts.sorted(by: >) {
            if outdent {
                guard lineStart < ns.length,
                      ns.substring(with: NSRange(location: lineStart, length: 1)) == "\t" else { continue }
                let target = NSRange(location: lineStart, length: 1)
                guard shouldChangeText(in: target, replacementString: "") else { continue }
                storage.replaceCharacters(in: target, with: "")
                deltas.append((lineStart, -1))
            } else {
                let target = NSRange(location: lineStart, length: 0)
                guard shouldChangeText(in: target, replacementString: "\t") else { continue }
                storage.replaceCharacters(in: target, with: "\t")
                deltas.append((lineStart, 1))
            }
        }
        guard !deltas.isEmpty else { return }
        didChangeText()

        func shifted(_ position: Int) -> Int {
            var value = position
            for edit in deltas {
                if edit.location < position || (edit.location == position && edit.delta > 0) {
                    value += edit.delta
                }
            }
            return value
        }
        let newStart = shifted(originalStart)
        let newEnd = max(newStart, shifted(originalEnd))
        setSelectedRange(NSRange(location: newStart, length: newEnd - newStart))
    }

    /// Start offsets of every paragraph the selection touches. A selection ending
    /// exactly at a line break does not include the line after it, and a caret
    /// parked at the end of the document maps to the last (possibly empty) line.
    private func paragraphStarts(touching selection: NSRange, in ns: NSString) -> [Int] {
        guard ns.length > 0 else { return [] }
        let begin = min(selection.location, ns.length)
        var finish = min(NSMaxRange(selection), ns.length)
        if finish > begin, finish > 0, ns.character(at: finish - 1) == 0x0A {
            finish -= 1
        }

        var starts: [Int] = []
        var cursor = begin
        while true {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: cursor, length: 0))
            if starts.last != start { starts.append(start) }
            if end <= cursor || end > finish { break }
            cursor = end
        }
        return starts
    }

    // MARK: commands

    func toggleDoneForSelection() {
        guard let model else { return }
        let items = paragraphStarts(touching: selectedRange(), in: string as NSString)
            .compactMap { start in model.outline.items.first { $0.range.location == start } }
        toggleDone(for: items)
    }

    func toggleDone(for items: [OutlineItem]) {
        guard let storage = textStorage else { return }
        for item in items.sorted(by: { $0.range.location > $1.range.location }) {
            let ns = string as NSString
            let contentRange = contentRangeOfLine(at: item.range.location)
            let line = ns.substring(with: contentRange)

            if line.contains("@done") {
                let regex = try! NSRegularExpression(pattern: "\\s*@done(\\([^)]*\\))?")
                if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let target = NSRange(location: contentRange.location + match.range.location,
                                         length: match.range.length)
                    guard shouldChangeText(in: target, replacementString: "") else { continue }
                    storage.replaceCharacters(in: target, with: "")
                    didChangeText()
                }
            } else {
                let target = NSRange(location: contentRange.location + contentRange.length, length: 0)
                guard shouldChangeText(in: target, replacementString: " @done") else { continue }
                storage.replaceCharacters(in: target, with: " @done")
                didChangeText()
            }
        }
    }

    func toggleDone(for item: OutlineItem) {
        toggleDone(for: [item])
    }

    private func contentRangeOfLine(at location: Int) -> NSRange {
        let ns = string as NSString
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                        for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    func insertDateTag() {
        guard let storage = textStorage else { return }
        let item = currentItem()
        let lineStart = item?.range.location ?? selectedRange().location
        let contentRange = contentRangeOfLine(at: lineStart)
        let target = NSRange(location: contentRange.location + contentRange.length, length: 0)
        guard shouldChangeText(in: target, replacementString: " @today") else { return }
        storage.replaceCharacters(in: target, with: " @today")
        setSelectedRange(NSRange(location: target.location + 7, length: 0))
        didChangeText()
    }

    /// Opens the due-date palette for a tag that was just inserted, e.g. when
    /// "due" is accepted from the completion list.
    func presentDueDate(for range: NSRange) {
        dueDates?.present(tokenRange: range, defaultDate: nil, in: self)
    }

    /// "Due Date" command: edits an existing @due(...) on the current line or
    /// appends a bare @due and immediately opens the palette.
    func insertDueTag() {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let anchor = currentItem()?.range.location ?? selectedRange().location
        let contentRange = contentRangeOfLine(at: anchor)
        let line = ns.substring(with: contentRange)

        if let match = Self.dueTagRegex.firstMatch(in: line,
                                                   range: NSRange(location: 0, length: (line as NSString).length)) {
            let range = NSRange(location: contentRange.location + match.range.location,
                                length: match.range.length)
            let tag = ns.substring(with: range)
            dueDates?.present(tokenRange: range, defaultDate: Self.date(inTag: tag), in: self)
            return
        }

        let insertion = line.isEmpty ? "@due" : " @due"
        let target = NSRange(location: contentRange.location + contentRange.length, length: 0)
        guard shouldChangeText(in: target, replacementString: insertion) else { return }
        storage.replaceCharacters(in: target, with: insertion)
        let caret = target.location + (insertion as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
        didChangeText()
        let token = NSRange(location: caret - 4, length: 4)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dueDates?.present(tokenRange: token, defaultDate: nil, in: self)
        }
    }

    private static let dueTagRegex = try! NSRegularExpression(pattern: "@due(\\([^)]*\\))?",
                                                              options: [.caseInsensitive])

    private static func date(inTag tag: String) -> Date? {
        guard let open = tag.firstIndex(of: "("), let close = tag.lastIndex(of: ")"), open < close else {
            return nil
        }
        let value = String(tag[tag.index(after: open)..<close])
        return DueDateController.isoFormatter.date(from: value)
    }

    /// "Delete Items": removes every line the selection touches, then plays the
    /// classic poof effect at the first removed line when enabled in Settings.
    func deleteSelectedLines() {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let starts = paragraphStarts(touching: selectedRange(), in: ns)
        guard let firstStart = starts.min() else { return }

        let poofRect = UserDefaults.standard.bool(forKey: "BShowPoofAnimationOnDelete")
            ? caretScreenRect(at: firstStart).map { NSRect(origin: $0.origin, size: NSSize(width: 32, height: 32)) }
            : nil

        for lineStart in starts.sorted(by: >) {
            var lineEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: nil,
                            for: NSRange(location: lineStart, length: 0))
            let target = NSRange(location: lineStart, length: lineEnd - lineStart)
            guard shouldChangeText(in: target, replacementString: "") else { continue }
            storage.replaceCharacters(in: target, with: "")
        }
        let newLength = (string as NSString).length
        setSelectedRange(NSRange(location: min(newLength, firstStart), length: 0))
        didChangeText()
        if let poofRect {
            NSAnimationEffect.poof.show(centeredAt: poofRect.origin, size: poofRect.size)
        }
    }

    func focus(onLine line: Int) {
        guard let model, line < model.outline.items.count else { return }
        let item = model.outline.items[line]
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: item.range.location, length: 0))
        scrollRangeToVisible(item.range)
    }

    // MARK: hit testing

    private func currentItem() -> OutlineItem? {
        let items = model?.outline.items ?? []
        let location = selectedRange().location
        if let hit = items.first(where: { NSLocationInRange(location, $0.range) }) {
            return hit
        }
        guard let last = items.last, location == last.range.location + last.range.length else {
            return nil
        }
        return last
    }

    private func item(atCharacterOffset offset: Int) -> OutlineItem? {
        model?.outline.items.first { offset >= $0.range.location && offset < $0.range.location + max(1, $0.range.length) }
    }

    /// Screen-space caret line rectangle for an arbitrary character offset.
    func caretScreenRect(at location: Int) -> NSRect? {
        guard let window, let layout = textLayoutManager, let storage = textContentStorage else {
            return nil
        }
        let ns = string as NSString
        guard location >= 0, location <= ns.length else { return nil }

        layout.ensureLayout(for: layout.documentRange)

        let probeIndex = location == ns.length ? max(0, location - 1) : location
        guard let probe = storage.location(storage.documentRange.location, offsetBy: probeIndex),
              let fragment = layout.textLayoutFragment(for: probe) else { return nil }
        let fragmentOffset = storage.offset(from: storage.documentRange.location,
                                            to: fragment.rangeInElement.location)
        guard fragmentOffset != NSNotFound else { return nil }

        for line in fragment.textLineFragments {
            let lineStart = fragmentOffset + line.characterRange.location
            let lineEnd = lineStart + line.characterRange.length
            guard location >= lineStart, location <= lineEnd else { continue }

            let local = location - lineStart
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
            let viewRect = NSRect(x: textContainerOrigin.x + frame.minX + x,
                                  y: textContainerOrigin.y + frame.minY + bounds.minY,
                                  width: 0, height: bounds.height)
            return window.convertToScreen(convert(viewRect, to: nil))
        }
        return nil
    }

    private func characterOffset(of fragment: NSTextLayoutFragment) -> Int? {
        guard let storage = textContentStorage else { return nil }
        let value = storage.offset(from: storage.documentRange.location,
                                   to: fragment.rangeInElement.location)
        return value == NSNotFound ? nil : value
    }

    private func lineCenterY(of fragment: NSTextLayoutFragment) -> CGFloat {
        guard let line = fragment.textLineFragments.first, line.characterRange.length > 0 else {
            return fragment.layoutFragmentFrame.height / 2
        }
        // locationForCharacter 的基线相对行自身排版原点；第二段起 fragment
        // 顶部还含段距/行距，必须加 typographicBounds.minY 才与字形对齐
        let baseline = line.locationForCharacter(at: 0).y + line.typographicBounds.minY
        let font = line.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? .systemFont(ofSize: 14)
        return baseline - font.capHeight / 2
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let layout = textLayoutManager,
           let storage = textContentStorage,
           let model,
           let item = item(atCharacterOffset: characterIndexForInsertion(at: point)),
           let lineLocation = storage.location(storage.documentRange.location,
                                               offsetBy: item.range.location),
           let fragment = layout.textLayoutFragment(for: lineLocation) {
            let frame = fragment.layoutFragmentFrame
            let lineTop = textContainerOrigin.y + frame.minY
            let dotCenter = NSPoint(x: textLeftInset - 18 + CGFloat(item.indent) * tabWidth,
                                    y: lineTop + lineCenterY(of: fragment))
            if item.kind == .project,
               hypot(point.x - dotCenter.x, point.y - dotCenter.y) < 10 {
                model.toggleFold(line: item.lineIndex)
                return
            }
            let glyphX = textLeftInset + CGFloat(item.indent) * tabWidth
            if item.kind == .task, point.x >= glyphX, point.x < glyphX + 17,
               point.y >= lineTop, point.y <= lineTop + max(frame.height, 17) {
                toggleDone(for: item)
                setSelectedRange(NSRange(location: item.range.location, length: 0))
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = textLayoutManager else { return }
        let origin = textContainerOrigin
        let visible = visibleRect
        var dots: [(center: NSPoint, folded: Bool)] = []

        layout.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = origin.y + frame.minY
            guard visible.intersects(NSRect(x: 0, y: y, width: self.bounds.width, height: frame.height)) else {
                return true
            }
            guard let offset = self.characterOffset(of: fragment),
                  let item = self.item(atCharacterOffset: offset),
                  item.kind == .project else { return true }
            let center = NSPoint(x: self.textLeftInset - 18 + CGFloat(item.indent) * self.tabWidth,
                                 y: y + self.lineCenterY(of: fragment))
            dots.append((center, self.foldedLines.contains(item.lineIndex)))
            return true
        }

        for dot in dots {
            let outer = NSBezierPath(ovalIn: NSRect(x: dot.center.x - 4.5, y: dot.center.y - 4.5,
                                                    width: 9, height: 9))
            if dot.folded {
                NSColor.controlAccentColor.setFill()
                outer.fill()
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: dot.center.x - 2.8, y: dot.center.y - 2.8,
                                            width: 5.6, height: 5.6)).fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                outer.lineWidth = 1.2
                outer.stroke()
            }
        }
    }
}

extension OutlineTextView: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        completion?.scheduleRefresh()
    }
}

extension OutlineTextView: NSTextContentStorageDelegate {
    func textContentManager(_ textContentManager: NSTextContentManager,
                            shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard let storage = textContentStorage,
              let elementRange = textElement.elementRange else { return true }
        let start = storage.offset(from: storage.documentRange.location, to: elementRange.location)
        let end = storage.offset(from: storage.documentRange.location, to: elementRange.endLocation)
        guard start != NSNotFound, end != NSNotFound else { return true }
        return !isHidden(NSRange(location: start, length: end - start))
    }
}
