
import AppKit
import Foundation

// MARK: - AppClass（Illustratorアプリ1本分のデータモデル）

class IllustratorAppClass {
    var appURL: URL
    var version: String = ""
    /// ソート用数値（major*1e9 + minor*1e6 + patch*1e3 + build）
    var versionDouble: Double = 0
    var isBooted: Bool = false
    var icon: NSImage?
    /// このアプリで開くファイルの URL 配列
    var openFileURLs: [URL] = []

    init(appURL: URL) {
        self.appURL = appURL
    }
}

// MARK: - IllustratorApp（Illustratorアプリ管理モジュール）

class IllustratorApp {

    static let shared = IllustratorApp()
    private init() {}

    /// 正規版のみ（Beta・Prerelease 除外）、バージョン昇順
    var appClassALL: [IllustratorAppClass] = []
    /// Beta・Prerelease を含む全アプリ、バージョン昇順
    var appClassALLIncludeBeta: [IllustratorAppClass] = []

    /// バージョン照合用（メジャーのみ）例: ["25", "26"]
    var appVerAllMajorOnly: [String] = []
    /// バージョン照合用（メジャー.マイナー）例: ["25.0", "26.1"]
    var appVerAllMajorAndMinor: [String] = []

    /// 起動予定として登録されたアプリ（RunStart後の open 実行前に保持）
    var willBootAppClass: [IllustratorAppClass] = []

    // MARK: - getAppALL

    func getAppALL() {
        appClassALL = []
        appClassALLIncludeBeta = []
        appVerAllMajorOnly = []
        appVerAllMajorAndMinor = []

        let fm = FileManager.default
        let appsURL = URL(fileURLWithPath: "/Applications")
        guard let entries = try? fm.contentsOfDirectory(
            at: appsURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }

        for entry in entries {
            guard entry.lastPathComponent.contains("Adobe Illustrator") else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let isBeta = entry.lastPathComponent.contains("Beta") ||
                         entry.lastPathComponent.contains("Prerelease")

            let appBundleURL = entry.appendingPathComponent("Adobe Illustrator.app")
            guard fm.fileExists(atPath: appBundleURL.path) else { continue }

            let ac = IllustratorAppClass(appURL: appBundleURL)
            ac.version = getAppFullVersion(appBundle: appBundleURL)
            ac.versionDouble = versionToDouble(ac.version)
            ac.isBooted = isAppBooted(appURL: appBundleURL)
            ac.icon = NSWorkspace.shared.icon(forFile: appBundleURL.path)
                        .resized(to: NSSize(width: 18, height: 18))

            appClassALLIncludeBeta.append(ac)

            if !isBeta {
                appClassALL.append(ac)
                let parts = ac.version.components(separatedBy: ".")
                appVerAllMajorOnly.append(parts.first ?? "")
                let majorMinor = (parts.count >= 2) ? "\(parts[0]).\(parts[1])" : parts[0]
                appVerAllMajorAndMinor.append(majorMinor)
            }
        }

        appClassALL.sort { $0.versionDouble < $1.versionDouble }
        appClassALLIncludeBeta.sort { $0.versionDouble < $1.versionDouble }
    }

    // MARK: - getAppALLRefresh（起動状態だけ更新）

    func getAppALLRefresh() {
        for ac in appClassALLIncludeBeta {
            ac.isBooted = isAppBooted(appURL: ac.appURL)
        }
    }

    // MARK: - openWithSameApp

    /// 同バージョンの Illustrator.app を探し、あれば ac.openFileURLs に追加して true を返す
    /// なければ fc.infoWindowMode に理由をセットして false を返す
    @discardableResult
    func openWithSameApp(fc: FileClass, reView: Bool = false, cmdKeyDown: Bool = false) -> Bool {
        let prefs = Preferences.shared

        // 下位バージョン保存されている
        if fc.isSavedLowerVersion {
            fc.infoWindowMode = 6
            return false
        }

        // Illustrator.app がインストールされていない
        if appClassALL.isEmpty {
            // Beta/Prerelease のみインストール済みの場合は通知ウィンドウを表示（バルーンなし）
            fc.infoWindowMode = appClassALLIncludeBeta.isEmpty ? 1 : 0
            return false
        }

        let parts = fc.determine_Created.components(separatedBy: ".")
        let myMajor = parts.first ?? ""
        let myMinor = parts.count >= 2 ? parts[1] : ""
        for ac in appClassALL {
            let appParts = ac.version.components(separatedBy: ".")
            let appMajor = appParts.first ?? ""
            let appMinor = appParts.count >= 2 ? appParts[1] : ""

            if appMajor == myMajor {
                fc.infoWindowMode = 0

                // メジャーのみ一致で開く設定
                if prefs.conditionsForOpeningAiFile == 1 {
                    return openWithSameAppCommonCheck(fc: fc, ac: ac, reView: reView, cmdKeyDown: cmdKeyDown)
                }

                // メジャー＋マイナー一致 or 常に通知
                if prefs.conditionsForOpeningAiFile == 0 || prefs.conditionsForOpeningAiFile == 2 {
                    if appMinor == myMinor {
                        return openWithSameAppCommonCheck(fc: fc, ac: ac, reView: reView, cmdKeyDown: cmdKeyDown)
                    } else {
                        // マイナーが違う → メジャー+マイナー一致アプリが存在するか確認
                        let fileVerMM = "\(myMajor).\(myMinor)"
                        if !appVerAllMajorAndMinor.contains(fileVerMM) {
                            fc.infoWindowMode = 2
                            break  // return せず beta チェックへ進む
                        }
                    }
                }
            } else {
                fc.infoWindowMode = 3
            }
        }
        // 非Beta では一致なし（mode 2 or 3）でも Beta/Prerelease に一致するものがあれば
        // バルーンを消して通知ウィンドウだけ表示（Beta は常に通知ウィンドウ経由で開く）
        if fc.infoWindowMode == 2 || fc.infoWindowMode == 3 {
            let hasBetaMatch = appClassALLIncludeBeta.contains { ac in
                let appParts = ac.version.components(separatedBy: ".")
                let appMajor = appParts.first ?? ""
                let appMinor = appParts.count >= 2 ? appParts[1] : ""
                let folder = ac.appURL.deletingLastPathComponent().lastPathComponent
                let isBeta = folder.contains("Beta") || folder.contains("Prerelease")
                return isBeta && appMajor == myMajor && appMinor == myMinor
            }
            if hasBetaMatch { fc.infoWindowMode = 0 }
        }

        return false
    }

    private func openWithSameAppCommonCheck(fc: FileClass, ac: IllustratorAppClass, reView: Bool, cmdKeyDown: Bool) -> Bool {
        let prefs = Preferences.shared

        if isAppBooted(appURL: ac.appURL) {
            fc.infoWindowMode = 0
            if cmdKeyDown || prefs.conditionsForOpeningAiFile == 2 {
                return false
            }
            if !reView {
                guard let fileURL = fc.file else { return false }
                ac.openFileURLs.append(fileURL)
            }
            return true
        } else {
            if !isOtherVerAppBooted(excluding: ac.appURL) {
                fc.infoWindowMode = 0
                if cmdKeyDown || prefs.conditionsForOpeningAiFile == 2 {
                    return false
                }
                if !reView {
                    guard let fileURL = fc.file else { return false }
                    ac.openFileURLs.append(fileURL)
                }
                return true
            } else {
                fc.infoWindowMode = 4
                return false
            }
        }
    }

    // MARK: - OpenWith（NSWorkspace で対象アプリを起動／前面化してファイルを開く）

    /// 完了ハンドラは Illustrator の起動／アクティブ化が完了した時点で呼ばれる。
    /// （Glow Ai 終了タイミングを Illustrator アクティブ化後に揃えるため必須）
    func openWith(appURL: URL, fileURLs: [URL], completion: @escaping () -> Void) {
        guard !fileURLs.isEmpty else { completion(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: config) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - isAppBooted

    func isAppBooted(appURL: URL) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardized == appURL.standardized
        }
    }

    func isOtherVerAppBooted(excluding targetURL: URL) -> Bool {
        for ac in appClassALLIncludeBeta {
            if ac.appURL.standardized != targetURL.standardized && isAppBooted(appURL: ac.appURL) {
                return true
            }
        }
        return false
    }

    // MARK: - willBootApp

    func isWillBootApp(appURL: URL) -> Bool {
        willBootAppClass.contains { $0.appURL.standardized == appURL.standardized }
    }

    func removeWillBootApp(appURL: URL) {
        willBootAppClass.removeAll {
            $0.appURL.standardized == appURL.standardized
        }
    }

    // MARK: - getMaximum / Minimum

    func getMaximumVerAppClass() -> IllustratorAppClass? {
        appClassALL.max { $0.versionDouble < $1.versionDouble }
    }

    /// Beta/Prerelease を含む中で最上位バージョン（ビルド番号含む比較）
    func getMaximumVerAppClassIncludeBeta() -> IllustratorAppClass? {
        appClassALLIncludeBeta.max { $0.versionDouble < $1.versionDouble }
    }

    func getMinimumVerAppClass() -> IllustratorAppClass? {
        appClassALL.min { $0.versionDouble < $1.versionDouble }
    }

    // MARK: - getIconFile

    /// onComplete は成功・失敗・中止のいずれの経路でも必ず最後に呼ばれる（後続処理の同期用）。
    func getIconFile(onSuccess: ((String) -> Void)? = nil,
                     onFailure: ((String) -> Void)? = nil,
                     onComplete: (() -> Void)? = nil) {
        guard let latest = getMaximumVerAppClass() else { onComplete?(); return }
        let resources = latest.appURL.appendingPathComponent("Contents/Resources")
        let fm = FileManager.default

        // .ai アイコン
        var aiIcon = resources.appendingPathComponent("ai_ai_primary.icns")
        if !fm.fileExists(atPath: aiIcon.path) {
            aiIcon = resources.appendingPathComponent("AI_File_Icon.icns")
        }
        guard fm.fileExists(atPath: aiIcon.path) else { onComplete?(); return }

        // .ait アイコン
        var aitIcon = resources.appendingPathComponent("ai_cc_ai_pad.icns")
        if !fm.fileExists(atPath: aitIcon.path) {
            aitIcon = resources.appendingPathComponent("AI_TemplateFile_Icon.icns")
        }
        guard fm.fileExists(atPath: aitIcon.path) else { onComplete?(); return }

        // .eps アイコン
        var epsIcon = resources.appendingPathComponent("ai_eps.icns")
        if !fm.fileExists(atPath: epsIcon.path) {
            epsIcon = resources.appendingPathComponent("AI_EPSFile_Icon.icns")
        }
        guard fm.fileExists(atPath: epsIcon.path) else { onComplete?(); return }

        // コピー先（自分のバンドル Resources）
        guard let myResources = Bundle.main.resourceURL else { onComplete?(); return }
        let destAI  = myResources.appendingPathComponent("ai_ai_primary.icns")
        let destAIT = myResources.appendingPathComponent("ai_cc_ai_pad.icns")
        let destEPS = myResources.appendingPathComponent("ai_eps.icns")

        do {
            try? fm.removeItem(at: destAI)
            try? fm.removeItem(at: destAIT)
            try? fm.removeItem(at: destEPS)
            try fm.copyItem(at: aiIcon,  to: destAI)
            try fm.copyItem(at: aitIcon, to: destAIT)
            try fm.copyItem(at: epsIcon, to: destEPS)
            Preferences.shared.appIconVersion = latest.version
            Preferences.shared.save()
            onSuccess?(latest.version)
            onComplete?()
        } catch {
            // 通常コピー失敗 → AppleScript で管理者権限コピー
            copyIconFilesWithAdminPrivileges(
                pairs: [(aiIcon, destAI), (aitIcon, destAIT), (epsIcon, destEPS)]
            ) { success in
                if success {
                    Preferences.shared.appIconVersion = latest.version
                    Preferences.shared.save()
                    onSuccess?(latest.version)
                } else {
                    onFailure?(latest.version)
                }
                onComplete?()
            }
        }
    }

    /// AppleScript の with administrator privileges を使ってファイルをコピーする
    private func copyIconFilesWithAdminPrivileges(
        pairs: [(src: URL, dest: URL)],
        completion: @escaping (Bool) -> Void
    ) {
        // cp コマンドを ; でつなぐ（各パスはシングルクォートでエスケープ済み）
        let cpCommands = pairs.map { pair in
            "cp -f \(shellEscape(pair.src.path)) \(shellEscape(pair.dest.path))"
        }.joined(separator: " ; ")

        let source = """
        do shell script "\(cpCommands)" with administrator privileges
        """

        // 認証ダイアログはメインスレッドでないと表示されないため main で実行する
        DispatchQueue.main.async {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            script?.executeAndReturnError(&error)
            completion(error == nil)
        }
    }

    // MARK: - Private helpers

    private func getAppFullVersion(appBundle: URL) -> String {
        guard let bundle = Bundle(url: appBundle),
              let ver = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return "" }
        return ver
    }

    private func versionToDouble(_ ver: String) -> Double {
        let parts = ver.components(separatedBy: ".")
        var result: Double = 0
        let weights: [Double] = [1_000_000_000, 1_000_000, 1_000, 1]
        for (i, p) in parts.prefix(4).enumerated() {
            result += (Double(p) ?? 0) * weights[i]
        }
        return result
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

// MARK: - NSImage resize helper（PhotoshopApp.swift からも使用）

extension NSImage {
    func resized(to size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy, fraction: 1)
        img.unlockFocus()
        return img
    }
}
