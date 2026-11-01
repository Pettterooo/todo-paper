import Foundation
import AppKit
import SwiftUI

enum ItemKind: String {
    case project, task, note
}

struct OutlineItem: Identifiable {
    var id: Int { lineIndex }
    let lineIndex: Int
    let range: NSRange      // full line range, including trailing newline when present
    let indent: Int
    let raw: String         // line without newline, with leading tabs
    let body: String        // leading tabs and trailing spaces stripped
    let kind: ItemKind
    let isDone: Bool
    let tags: [String]

    var name: String {
        kind == .project ? String(body.dropLast()) : body
    }
}

struct Outline {
    var items: [OutlineItem] = []
    var projects: [OutlineItem] = []
    var allTags: [String] = []

    static func parse(_ text: String) -> Outline {
        let ns = text as NSString
        var items: [OutlineItem] = []
        var location = 0
        var lineIndex = 0

        while location < ns.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let raw = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            var indent = 0
            for ch in raw {
                if ch == "\t" { indent += 1 } else { break }
            }
            let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\t")).trimmingCharacters(in: .whitespaces)

            let kind: ItemKind
            if body.hasPrefix("- ") || body == "-" {
                kind = .task
            } else if body.hasSuffix(":") {
                kind = .project
            } else {
                kind = .note
            }

            let tags = Self.tags(in: body)
            items.append(OutlineItem(lineIndex: lineIndex,
                                     range: lineRange,
                                     indent: indent,
                                     raw: raw,
                                     body: body,
                                     kind: kind,
                                     isDone: tags.contains("done"),
                                     tags: tags))

            location = lineRange.location + lineRange.length
            lineIndex += 1
        }

        var out = Outline()
        out.items = items
        out.projects = items.filter { $0.kind == .project }
        var seen = Set<String>()
        out.allTags = items.flatMap(\.tags).filter { seen.insert($0).inserted }.sorted()
        return out
    }

    static func tags(in body: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "@([A-Za-z0-9_-]+)")
        let ns = body as NSString
        return pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }
}

@MainActor
final class DocumentModel: ObservableObject {
    @Published var text: String
    @Published var outline: Outline
    @Published private(set) var foldedLines: Set<Int> = []

    private var isUpdating = false
    private let onTextChange: (String) -> Void

    weak var editor: OutlineTextView?

    init(text: String, onTextChange: @escaping (String) -> Void = { _ in }) {
        self.text = text
        self.onTextChange = onTextChange
        outline = Outline.parse(text)
    }

    var projects: [OutlineItem] { outline.projects }

    func updateText(_ newText: String) {
        guard !isUpdating, newText != text else { return }
        text = newText
        outline = Outline.parse(newText)
        recomputeVisibility()
        onTextChange(newText)
    }

    /// Whole-content replacement coming from outside the editor (e.g. Revert To).
    func replaceText(with newText: String) {
        guard newText != text else { return }
        text = newText
        outline = Outline.parse(newText)
        foldedLines.removeAll()
        editor?.replaceText(with: newText)
        recomputeVisibility()
    }

    func toggleFold(line: Int) {
        if foldedLines.contains(line) {
            foldedLines.remove(line)
        } else {
            foldedLines.insert(line)
        }
        recomputeVisibility()
    }

    func isFolded(line: Int) -> Bool { foldedLines.contains(line) }

    func focusLine(_ line: Int) {
        editor?.focus(onLine: line)
    }

    func toggleDoneForSelection() {
        editor?.toggleDoneForSelection()
    }

    func insertDateTag() {
        editor?.insertDateTag()
    }

    func insertDueTag() {
        editor?.insertDueTag()
    }

    func deleteSelection() {
        editor?.deleteSelectedLines()
    }

    // MARK: visibility

    private func recomputeVisibility() {
        let items = outline.items
        var visible = Array(repeating: true, count: items.count)

        // folded branches
        for item in items where item.kind == .project && foldedLines.contains(item.lineIndex) {
            var j = item.lineIndex + 1
            while j < items.count && items[j].indent > item.indent {
                visible[j] = false
                j += 1
            }
        }

        var ranges: [NSRange] = []
        for (idx, item) in items.enumerated() where !visible[idx] {
            if let last = ranges.last, last.location + last.length == item.range.location {
                ranges[ranges.count - 1].length += item.range.length
            } else {
                ranges.append(item.range)
            }
        }
        editor?.applyHiddenRanges(ranges, folded: foldedLines)
    }
}

enum SampleDocument {
    static let text = """
    Welcome:
    \t- TaskPaper knows about projects, tasks, notes and tags @today
    \t- It auto-formats items so lists are easier to read
    \t@tags are picked up anywhere in a line
    \t- Mark a task done and it gets struck through @done(2026-10-30)
    Design:
    \t- Rebuild the editor on TextKit 2
    \t- Keep the file format plain text
    \tNotes about the rebuild
    \t- Glass chrome via NSGlassEffectView
    \t- Folding driven by the text content manager
    Launch:
    \t- Write the migration spec @due(2026-11-15)
    \t- Ship a demo for review
    \t- Collect feedback @start(2026-11-01)
    """
}
