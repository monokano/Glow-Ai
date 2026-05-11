
import AppKit
import Foundation

// MARK: - PhotoshopAppClass（Photoshopアプリ1本分のデータモデル）

class PhotoshopAppClass {
    var appURL: URL
    var version: String = ""
    var isBooted: Bool = false
    var icon: NSImage?
    var openFileURLs: [URL] = []

    init(appURL: URL) {
        self.appURL = appURL
    }
}

// MARK: - PhotoshopApp（Photoshopアプリ管理モジュール）

class PhotoshopApp {

    static let shared = PhotoshopApp()
    private init() {}

    var appClassALL: [PhotoshopAppClass] = []

    // MARK: - getAppALL

    func getAppALL() {
        appClassALL = []
        var sortKeys: [Double] = []

        let fm = FileManager.default
        let appsURL = URL(fileURLWithPath: "/Applications")
        guard let entries = try? fm.contentsOfDirectory(
            at: appsURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }

        for entry in entries {
            guard entry.lastPathComponent.contains("Adobe Photoshop") else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            // フォルダ内の "Adobe Photoshop*.app" を探す
            guard let children = try? fm.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil, options: []) else { continue }

            for child in children {
                let name = child.lastPathComponent
                guard name.hasPrefix("Adobe Photoshop") && name.hasSuffix(".app") else { continue }

                let ac = PhotoshopAppClass(appURL: child)
                ac.version = getAppFullVersion(appBundle: child)
                // "x.xxx" 以降を除去（Xojo: RegExMBS_ReplaceAll(ver, "x.+", "")）
                if let range = ac.version.range(of: #"x.+"#, options: .regularExpression) {
                    ac.version = String(ac.version[..<range.lowerBound])
                }
                ac.isBooted = isAppBooted(appURL: child)
                ac.icon = NSWorkspace.shared.icon(forFile: child.path)
                            .resized(to: NSSize(width: 18, height: 18))

                appClassALL.append(ac)
                sortKeys.append(Double(ac.version) ?? 0)
            }
        }

        // バージョン昇順ソート
        let sorted = zip(sortKeys, appClassALL).sorted { $0.0 < $1.0 }
        appClassALL = sorted.map { $0.1 }
    }

    // MARK: - getAppALLRefresh（起動状態だけ更新）

    func getAppALLRefresh() {
        for ac in appClassALL {
            ac.isBooted = isAppBooted(appURL: ac.appURL)
        }
    }

    // MARK: - getAppName

    static func versionName(_ ver: String) -> String {
        let major = Int(ver.components(separatedBy: ".").first ?? "") ?? 0
        return major > 0 ? "\(major + 1999)" : ver
    }

    func getAppName(pc: PhotoshopAppClass) -> String {
        let folderName = pc.appURL.deletingLastPathComponent().lastPathComponent
        return folderName.replacingOccurrences(of: "Adobe Photoshop ", with: "")
    }

    // MARK: - isAppBooted

    func isAppBooted(appURL: URL) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardized == appURL.standardized
        }
    }

    // MARK: - openWith

    func openWith(appURL: URL, fileURLs: [URL], completion: @escaping () -> Void) {
        guard !fileURLs.isEmpty else { completion(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: config) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Private helpers

    private func getAppFullVersion(appBundle: URL) -> String {
        let plistURL = appBundle.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) else { return "" }
        // "Adobe Product Version" を優先、なければ CFBundleVersion
        if let v = dict["Adobe Product Version"] as? String { return v }
        return dict["CFBundleVersion"] as? String ?? ""
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

