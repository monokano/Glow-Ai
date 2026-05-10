
import Foundation

class FileClass {

    // MARK: - ファイル本体
    var file: URL?

    // MARK: - 種別
    /// "Ai" / "EPS" / "PDF"（Illustrator編集機能保持PDFを .ai に偽装したもの）
    var kind: String = ""

    // MARK: - アプリ判定
    /// "Illustrator" または "Photoshop"
    var appName: String = ""
    var isIllustratorFile: Bool = false
    /// true = 本物の Illustrator テンプレート（.ait）形式
    var isTemplate: Bool = false

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
}
