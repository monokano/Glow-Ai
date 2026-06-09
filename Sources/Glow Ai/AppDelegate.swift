
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
    /// 起動時ダイアログ（アイコン取込・危険バージョン警告）が終わったか
    private var iconImportDone: Bool = false
    /// 起動時ダイアログの完了を待って runStart() を実行するための保留フラグ
    private var pendingRunStart: Bool = false
    /// 現在表示中の InfoWindow コントローラ
    var infoWindowController: InfoWindowController?
    /// 環境設定ウインドウ
    private var preferencesWindowController: PreferencesWindowController?
    /// 更新履歴ウインドウ
    private var changeLogWindowController: ChangeLogWindowController?
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

        // ファイル関連付けを明示的に再登録
        if Preferences.shared.autoClaimFileAssociations {
            // ON：Glow Ai 自身を関連付け
            claimFileAssociations()
        } else {
            // OFF：インストール済みの最上位 Illustrator（Beta含む）を関連付け
            claimFileAssociationsToTopIllustrator()
        }

        // 不要なメニュー（表示・ウインドウ）を削除
        DispatchQueue.main.async {
            let removes = ["表示", "View", "ウインドウ", "Window"]
            NSApp.mainMenu?.items
                .filter { removes.contains($0.title) }
                .forEach { NSApp.mainMenu?.removeItem($0) }
        }

        // 起動時ダイアログ（アイコン取込）を真っ先に表示するため、
        // 完了まで runStart()（通知ウィンドウ処理）を保留する。
        importIconsIfNeeded { [weak self] in
            guard let self else { return }
            self.iconImportDone = true
            if self.pendingRunStart {
                self.pendingRunStart = false
                self.runStart()
            }
        }
    }

    // MARK: - アイコン取込

    /// アイコン取込が必要なら実行し、完了ダイアログ（抑制設定でない場合）を表示してから
    /// completion を呼ぶ。取込不要・中止の場合も必ず completion を呼ぶ。
    private func importIconsIfNeeded(completion: @escaping () -> Void) {
        let prefs = Preferences.shared
        guard !IllustratorApp.shared.appClassALL.isEmpty else { completion(); return }

        let bundleBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0

        let needImport: Bool
        if prefs.nonReleaseVersion != bundleBuild {
            prefs.nonReleaseVersion = bundleBuild
            prefs.save()
            needImport = true
        } else if let latest = IllustratorApp.shared.getMaximumVerAppClass(),
                  latest.version != prefs.appIconVersion {
            needImport = true
        } else {
            needImport = false
        }

        guard needImport else { completion(); return }

        IllustratorApp.shared.getIconFile(onSuccess: { [weak self] version in
            self?.showIconImportedAlert(version: version)
        }, onProblem: { [weak self] problem in
            self?.showIconImportProblemAlert(problem)
        }, onComplete: {
            completion()
        })
    }

    // MARK: - ファイル関連付け再登録

    func claimFileAssociations() {
        let appURL = Bundle.main.bundleURL
        let utiStrings = [
            "com.adobe.illustrator.ai-image",
            "com.adobe.illustrator.ait-template",
            "com.adobe.encapsulated-postscript"
        ]
        for utiString in utiStrings {
            guard let utType = UTType(utiString) else { continue }
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: utType) { _ in }
        }
    }

    /// 「起動時に関連付けをする」がOFFの場合：
    /// インストール済み最上位バージョンのIllustrator（Beta/Prerelease含む）に関連付けする
    func claimFileAssociationsToTopIllustrator() {
        guard let top = IllustratorApp.shared.getMaximumVerAppClassIncludeBeta() else { return }
        let utiStrings = [
            "com.adobe.illustrator.ai-image",
            "com.adobe.illustrator.ait-template",
            "com.adobe.encapsulated-postscript"
        ]
        for utiString in utiStrings {
            guard let utType = UTType(utiString) else { continue }
            NSWorkspace.shared.setDefaultApplication(at: top.appURL, toOpen: utType) { _ in }
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

        let changeLogItem = NSMenuItem(
            title: String(localized: "Change Log"),
            action: #selector(openChangeLog),
            keyEquivalent: ""
        )
        changeLogItem.target = self
        menu.addItem(changeLogItem)

        return menu
    }

    // MARK: - メニューバー「環境設定」／「更新履歴」

    @objc func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openChangeLog() {
        if changeLogWindowController == nil {
            changeLogWindowController = ChangeLogWindowController()
        }
        changeLogWindowController?.show()
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
        // ただし起動時ダイアログを先に出すため、未完了なら保留する。
        if countDrop == 1 {
            if iconImportDone {
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

    private func showIconImportedAlert(version: String) {
        guard !Preferences.shared.doNotNotifyIconImport else { return }
        let name = FileInfo.versionName(version)
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Icon files imported from Illustrator %@"), name)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// アイコンを自分のバンドルに書き込めなかったとき、原因に応じた是正案内を表示する。
    /// 管理者パスワードは要求しない（旧来の管理者コピーを廃止した代替）。
    private func showIconImportProblemAlert(_ problem: IconImportProblem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch problem {
        case .translocated:
            alert.messageText = String(localized: "Please move Glow Ai to the Applications folder")
            alert.informativeText = String(localized: "Glow Ai is running from a temporary, read-only location, so it cannot update its file icons. Quit Glow Ai, move it to the Applications folder using the Finder, and open it again.")
        case .rootOwned:
            alert.messageText = String(localized: "Please reinstall Glow Ai")
            alert.informativeText = String(localized: "Part of Glow Ai is owned by the administrator, so it cannot update its file icons. Move Glow Ai to the Trash, download the latest version, and install it again.")
        case .notWritable:
            alert.messageText = String(localized: "Glow Ai could not update its file icons")
            alert.informativeText = String(localized: "Glow Ai cannot write to its current location. Move it to the Applications folder (or the Applications folder in your home folder) and open it again.")
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

