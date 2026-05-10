
import SwiftUI
import UniformTypeIdentifiers

@main
struct GlowAiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // ウインドウなし（ドロップ＆終了型アプリ）
        // 表示・ウインドウメニューは AppDelegate で NSApp.mainMenu から直接削除
        Settings { EmptyView() }
            .commands {
                // File メニュー（標準位置：アプリメニューの右）
                CommandGroup(replacing: .newItem) {
                    Button("Open…") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.item]
                        if panel.runModal() == .OK {
                            NSApp.delegate?.application?(NSApp, open: panel.urls)
                        }
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
                CommandGroup(replacing: .undoRedo) {}
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences…") {
                        appDelegate.openPreferences()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button("Glow Ai Help") {
                        appDelegate.openHelp()
                    }
                    .keyboardShortcut("?", modifiers: .command)
                    Divider()
                    Button("Change Log") {
                        appDelegate.openChangeLog()
                    }
                }
            }
    }
}
