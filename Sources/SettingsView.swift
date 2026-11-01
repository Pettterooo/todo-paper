import SwiftUI

/// TaskPaper-style settings. Every toggle is a checkbox bound straight to a
/// "B"-prefixed NSUserDefaults key — the same keys TaskPaper uses — and the
/// runtime reads those keys directly. No intermediate state.
struct SettingsView: View {
    @AppStorage("BReopenLastDocument") private var reopenLastDocument = true
    @AppStorage("BSidebarFontSizeFollowsSystemPreferences") private var sidebarFollowsSystem = true
    @AppStorage("BShowWelcomeText") private var showWelcomeText = true
    @AppStorage("BCheckSpellingAsYouType") private var checkSpellingAsYouType = false
    @AppStorage("BCorrectSpellingAutomatically") private var correctSpellingAutomatically = false
    @AppStorage("BShowPoofAnimationOnDelete") private var showPoofOnDelete = true
    @AppStorage("BShowToggleDoneButton") private var showToggleDoneButton = true
    @AppStorage("BShowInsertDateButton") private var showInsertDateButton = true
    @AppStorage("BShowDueDateButton") private var showDueDateButton = true
    @AppStorage("BShowDeleteItemsButton") private var showDeleteItemsButton = true

    var body: some View {
        Form {
            Section("启动") {
                Toggle("启动时打开上次的文档", isOn: $reopenLastDocument)
            }
            Section("侧栏") {
                Toggle("侧栏图标大小跟随系统设置", isOn: $sidebarFollowsSystem)
            }
            Section("编辑器") {
                Toggle("新文档显示欢迎文本", isOn: $showWelcomeText)
                Toggle("输入时检查拼写", isOn: $checkSpellingAsYouType)
                Toggle("自动纠正拼写", isOn: $correctSpellingAutomatically)
            }
            Section("任务") {
                Toggle("删除条目时显示烟雾动画", isOn: $showPoofOnDelete)
            }
            Section("工具栏") {
                Toggle("标记完成", isOn: $showToggleDoneButton)
                Toggle("插入日期", isOn: $showInsertDateButton)
                Toggle("截止日期", isOn: $showDueDateButton)
                Toggle("删除条目", isOn: $showDeleteItemsButton)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .navigationTitle("设置")
    }
}
