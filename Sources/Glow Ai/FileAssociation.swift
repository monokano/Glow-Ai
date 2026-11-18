import AppKit
import UniformTypeIdentifiers

/// .ai / .ait / .eps のファイル関連付け（環境設定の「関連付ける」ボタンからだけ使う。HANDOFF ステップ6）。
///
/// 起動時に自動で関連付けることはしない（ステップ3で廃止。仕様を知らないユーザーが混乱するため）。
///
/// macOS 26.4 以降、NSWorkspace.setDefaultApplication(at:toOpen:) は確認の仕組みに回される
/// （2026-11-08、macOS 27.2 で実測。App-共有資料/ファイル関連付け_macOS26.4以降.md）：
/// - 現在の関連付け先と同じ Bundle ID への変更は「変更なし」とみなされ、何も起きない（ダイアログも出ない）
/// - Bundle ID が違うアプリへの変更は、種類ごとに確認ダイアログが出る。許可しても保存されるのは
///   Bundle ID だけで、バージョンは選べない（同じ Bundle ID の最新版になる）
/// - 「変更しない」を押すと userCanceledErr が返る。それ以外はエラーなしでも反映されたとは限らないので読み直す
/// secure.plist を直接書き換える方法は lsd がクラッシュを繰り返すことがあるので使わない。
enum FileAssociation {

    static let types: [UTType] = [
        "com.adobe.illustrator.ai-image",
        "com.adobe.illustrator.ait-template",
        "com.adobe.encapsulated-postscript",
    ].compactMap { UTType($0) }

    /// 関連付け先の選択肢
    enum Target {
        /// Glow Ai 自身
        case glowAi
        /// インストール済みの正式版 Illustrator の最上位（Beta などの正規版以外は除く）
        case illustrator

        /// 関連付けに使うアプリの URL。正式版 Illustrator が無ければ nil
        var appURL: URL? {
            switch self {
            case .glowAi:      return Bundle.main.bundleURL
            case .illustrator: return IllustratorApp.shared.getMaximumVerAppClass()?.appURL
            }
        }

        /// 画面に出す名前（例：「Adobe Illustrator 2026」）
        var displayName: String? {
            switch self {
            case .glowAi:
                return "Glow Ai"
            case .illustrator:
                // アプリ本体は「Adobe Illustrator.app」で年号が無いので、親フォルダ名
                //（「Adobe Illustrator 2026」）を使う。想定外の置き方ならアプリ名
                guard let url = appURL else { return nil }
                let folder = url.deletingLastPathComponent().lastPathComponent
                return folder.hasPrefix("Adobe Illustrator")
                    ? folder
                    : url.deletingPathExtension().lastPathComponent
            }
        }
    }

    /// 3種類とも target のアプリ（Bundle ID）に関連付けられているか
    static func isAssociated(with target: Target) -> Bool {
        guard let url = target.appURL else { return false }
        return typesNeedingChange(to: url).isEmpty
    }

    /// 現在の関連付け先の Bundle ID が、appURL のアプリと違う種類
    static func typesNeedingChange(to appURL: URL) -> [UTType] {
        guard let targetID = Bundle(url: appURL)?.bundleIdentifier else { return types }
        return types.filter { type in
            guard let current = NSWorkspace.shared.urlForApplication(toOpen: type),
                  let currentID = Bundle(url: current)?.bundleIdentifier else { return true }
            return currentID.caseInsensitiveCompare(targetID) != .orderedSame
        }
    }

    /// apply の結果
    enum Outcome {
        /// すべて反映された
        case applied
        /// 確認ダイアログで「“〜”のままにする」が押された。changedSome は、それより前の種類で変わったものがあるか
        case kept(changedSome: Bool)
        /// エラーなしでも反映されなかった（Finder の手順を案内する）
        case notApplied
    }

    /// 種類を appURL のアプリに関連付け、結果を返す（反映は Bundle ID を読み直して確かめる）。
    /// 確認ダイアログが出た場合は、ユーザーが答えるまで完了しない
    static func apply(_ targets: [UTType], to appURL: URL, completion: @escaping (Outcome) -> Void) {
        Task {
            var canceled = false
            for type in targets {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    // 確認ダイアログで「“〜”のままにする」を押すと userCanceledErr（-128）が返る（macOS 27.2 で実測）。
                    // ユーザーの選択なので失敗扱いにしない。残りの種類でダイアログを出し続けないよう、そこで止める
                    if isUserCanceled(error) { canceled = true; break }
                }
            }
            // 反映の遅れで誤判定しないよう、変わっていなければ少し待って読み直す
            var remaining = typesNeedingChange(to: appURL).filter { targets.contains($0) }
            if !remaining.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining = typesNeedingChange(to: appURL).filter { targets.contains($0) }
            }
            if remaining.isEmpty {
                completion(.applied)
            } else if canceled {
                completion(.kept(changedSome: remaining.count < targets.count))
            } else {
                completion(.notApplied)
            }
        }
    }

    /// NSCocoaErrorDomain 256 の中に userCanceledErr（-128）が入っている形で返る
    private static func isUserCanceled(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == userCanceledErr { return true }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isUserCanceled(underlying)
        }
        return false
    }

    /// 関連付けが反映されなかったときの案内
    static func showNotAppliedAlert(for window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The file association was not changed.")
        alert.informativeText = String(localized: "macOS security may prevent this change. In the Finder, select a .ai, .ait, or .eps file, choose Get Info, choose the app in \"Open with\", and click \"Change All…\".")
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
