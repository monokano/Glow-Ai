
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
        let prefs = Preferences.shared

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

        // アイコンファイルのコピー（最新 Illustrator.app から）
        if !IllustratorApp.shared.appClassALL.isEmpty {
            let bundleBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            if prefs.nonReleaseVersion != bundleBuild {
                IllustratorApp.shared.getIconFile { version in
                    self.showIconImportedAlert(version: version)
                } onFailure: { version in
                    self.showIconImportFailedAlert(version: version)
                }
                prefs.nonReleaseVersion = bundleBuild
                prefs.save()
            } else if let latest = IllustratorApp.shared.getMaximumVerAppClass(),
                      latest.version != prefs.appIconVersion {
                IllustratorApp.shared.getIconFile { version in
                    self.showIconImportedAlert(version: version)
                } onFailure: { version in
                    self.showIconImportFailedAlert(version: version)
                }
            }

            // 危険バージョン警告
            showDangerousVersionAlerts()
        }
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
        if countDrop == 1 {
            runStart()
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
        let dangerousVersions = ["25.3.1", "22.0.0", "21.0.0", "21.0.1", "21.0.2"]

        if fc.isTimeOut {
            fc.infoWindowMode = 11
            return true
        } else if fc.kind == "PDF" && fc.isIllustratorFile {
            // A1: Illustrator編集機能保持PDF
            fc.infoWindowMode = 12
            return true
        } else if fc.isIllustratorFile && !fc.determine_Created.isEmpty {
            if dangerousVersions.contains(fc.determine_Created) {
                fc.infoWindowMode = 7
                return true
            } else if fc.file?.pathExtension.lowercased() == "pdf" {
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

    // MARK: - 危険バージョン警告

    private func showDangerousVersionAlerts() {
        for ac in IllustratorApp.shared.appClassALL {
            switch ac.version {
            case "25.3.1":
                showVersionAlert(
                    title: String(format: NSLocalizedString("Danger! Illustrator CC 2021 v%@ is installed", comment: ""), ac.version),
                    info: NSLocalizedString("There are serious bugs in v25.3.1. Please do not use this version.", comment: "")
                )
            case "22.0.0":
                showVersionAlert(
                    title: String(format: NSLocalizedString("Danger! Illustrator CC 2018 v%@ is installed", comment: ""), ac.version),
                    info: NSLocalizedString("There is a serious bug in v22.0.0. Please update it now.", comment: "")
                )
            case "21.0.0", "21.0.1", "21.0.2":
                showVersionAlert(
                    title: String(format: NSLocalizedString("Danger! Illustrator CC 2017 v%@ is installed", comment: ""), ac.version),
                    info: String(format: NSLocalizedString("There is a problem which causes garbled spot color names in v%@. Please update it now.", comment: ""), ac.version)
                )
            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private func showIconImportedAlert(version: String) {
        let name = FileInfo.versionName(version)
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Icon files imported from Illustrator %@"), name)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showIconImportFailedAlert(version: String) {
        let name = FileInfo.versionName(version)
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Failed to import icon files from Illustrator %@"), name)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showVersionAlert(title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
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

