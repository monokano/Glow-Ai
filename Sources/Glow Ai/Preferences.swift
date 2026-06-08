
import Foundation

/// アプリ全体の設定。UserDefaults に保存。
class Preferences {

    static let shared = Preferences()
    private init() { load() }

    private let defaults = UserDefaults.standard

    // MARK: - 設定項目

    /// Aiファイルを開く条件
    /// 0 = メジャー＋マイナー一致で開く
    /// 1 = メジャーバージョンのみ一致で開く
    /// 2 = 常に通知ウインドウを表示
    var conditionsForOpeningAiFile: Int = 0

    /// 上位バージョンのアプリで開くことを許可
    var allowOpeningInHigherVersion: Bool = false

    /// 互換（下位）バージョンのアプリで開くことを許可
    var allowedToOpenInLowerVersion: Bool = false

    /// 通知ウインドウの「終了」ボタンをデフォルトにする
    var activateTheQuitButton: Bool = false

    /// 読込サイズ制限（タイムアウト）を使う
    var useTimeLimit: Bool = true

    /// 制限時間（秒）1〜10
    var timeLimit: Int = 5

    /// EPSの互換バージョンを検出しない
    var isNotDetectEPSCompatibleVer: Bool = true

    /// 起動時にファイル関連付けを自動登録する（.ai / .ait / .eps）
    var autoClaimFileAssociations: Bool = true

    /// ファイルアイコン取込完了を通知しない（完了・失敗ダイアログを抑制）
    var doNotNotifyIconImport: Bool = false

    /// 通知ウインドウの幅
    var infoWindowWidth: Int = 450

    /// 詳細情報シートの幅
    var moreInfoSheetWidth: Int = 450

    /// アイコン更新判定用（非リリースバージョン番号）
    var nonReleaseVersion: Int = 0

    /// 最後にコピーしたアイコンの Illustratorバージョン
    var appIconVersion: String = ""

    // MARK: - Keys

    private enum Key: String {
        case conditionsForOpeningAiFile
        case allowOpeningInHigherVersion
        case allowedToOpenInLowerVersion
        case activateTheQuitButton
        case useTimeLimit
        case timeLimit
        case isNotDetectEPSCompatibleVer
        case autoClaimFileAssociations
        case doNotNotifyIconImport
        case infoWindowWidth
        case moreInfoSheetWidth
        case nonReleaseVersion
        case appIconVersion
    }

    // MARK: - Load / Save

    func load() {
        let d = defaults
        conditionsForOpeningAiFile  = d.object(forKey: Key.conditionsForOpeningAiFile.rawValue)  as? Int  ?? 0
        allowOpeningInHigherVersion  = d.object(forKey: Key.allowOpeningInHigherVersion.rawValue)  as? Bool ?? false
        allowedToOpenInLowerVersion  = d.object(forKey: Key.allowedToOpenInLowerVersion.rawValue)  as? Bool ?? false
        activateTheQuitButton        = d.object(forKey: Key.activateTheQuitButton.rawValue)        as? Bool ?? false
        useTimeLimit                 = d.object(forKey: Key.useTimeLimit.rawValue)                 as? Bool ?? true
        timeLimit                    = d.object(forKey: Key.timeLimit.rawValue)                    as? Int  ?? 5
        isNotDetectEPSCompatibleVer  = d.object(forKey: Key.isNotDetectEPSCompatibleVer.rawValue)  as? Bool ?? true
        autoClaimFileAssociations    = d.object(forKey: Key.autoClaimFileAssociations.rawValue)    as? Bool ?? true
        doNotNotifyIconImport        = d.object(forKey: Key.doNotNotifyIconImport.rawValue)        as? Bool ?? false
        infoWindowWidth              = d.object(forKey: Key.infoWindowWidth.rawValue)              as? Int  ?? 450
        moreInfoSheetWidth           = d.object(forKey: Key.moreInfoSheetWidth.rawValue)           as? Int  ?? 450
        nonReleaseVersion            = d.object(forKey: Key.nonReleaseVersion.rawValue)            as? Int  ?? 0
        appIconVersion               = d.string(forKey: Key.appIconVersion.rawValue)               ?? ""
    }

    func save() {
        let d = defaults
        d.set(conditionsForOpeningAiFile,  forKey: Key.conditionsForOpeningAiFile.rawValue)
        d.set(allowOpeningInHigherVersion,  forKey: Key.allowOpeningInHigherVersion.rawValue)
        d.set(allowedToOpenInLowerVersion,  forKey: Key.allowedToOpenInLowerVersion.rawValue)
        d.set(activateTheQuitButton,        forKey: Key.activateTheQuitButton.rawValue)
        d.set(useTimeLimit,                 forKey: Key.useTimeLimit.rawValue)
        d.set(timeLimit,                    forKey: Key.timeLimit.rawValue)
        d.set(isNotDetectEPSCompatibleVer,  forKey: Key.isNotDetectEPSCompatibleVer.rawValue)
        d.set(autoClaimFileAssociations,    forKey: Key.autoClaimFileAssociations.rawValue)
        d.set(doNotNotifyIconImport,        forKey: Key.doNotNotifyIconImport.rawValue)
        d.set(infoWindowWidth,              forKey: Key.infoWindowWidth.rawValue)
        d.set(moreInfoSheetWidth,           forKey: Key.moreInfoSheetWidth.rawValue)
        d.set(nonReleaseVersion,            forKey: Key.nonReleaseVersion.rawValue)
        d.set(appIconVersion,               forKey: Key.appIconVersion.rawValue)
    }
}
