import SwiftUI
import UniformTypeIdentifiers

/// Plain-text file document. TaskPaper stores everything as UTF-8 text,
/// so a value-type FileDocument is all the persistence layer needs —
/// NSDocument machinery (save, autosave, versions, recent files) is
/// provided by DocumentGroup on top of this.
struct TaskPaperFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(exportedAs: "com.taskpaper.text"), .plainText, .text]
    }

    var text: String

    /// New documents start with the bundled Welcome.txt when the
    /// BShowWelcomeText setting is on — the same seeding TaskPaper does.
    init() {
        if UserDefaults.standard.bool(forKey: "BShowWelcomeText"),
           let url = Bundle.main.url(forResource: "Welcome", withExtension: "txt"),
           let welcome = try? String(contentsOf: url, encoding: .utf8) {
            text = welcome
        } else {
            text = ""
        }
    }

    init(text: String) {
        self.text = text
    }

    /// UTF-8 first, then UTF-16; never fails to open — falls back to lossy UTF-8.
    static func decode(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let decoded = String(data: data, encoding: .utf8) { return decoded }
        // String's UTF-16 decoder returns "" (not nil) for malformed odd-length
        // data, so a non-empty result is required for the fallback to be valid.
        if let decoded = String(data: data, encoding: .utf16), !decoded.isEmpty { return decoded }
        return String(decoding: data, as: UTF8.self)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = Self.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Self.encode(text))
    }

    static func encode(_ text: String) -> Data {
        Data(text.utf8)
    }
}
