
import Foundation

class FileClass {

    // MARK: - ファイル本体
    var file: URL?

    // MARK: - 種別
    /// "Ai" / "EPS" / "PDF" / "PSD" / "PSB"（PSD=8BPS version1 / PSB=version2）
    var kind: String = ""

    // MARK: - アプリ判定
    /// "Illustrator" または "Photoshop"
    var appName: String = ""
    var isIllustratorFile: Bool = false
    /// true = 本物の Illustrator テンプレート（.ait）形式
    var isTemplate: Bool = false
    /// true = Photoshop編集機能保持PDF（/PieceInfo/AdobePhotoshop）
    var isPhotoshopEditablePDF: Bool = false

    // MARK: - バージョン判定結果
    /// 作成バージョン（例: "25.0.0"）← マッチングの主キー
    var determine_Created: String = ""
    /// 互換（保存）バージョン
    var determine_Saved: String = ""
    var isSavedLowerVersion: Bool = false

    // MARK: - 生の検出値
    var ai8_CreatorVersion: String = ""
    var creator1: String = ""
    var creator2: String = ""
    var hasCreator2: Bool = true
    var xmp_CreatorTool: String = ""
    var finderInfo_Creator: String = ""
    var finderInfo_FileType: String = ""

    // MARK: - Photoshop バージョン（PSD/PSB=cinf psVersion / EPS=%%Creator）
    /// 例 "26.11.5"。表示専用（インストール済み Photoshop との照合には使わない）
    var psVersion: String = ""

    // MARK: - 状態フラグ
    var isTimeOut: Bool = false

    // MARK: - InfoWindow 表示モード
    /// 0: 正常（手動表示）
    /// 1: Illustrator.app がインストールされていない
    /// 2: マイナーバージョン一致のアプリがない
    /// 3: メジャーバージョン一致のアプリがない
    /// 4: 別バージョンのアプリが起動中
    /// 5: バージョンを検出できなかった
    /// 6: 下位バージョン保存されている
    /// 10: Illustrator ファイルではない
    /// 11: 制限時間超過でバージョン検出できなかった
    /// 12: Illustrator 編集機能を保持した PDF
    var infoWindowMode: Int = 0

    // MARK: - 処理時間（表示用）
    var time_AI8_CreatorVersion: String = ""
    var time_Creator1: String = ""
    var time_Creator2: String = ""
    var time_XMP_CreatorTool: String = ""
    var time_TotalSeconds: String = ""

    // MARK: - 種類の危険判定（種類バルーンを赤にする条件＝拡張子がコンテンツ種別と不一致）
    /// 各形式で正規の拡張子以外のファイルは true。D（その他・kind未確定）は常に true。
    /// 種類バルーンの色（InfoWindow）と Photoshop の警告バッジ表示で共用する。
    var isKindDangerous: Bool {
        let ext = file?.pathExtension.lowercased() ?? ""
        if kind == "PDF"                              { return ext != "pdf" }  // A1 / A1b / A3
        if kind == "Ai"  && isIllustratorFile && isTemplate { return ext != "ai" && ext != "ait" }  // A2b
        if kind == "Ai"  && isIllustratorFile         { return ext != "ai" && ext != "ait" }  // A2
        if kind == "EPS" && isIllustratorFile         { return ext != "eps" }  // B1
        if kind == "EPS" && appName == "Photoshop"    { return ext != "eps" }  // B2
        if kind == "PSD"                              { return ext != "psd" }  // C1
        if kind == "PSB"                              { return ext != "psb" }  // C2
        return true  // D: 常に赤
    }
}
