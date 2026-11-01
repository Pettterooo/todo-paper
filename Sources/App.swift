import SwiftUI
import AppKit

/// Registered before any document is restored: SwiftUI DocumentGroup restores
/// windows *before* applicationDidFinishLaunching runs, so defaults must be
/// in place at process start or the welcome-text seeding reads them as off.
private let registeredDefaults: Void = {
    UserDefaults.standard.register(defaults: [
        "BShowWelcomeText": true,
        "BShowPoofAnimationOnDelete": true,
        "BSidebarFontSizeFollowsSystemPreferences": true,
        "BCheckSpellingAsYouType": false,
        "BCorrectSpellingAutomatically": false,
        "BShowToggleDoneButton": true,
        "BShowInsertDateButton": true,
        "BShowDueDateButton": true,
        "BShowDeleteItemsButton": true,
        "BReopenLastDocument": true,
    ])
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = registeredDefaults
        NSApp.setActivationPolicy(.regular)

        // Remember whichever document window was last active, so the next
        // launch can reopen it. Untitled windows have no representedURL.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  let url = window.representedURL else { return }
            UserDefaults.standard.set(url.path, forKey: "LastDocumentPath")
        }

        reopenLastDocumentIfNeeded()
    }

    /// Reopens the document that was active at the last quit when the
    /// "启动时打开上次的文档" setting is on. NSDocumentController dedupes by URL,
    /// so a window the system already restored is just brought forward.
    private func reopenLastDocumentIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "BReopenLastDocument"),
              let path = UserDefaults.standard.string(forKey: "LastDocumentPath"),
              FileManager.default.fileExists(atPath: path) else { return }
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path),
                                                 display: true) { _, _, _ in }
    }

    /// Closing the last window must not terminate the app: auto-termination
    /// makes the window and Dock icon vanish together, which reads as a crash.
    /// Keep the app alive like a normal document app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// A Dock click with no window open opens a fresh untitled document
    /// instead of the default Open panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if NSApp.sendAction(Selector(("newDocument:")), to: nil, from: nil) {
            return false
        }
        return true
    }
}

@main
struct TaskPaperDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: TaskPaperFileDocument()) { configuration in
            ContentView(document: configuration.$document, fileURL: configuration.fileURL)
        }
        .defaultSize(width: 615, height: 532)

        Settings {
            SettingsView()
        }
    }
}

struct ContentView: View {
    @Binding var document: TaskPaperFileDocument
    private let fileURL: URL?
    @StateObject private var doc: DocumentModel
    @State private var selection: SidebarSelection? = .home
    @AppStorage("BShowToggleDoneButton") private var showToggleDoneButton = true
    @AppStorage("BShowInsertDateButton") private var showInsertDateButton = true
    @AppStorage("BShowDueDateButton") private var showDueDateButton = true
    @AppStorage("BShowDeleteItemsButton") private var showDeleteItemsButton = true

    init(document: Binding<TaskPaperFileDocument>, fileURL: URL?) {
        self._document = document
        self.fileURL = fileURL
        self._doc = StateObject(wrappedValue: DocumentModel(
            text: document.wrappedValue.text,
            onTextChange: { newText in document.wrappedValue.text = newText }
        ))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(doc: doc, selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            if fileURL == nil {
                OutlineEditor(model: doc)
                    .navigationTitle("未命名")
            } else {
                OutlineEditor(model: doc)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if showToggleDoneButton {
                    Button {
                        doc.toggleDoneForSelection()
                    } label: {
                        Label("标记完成", systemImage: "checkmark.circle")
                    }
                    .help("切换所选行的 @done")
                }
                if showInsertDateButton {
                    Button {
                        doc.insertDateTag()
                    } label: {
                        Label("插入日期", systemImage: "calendar")
                    }
                    .help("在行尾追加 @today")
                }
                if showDueDateButton {
                    Button {
                        doc.insertDueTag()
                    } label: {
                        Label("截止日期", systemImage: "calendar.badge.clock")
                    }
                    .help("添加带日期的 @due")
                }
                if showDeleteItemsButton {
                    Button {
                        doc.deleteSelection()
                    } label: {
                        Label("删除条目", systemImage: "trash")
                    }
                    .help("删除选中的行")
                }
            }
        }
        .onChange(of: document.text) { _, newText in
            if newText != doc.text { doc.replaceText(with: newText) }
        }
        .onAppear {
            if let fileURL {
                UserDefaults.standard.set(fileURL.path, forKey: "LastDocumentPath")
            }
        }
    }
}

enum SidebarSelection: Hashable {
    case home
    case project(Int)      // line index
}

struct SidebarView: View {
    @ObservedObject var doc: DocumentModel
    @Binding var selection: SidebarSelection?
    @AppStorage("BSidebarFontSizeFollowsSystemPreferences") private var sidebarFollowsSystem = true

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("首页", systemImage: "house")
                    .tag(SidebarSelection.home)
            }
            if !doc.projects.isEmpty {
                Section("项目") {
                    ForEach(doc.projects) { p in
                        Label(p.name, systemImage: "list.bullet.indent")
                            .tag(SidebarSelection.project(p.lineIndex))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .controlSize(sidebarFollowsSystem ? .regular : .small)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                Text("\(doc.outline.items.count) 个条目")
                Spacer()
                Text("\(doc.outline.projects.count) 个项目")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            switch newValue {
            case .home:
                doc.focusLine(0)
            case .project(let line):
                doc.focusLine(line)
            }
        }
    }
}
