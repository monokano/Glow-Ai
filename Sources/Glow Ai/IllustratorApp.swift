
import AppKit
import Foundation

// MARK: - IconImportProblem（アイコン取込が失敗した原因）

/// 自分のバンドルにアイコンを書き込めない理由。環境設定で、ボタンを押せない理由の表示に使う。
enum IconImportProblem {
    /// App Translocation（隔離属性付きで読み取り専用のランダムパスから起動）
    case translocated
    /// バンドル内ファイルが管理者（root）所有になっている
    case rootOwned
    /// その他、設置場所に書き込めない
    case notWritable
}

// MARK: - AppTranslocation（隔離起動の判定）

/// App Translocation（隔離属性付きのアプリを Finder で移動せずに起動したとき、
/// 読み取り専用の一時的な場所から実行される macOS の仕組み）の判定。
/// 共通資料 App-共有資料/AppTranslocation対策.md を参照。
enum AppTranslocation {
    private static let securityHandle =
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    /// 隔離起動しているか。
    /// `SecTranslocateIsTranslocatedURL` を dlsym で呼び、取得できなければパスで判定する。
    static func isTranslocated(_ url: URL) -> Bool {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        if let handle = securityHandle,
           let sym = dlsym(handle, "SecTranslocateIsTranslocatedURL") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            var isTrans = false
            var err: Unmanaged<CFError>? = nil
            if fn(url as CFURL, &isTrans, &err).boolValue { return isTrans }
            err?.release()   // 失敗時に返る CFError を解放（リーク防止）
        }
        return url.path.contains("/AppTranslocation/")
    }

    /// 隔離起動中のアプリの元の場所。
    /// `SecTranslocateCreateOriginalPathForURL`（公開ヘッダに無い）を dlsym で呼ぶ。取得できなければ nil。
    static func originalURL(of url: URL) -> URL? {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = securityHandle,
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var err: Unmanaged<CFError>? = nil
        guard let original = fn(url as CFURL, &err)?.takeRetainedValue() else {
            err?.release()
            return nil
        }
        return original as URL
    }

    /// 元の場所がアプリケーションフォルダ（/Applications または ~/Applications）の中か。
    /// アプリケーションフォルダの中で ZIP を展開した場合などに当たる。
    static func isInApplicationsFolder(_ url: URL) -> Bool {
        let appDirs = FileManager.default.urls(for: .applicationDirectory,
                                               in: [.localDomainMask, .userDomainMask])
        let path = url.standardizedFileURL.path
        return appDirs.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}

// MARK: - AppClass（Illustratorアプリ1本分のデータモデル）

class IllustratorAppClass {
    var appURL: URL
    var version: String = ""
    /// ソート用数値（major*1e9 + minor*1e6 + patch*1e3 + build）
    var versionDouble: Double = 0
    /// 正規版以外（(Beta)・Prerelease・Debug など）。getAppALL で isBetaFolder により決まる
    var isBeta: Bool = false
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

    /// 正規版のみ（isBeta の版を除外）、バージョン昇順
    var appClassALL: [IllustratorAppClass] = []
    /// 正規版以外（(Beta)・Prerelease・Debug など）も含む全アプリ、バージョン昇順（同じバージョンなら正規版が先）
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

            // Illustrator.app を探す（Debug 版などバンドル名が違う場合にも対応）
            guard let appBundleURL = findIllustratorApp(in: entry),
                  fm.fileExists(atPath: appBundleURL.path) else { continue }

            let ac = IllustratorAppClass(appURL: appBundleURL)
            ac.version = getAppFullVersion(appBundle: appBundleURL)
            ac.versionDouble = versionToDouble(ac.version)
            ac.isBeta = IllustratorApp.isBetaFolder(entry.lastPathComponent)
            ac.isBooted = isAppBooted(appURL: appBundleURL)
            ac.icon = NSImage.appIcon(at: appBundleURL)
                        .resized(to: NSSize(width: 18, height: 18))

            appClassALLIncludeBeta.append(ac)

            if !ac.isBeta {
                appClassALL.append(ac)
                let parts = ac.version.components(separatedBy: ".")
                appVerAllMajorOnly.append(parts.first ?? "")
                let majorMinor = (parts.count >= 2) ? "\(parts[0]).\(parts[1])" : parts[0]
                appVerAllMajorAndMinor.append(majorMinor)
            }
        }

        appClassALL.sort { IllustratorApp.isAscending($0, $1) }
        appClassALLIncludeBeta.sort { IllustratorApp.isAscending($0, $1) }
    }

    /// 正規版のフォルダ名は「Adobe Illustrator」＋次のどれかだけのもの。
    ///   数字（"2026"）／ CC ＋年号（"CC 2019"）／ CC 単体 ／ CS 系（"CS6" "CS5.1" "CS"）
    /// それ以外（(Beta)・Prerelease・Debug・Finder での複製など）はすべて Beta 扱いにする。
    /// Debug 版は Info.plist が正規版と同一のため、フォルダ名以外に手がかりがない。
    /// 年号の無い CC・CS 系は 32bit で現行 macOS では起動できないが、念のため正規版として扱う。
    private static func isBetaFolder(_ folderName: String) -> Bool {
        folderName.range(of: "^Adobe Illustrator (CC( [0-9.]+)?|CS[0-9.]*|[0-9.]+)$",
                         options: .regularExpression) == nil
    }

    /// バージョン昇順。同じバージョンなら正規版を先に並べる
    /// （Debug 版や複製は正規版と同じバージョンになるため、並び順をフォルダの列挙順任せにしない）
    private static func isAscending(_ a: IllustratorAppClass, _ b: IllustratorAppClass) -> Bool {
        if a.versionDouble != b.versionDouble { return a.versionDouble < b.versionDouble }
        return !a.isBeta && b.isBeta
    }

    private func findIllustratorApp(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: []) else { return nil }
        return contents.first { $0.pathExtension == "app" && $0.lastPathComponent.contains("Illustrator") }
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
            // Beta 扱いの版（正規版以外）のみインストール済みの場合は通知ウィンドウを表示（バルーンなし）
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
        // 非Beta では一致なし（mode 2 or 3）でも Beta 扱いの版（正規版以外）に一致するものがあれば
        // バルーンを消して通知ウィンドウだけ表示（Beta は常に通知ウィンドウ経由で開く）
        if fc.infoWindowMode == 2 || fc.infoWindowMode == 3 {
            let hasBetaMatch = appClassALLIncludeBeta.contains { ac in
                let appParts = ac.version.components(separatedBy: ".")
                let appMajor = appParts.first ?? ""
                let appMinor = appParts.count >= 2 ? appParts[1] : ""
                return ac.isBeta && appMajor == myMajor && appMinor == myMinor
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

    /// Beta を含む中で最上位バージョン（ビルド番号含む比較）。同じバージョンなら正規版を優先する
    /// （オフ時の関連付け先が Debug 版や複製にならないように）
    func getMaximumVerAppClassIncludeBeta() -> IllustratorAppClass? {
        appClassALLIncludeBeta.max { a, b in
            if a.versionDouble != b.versionDouble { return a.versionDouble < b.versionDouble }
            return a.isBeta && !b.isBeta
        }
    }

    func getMinimumVerAppClass() -> IllustratorAppClass? {
        appClassALL.min { $0.versionDouble < $1.versionDouble }
    }

    // MARK: - アイコン取込（環境設定のボタンから。HANDOFF ステップ7）

    /// 自分のバンドル内のコピー先（.ai／.ait／.eps）。Info.plist の CFBundleTypeIconFile と同じ名前
    private static let iconFileNames = ["ai_ai_primary.icns", "ai_cc_ai_pad.icns", "ai_eps.icns"]

    /// 最上位の正規版 Illustrator 内のアイコン（.ai／.ait／.eps の順）。見つからなければ nil
    func latestIconSources() -> [URL]? {
        guard let latest = getMaximumVerAppClass() else { return nil }
        let resources = latest.appURL.appendingPathComponent("Contents/Resources")
        let candidates = [
            ["ai_ai_primary.icns", "AI_File_Icon.icns"],
            ["ai_cc_ai_pad.icns", "AI_TemplateFile_Icon.icns"],
            ["ai_eps.icns", "AI_EPSFile_Icon.icns"],
        ]
        var urls: [URL] = []
        for names in candidates {
            guard let found = names.map({ resources.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            urls.append(found)
        }
        return urls
    }

    /// 自分のバンドルにアイコンを書き込めない理由。書き込めるなら nil。
    /// ボタンを押す前に調べて、押せない状態にするために使う
    func iconImportProblem() -> IconImportProblem? {
        guard let myResources = Bundle.main.resourceURL else { return .notWritable }
        if isTranslocated(Bundle.main.bundleURL) { return .translocated }
        // 置き換え（削除＋コピー）には Resources フォルダへの書き込み権限が要る
        if FileManager.default.isWritableFile(atPath: myResources.path) { return nil }
        let destAI = myResources.appendingPathComponent(Self.iconFileNames[0])
        if ownerUID(destAI.path) == 0 || ownerUID(myResources.path) == 0 { return .rootOwned }
        return .notWritable
    }

    /// 自分のバンドルのアイコンが、最上位の正規版 Illustrator のものと同じか
    func iconsAreUpToDate() -> Bool {
        guard let sources = latestIconSources(),
              let myResources = Bundle.main.resourceURL else { return false }
        for (src, name) in zip(sources, Self.iconFileNames) {
            let dest = myResources.appendingPathComponent(name)
            guard let a = try? Data(contentsOf: src),
                  let b = try? Data(contentsOf: dest),
                  a == b else { return false }
        }
        return true
    }

    /// 最上位の正規版 Illustrator のアイコンを自分のバンドルにコピーする（in-process の FileManager のみ。
    /// 管理者パスワードは要求しない）。成功なら true
    func importIcons() -> Bool {
        guard let sources = latestIconSources(),
              let myResources = Bundle.main.resourceURL else { return false }
        let fm = FileManager.default
        var changed = false
        do {
            for (src, name) in zip(sources, Self.iconFileNames) {
                let dest = myResources.appendingPathComponent(name)
                // 中身が同じなら触らない（ステップ8：置き換えのたびに Finder のアイコンが白紙になる原因になる）
                if let a = try? Data(contentsOf: src), let b = try? Data(contentsOf: dest), a == b { continue }
                // 削除→コピーだと一瞬ファイルが無くなり、Finder がその間に白紙のアイコンを覚えてしまう
                //（2026-11-08 実機で .ai が真っ白に）。同じフォルダに一時コピーを作り、入れ替える
                let temp = myResources.appendingPathComponent(".\(name).importing")
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: src, to: temp)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: dest)
                }
                changed = true
            }
        } catch {
            return false
        }
        if changed { Self.refreshIconCache() }
        return true
    }

    /// 書類アイコンを変えたことを LaunchServices と Finder に知らせる。
    /// バンドルの更新日時を変えて再登録すると、書類アイコンが読み直される
    static func refreshIconCache() {
        let bundleURL = Bundle.main.bundleURL
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundleURL.path)
        LSRegisterURL(bundleURL as CFURL, true)
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
    }

    // MARK: - 設置状態の診断

    /// App Translocation（隔離属性付きで読み取り専用のランダムパス）から起動しているか。
    private func isTranslocated(_ url: URL) -> Bool {
        AppTranslocation.isTranslocated(url)
    }

    /// 指定パスの所有者 UID（root = 0／取得不可なら nil）
    private func ownerUID(_ path: String) -> uid_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_uid : nil
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

}

// MARK: - NSImage resize helper（PhotoshopApp.swift からも使用）

extension NSImage {
    /// アプリのアイコン。Info.plist の CFBundleIconFile の .icns を直接読む。
    /// macOS 26 以降の NSWorkspace.icon(forFile:) は、Icon Composer 形式のアイコンを持たないアプリ
    ///（Adobe 製品など）のアイコンを縮めてグレーの角丸の枠に入れて返すため、18pt のリストでは
    /// グレーの囲みが目立つ（HANDOFF ステップ12）。読めなければ従来どおり NSWorkspace を使う
    static func appIcon(at appURL: URL) -> NSImage {
        if let name = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !name.isEmpty {
            let file = name.hasSuffix(".icns") ? name : name + ".icns"
            let url = appURL.appendingPathComponent("Contents/Resources").appendingPathComponent(file)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

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
