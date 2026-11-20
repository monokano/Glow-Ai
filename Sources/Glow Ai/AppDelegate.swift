
import AppKit
import SwiftUI
import UniformTypeIdentifiers


class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var shared: AppDelegate?

    // MARK: - State

    /// ドロップされたファイルの累積配列（RunStart が処理する）
    private var dropItems: [URL] = []
    /// OpenDocument が呼ばれた回数（初回だけ RunStart を起動する）
    private var countDrop: Int = 0
    /// 初回ドロップ時の cmd キー状態（application(_:open:) 呼び出し直後にキャプチャ）
    private var cmdKeyDownAtDrop: Bool = false
    /// applicationDidFinishLaunching が終わったか（Release ビルドでは application(_:open:) が先に呼ばれるため）
    private var launchFinished: Bool = false
    /// 起動処理の完了を待って runStart() を実行するための保留フラグ
    private var pendingRunStart: Bool = false
    /// 現在表示中の InfoWindow コントローラ
    var infoWindowController: InfoWindowController?
    /// 環境設定ウインドウ
    private var preferencesWindowController: PreferencesWindowController?
    private var helpWindowController: HelpWindowController?

    // MARK: - applicationWillFinishLaunching

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS 13.0 未満は対象外（Deployment Target で弾かれるが念のため）
        if #unavailable(macOS 13.0) { return }

        // application(_:open:) より前にアプリ一覧を収集する
        // ※ Release ビルドでは application(_:open:) が applicationDidFinishLaunching
        //   より先に呼ばれるため、ここで収集しておく必要がある
        IllustratorApp.shared.getAppALL()
        PhotoshopApp.shared.getAppALL()
    }

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // macOS 13.0 未満は対象外（Deployment Target で弾かれるが念のため）
        if #unavailable(macOS 13.0) {
            showAlertAndQuit(
                message: NSLocalizedString("System Requirement", comment: ""),
                info: "macOS 13.0 or later is required."
            )
            return
        }

        // Dock メニューを手動登録（@NSApplicationDelegateAdaptor 経由だとフォワードされないため）
        NSApp.delegate = self

        // 不要なメニュー（表示・ウインドウ）を削除
        DispatchQueue.main.async {
            let removes = ["表示", "View", "ウインドウ", "Window"]
            NSApp.mainMenu?.items
                .filter { removes.contains($0.title) }
                .forEach { NSApp.mainMenu?.removeItem($0) }
        }

        // 隔離起動（App Translocation）中なら、Finder での移動を案内する。
        // 移動すれば出なくなるので毎回出す。「終了」ならドロップされたファイルも開かずに終了する。
        if AppTranslocation.isTranslocated(Bundle.main.bundleURL) {
            if !showTranslocationAlert() {
                appQuit()
                return
            }
        }

        // アイコン取込は起動時には行わない（環境設定のボタンから。HANDOFF ステップ7）
        launchFinished = true
        if pendingRunStart {
            pendingRunStart = false
            runStart()
        }
    }

    // MARK: - Dock メニュー

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let prefsItem = NSMenuItem(
            title: String(localized: "Preferences…"),
            action: #selector(openPreferences),
            keyEquivalent: ""
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        // ヘルプ（共通仕様＝App-共有資料/ヘルプ仕様.md §4.2）。ウインドウのタイトルはヘルプメニューから開いたときと同じ
        let helpItem = NSMenuItem(
            title: String(localized: "Help"),
            action: #selector(dockHelpClicked(_:)),
            keyEquivalent: ""
        )
        helpItem.target = self
        menu.addItem(helpItem)

        return menu
    }

    @objc private func dockHelpClicked(_ sender: Any?) {
        openHelp()
    }

    // MARK: - メニューバー「環境設定」／「ヘルプ」

    @objc func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func openHelp() {
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.show()
    }

    // MARK: - application(_:open:)（ファイルドロップ受付）

    func application(_ application: NSApplication, open urls: [URL]) {
        countDrop += 1

        // 初回ドロップ時のみ cmd キー状態をキャプチャする
        if countDrop == 1 {
            cmdKeyDownAtDrop = NSEvent.modifierFlags.contains(.command)
        }

        for url in urls {
            var resolved = url
            // Finder エイリアス解決
            if let r = try? URL(resolvingAliasFileAt: url) { resolved = r }
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            dropItems.append(resolved)
        }

        guard !dropItems.isEmpty else { appQuit(); return }

        // 初回ドロップ時のみ RunStart を起動する
        // 2回目以降は dropItems に追加済みなので RunStart 内で処理される
        // ただし起動処理が終わっていなければ保留する。
        if countDrop == 1 {
            if launchFinished {
                runStart()
            } else {
                pendingRunStart = true
            }
        }
    }

    // MARK: - applicationShouldTerminateAfterLastWindowClosed

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - applicationWillTerminate

    func applicationWillTerminate(_ notification: Notification) {
        Preferences.shared.save()
    }

    // MARK: - RunStart（メイン処理）

    private func runStart() {
        for url in dropItems {
            guard let fc = FileInfo.getInfoMinimum(url: url,
                                                   isLimit: Preferences.shared.useTimeLimit) else { continue }

            let needsWindow = evaluateInfoWindowMode(fc: fc, cmdKeyDown: cmdKeyDownAtDrop)
            if needsWindow {
                // 警告バッジ:
                // ・Photoshopファイル → 種類バルーンが赤（拡張子偽装）のときだけ付ける
                // ・それ以外（Illustrator等） → 従来どおり（mode 11=制限時間超過 / 12=Illustrator編集PDF は付けない）
                let showAlert = fc.appName == "Photoshop"
                    ? fc.isKindDangerous
                    : (fc.infoWindowMode != 11 && fc.infoWindowMode != 12)
                showInfoWindow(fc: fc, showAlertIcon: showAlert)
            }
        }

        // 各 Illustrator.app / Photoshop.app に対してまとめてファイルを渡す。
        // NSWorkspace の open は非同期なので DispatchGroup で完了を待ち、
        // 全アプリのアクティブ化完了後に Glow Ai を終了する。
        // （早く終了すると macOS が直前にアクティブだった Finder にフォーカスを戻し、
        //   一瞬 Finder 最前面 → Illustrator 最前面のちらつきが発生する）
        let group = DispatchGroup()

        for ac in IllustratorApp.shared.appClassALLIncludeBeta where !ac.openFileURLs.isEmpty {
            group.enter()
            IllustratorApp.shared.openWith(appURL: ac.appURL, fileURLs: ac.openFileURLs) {
                group.leave()
            }
        }

        for ac in PhotoshopApp.shared.appClassALL where !ac.openFileURLs.isEmpty {
            group.enter()
            PhotoshopApp.shared.openWith(appURL: ac.appURL, fileURLs: ac.openFileURLs) {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.appQuit()
        }
    }

    // MARK: - showInfoWindow

    func showInfoWindow(fc: FileClass, showAlertIcon: Bool) {
        let controller = InfoWindowController(fc: fc, showAlertIcon: showAlertIcon)
        // NSApp.delegate as? AppDelegate は Archive ビルドでキャスト失敗するため、self を直接渡す
        controller.onEvaluate = { [weak self] newFC in
            self?.evaluateInfoWindowMode(fc: newFC)
        }
        infoWindowController = controller
        controller.showModal()
        infoWindowController = nil
    }

    // MARK: - evaluateInfoWindowMode
    // infoWindowMode を評価してセットする。
    // 戻り値：通知ウィンドウを表示すべき場合 true、ファイルを直接開いた場合 false
    @discardableResult
    func evaluateInfoWindowMode(fc: FileClass, cmdKeyDown: Bool = false) -> Bool {
        if fc.isTimeOut {
            fc.infoWindowMode = 11
            return true
        } else if fc.kind == "PDF" && fc.isIllustratorFile {
            // A1: Illustrator編集機能保持PDF
            fc.infoWindowMode = 12
            return true
        } else if fc.isIllustratorFile && !fc.determine_Created.isEmpty {
            if fc.file?.pathExtension.lowercased() == "pdf" {
                // 拡張子 .pdf のファイルは種類・バージョン一致を問わず常に通知ウィンドウを表示する
                // reView: true でモードだけ評価し openFileURLs への追加は行わない
                IllustratorApp.shared.openWithSameApp(fc: fc, reView: true, cmdKeyDown: cmdKeyDown)
                return true
            } else {
                let opened = IllustratorApp.shared.openWithSameApp(fc: fc, cmdKeyDown: cmdKeyDown)
                return !opened
            }
        } else {
            fc.infoWindowMode = fc.isIllustratorFile ? 5 : 10
            return true
        }
    }

    // MARK: - appQuit

    func appQuit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    // MARK: - 隔離起動の案内

    /// 隔離起動の案内を出す。「このまま続ける」なら true、「終了」なら false。
    /// 元の場所がアプリケーションフォルダの中（そこで ZIP を展開した場合など）なら、
    /// 「いったん外へ出して戻す」案内にする。元の場所が分からなければ両方に効く文言にする。
    private func showTranslocationAlert() -> Bool {
        let original = AppTranslocation.originalURL(of: Bundle.main.bundleURL)
        let title: String
        let action: String
        switch original.map({ AppTranslocation.isInApplicationsFolder($0) }) {
        case true?:
            title = String(localized: "Move Glow Ai again in the Finder")
            action = String(localized: "Glow Ai is in the Applications folder, but it was moved there in a way that doesn't meet Apple's requirements. Quit Glow Ai, move it to the Desktop in the Finder, move it back to the Applications folder, and then open it again. Also, make sure to move it by itself, not together with other apps.")
        case false?:
            title = String(localized: "Move Glow Ai to the Applications folder")
            action = String(localized: "Quit Glow Ai, move it to the Applications folder in the Finder, and then open it again. Also, make sure to move it by itself, not together with other apps.")
        case nil:
            title = String(localized: "Move Glow Ai to the Applications folder")
            action = String(localized: "Quit Glow Ai, move it to the Applications folder in the Finder, and then open it again. If it's already in the Applications folder, move it to the Desktop and back again in the Finder. Also, make sure to move it by itself, not together with other apps.")
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = [
            String(localized: "Glow Ai is running from a temporary location because it was opened right after being downloaded."),
            String(localized: "For security, macOS runs apps obtained from the internet from a copy in a temporary location until you move them in the Finder."),
            action,
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Quit"))             // 既定（Return）
        let continueButton = alert.addButton(withTitle: String(localized: "Continue Anyway"))
        continueButton.keyEquivalent = "\u{1b}"                           // Esc
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showAlertAndQuit(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.runModal()
        appQuit()
    }
}

