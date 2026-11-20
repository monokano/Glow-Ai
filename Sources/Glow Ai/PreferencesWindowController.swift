
import AppKit
import SwiftUI
import Combine

// 設定ウインドウ。
// 見た目は SwiftUI の標準フォーム（Form ＋ .formStyle(.grouped)）＝ OS 純正の設定画面と同じ部品で描く。
// macOS 26 で窓の地がほぼ白になり、区切り線で仕切っただけの AppKit 版が白一色に見えたため、
// いったん AppKit で「薄いグレーのカード」を再現したが、浮紙（同じ作り方）と比べて純正に近い
// 標準フォームへ移した（2026-11-09、HANDOFF ステップ15）。色や寸法は OS 任せ。
// ウインドウは AppKit（NSHostingController）で持ち、AppDelegate からの呼び方は従来どおり。

class PreferencesWindowController: NSWindowController {

    private let model = PreferencesModel()

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PreferencesView.width, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = String(localized: "Glow Ai Preferences")
        win.isReleasedWhenClosed = false
        super.init(window: win)

        // SwiftUI 側の理想サイズ（幅固定・高さは内容）へウインドウを追従させる
        let hosting = NSHostingController(rootView: PreferencesView(model: model))
        hosting.sizingOptions = .preferredContentSize
        win.contentViewController = hosting
        model.window = win
        // 置く前に内容の高さへ合わせる。仮の高さ（320）のまま置くと、後から下へ伸びてずれる
        win.setContentSize(hosting.view.fittingSize)
        placeWindow()

        // 開いたまま Finder で関連付けを変えたり Illustrator を更新したりしても、
        // 戻ってきたときにボタンの有効／無効が現状に合うよう読み直す
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main
        ) { [weak self] _ in
            self?.model.refreshOnBecomeKey()
        }
        // 閉じたときの位置を覚える（開いたまま終了した場合に備え、動かしたときも覚える）
        for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification] {
            positionObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: win, queue: .main
            ) { [weak self] _ in
                self?.savePosition()
            })
        }
    }

    private var becomeKeyObserver: NSObjectProtocol?
    private var positionObservers: [NSObjectProtocol] = []

    deinit {
        if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        positionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 開くたびに関連付けとアイコンの現状を読み直す（Finder で変えられていることがあるため）
    override func showWindow(_ sender: Any?) {
        // 閉じている間にディスプレイの構成が変わっていることがあるので、開くたびに画面内へ収め直す
        if window?.isVisible == false { fitOnScreen() }
        super.showWindow(sender)
        model.refreshOnShow()
    }

    // MARK: 位置（2026-11-19：最後に閉じた位置で開く。ディスプレイからはみ出すなら収める。Glow Id と同じ）

    /// ウインドウの左上の点（スクリーン座標）。高さは内容で変わるので、上端の位置で覚える
    private static let positionKey = "preferencesWindowTopLeft"

    private func placeWindow() {
        guard let win = window else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            win.setFrameTopLeftPoint(NSPointFromString(saved))
            fitOnScreen()
        } else {
            win.center()
        }
    }

    private func savePosition() {
        guard let win = window else { return }
        let topLeft = NSPoint(x: win.frame.minX, y: win.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.positionKey)
    }

    /// 重なっているディスプレイ（無ければメインのディスプレイ）の、メニューバーと Dock を除いた範囲に収める。
    /// 画面より高いときはタイトルバーが見えるよう上端を優先する
    private func fitOnScreen() {
        guard let win = window else { return }
        var frame = win.frame
        let screen = NSScreen.screens
            .max { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }
            .flatMap { $0.visibleFrame.intersects(frame) ? $0 : nil }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }

        if frame.maxX > area.maxX { frame.origin.x = area.maxX - frame.width }
        if frame.minX < area.minX { frame.origin.x = area.minX }
        if frame.minY < area.minY { frame.origin.y = area.minY }
        if frame.maxY > area.maxY { frame.origin.y = area.maxY - frame.height }
        if frame.origin != win.frame.origin { win.setFrameOrigin(frame.origin) }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Model

final class PreferencesModel: ObservableObject {

    weak var window: NSWindow?

    // ── 一般の設定（変更したらすぐ保存）
    /// 常に通知ウインドウを表示する（conditionsForOpeningAiFile == 2）
    @Published var alwaysNotify: Bool {
        didSet { Preferences.shared.conditionsForOpeningAiFile = alwaysNotify ? 2 : 0; Preferences.shared.save() }
    }
    @Published var notDetectEPS: Bool {
        didSet { Preferences.shared.isNotDetectEPSCompatibleVer = notDetectEPS; Preferences.shared.save() }
    }
    @Published var useTimeLimit: Bool {
        didSet { Preferences.shared.useTimeLimit = useTimeLimit; Preferences.shared.save() }
    }
    @Published var timeLimit: Double {
        didSet {
            guard Int(timeLimit) != Preferences.shared.timeLimit else { return }
            Preferences.shared.timeLimit = Int(timeLimit); Preferences.shared.save()
        }
    }

    var timeLimitTitle: String {
        String(format: String(localized: "Limit read time (%lld sec)"), Int(timeLimit))
    }

    // ── ファイルの関連付け（ステップ6）
    /// ユーザーが選び直したら状態表示を消す（プログラムで選び直すときは消さない）
    @Published var selectedTarget: FileAssociation.Target = .glowAi {
        didSet { if !isSelectingProgrammatically { assocStatus = "" } }
    }
    private var isSelectingProgrammatically = false
    @Published var glowAiTitle = "Glow Ai"
    @Published var illustratorTitle = ""
    @Published var illustratorAvailable = false
    @Published var assocStatus = ""
    /// 関連付けの処理中（確認ダイアログの応答待ちを含む）
    @Published var isAssociating = false
    /// 3種類とも関連付いている「（現在）」のアプリ。種類ごとにばらばらなら nil
    @Published private(set) var currentTarget: FileAssociation.Target?
    /// 「関連付ける」を押せるか。「（現在）」の側を選んでいるときは押しても何も変わらないので押せなくする。
    /// Illustrator が無いのに選ばれている場合（ラジオの1項目だけの disabled が効かないことがある）も押せなくする
    var canAssociate: Bool {
        !isAssociating && selectedTarget != currentTarget
            && (selectedTarget != .illustrator || illustratorAvailable)
    }

    // ── ファイルアイコンの取り込み（ステップ7。起動時の自動取り込みは廃止）
    @Published var iconNote = ""
    @Published var iconStatus = ""
    @Published var iconButtonEnabled = false

    init() {
        let prefs = Preferences.shared
        alwaysNotify = (prefs.conditionsForOpeningAiFile == 2)
        notDetectEPS = prefs.isNotDetectEPSCompatibleVer
        useTimeLimit = prefs.useTimeLimit
        timeLimit    = Double(prefs.timeLimit)
        refreshAssociation(selectCurrent: true)
        refreshIcons()
    }

    func refreshOnShow() {
        if !isAssociating { refreshAssociation(selectCurrent: true) }
        refreshIcons()
    }

    /// ウインドウが前面に戻ったとき。ユーザーが選びかけたラジオボタンは変えず、現状だけ読み直す
    func refreshOnBecomeKey() {
        if !isAssociating { refreshAssociation(selectCurrent: false) }
        refreshIcons()
    }

    // MARK: 関連付け

    /// ラジオボタンの名前と「（現在）」の表示を更新する。selectCurrent なら現在の関連付け先を選ぶ
    func refreshAssociation(selectCurrent: Bool) {
        let glowCurrent = FileAssociation.isAssociated(with: .glowAi)
        let aiCurrent   = FileAssociation.isAssociated(with: .illustrator)

        glowAiTitle = glowCurrent
            ? String(format: String(localized: "%@ (current)"), "Glow Ai")
            : "Glow Ai"

        if let aiName = FileAssociation.Target.illustrator.displayName {
            illustratorTitle = aiCurrent
                ? String(format: String(localized: "%@ (current)"), aiName)
                : aiName
            illustratorAvailable = true
        } else {
            illustratorTitle = String(localized: "Adobe Illustrator (not installed)")
            illustratorAvailable = false
        }
        currentTarget = (aiCurrent && illustratorAvailable) ? .illustrator : (glowCurrent ? .glowAi : nil)

        if selectCurrent {
            isSelectingProgrammatically = true
            selectedTarget = (aiCurrent && illustratorAvailable) ? .illustrator : .glowAi
            isSelectingProgrammatically = false
            assocStatus = ""
        }
    }

    /// 「関連付ける」：選んだアプリと違う種類だけを変更する。
    /// macOS 26.4 以降は種類ごとに確認ダイアログが出て、答えるまで完了しない
    func associate() {
        guard !isAssociating else { return }
        let target = selectedTarget
        guard let appURL = target.appURL, let name = target.displayName else { return }

        let needed = FileAssociation.typesNeedingChange(to: appURL)
        if needed.isEmpty {
            assocStatus = String(format: String(localized: "Already associated with %@."), name)
            return
        }

        isAssociating = true
        assocStatus = String(localized: "Waiting for confirmation…")

        FileAssociation.apply(needed, to: appURL) { [weak self] outcome in
            guard let self else { return }
            self.isAssociating = false
            switch outcome {
            case .applied:
                self.refreshAssociation(selectCurrent: false)
                self.assocStatus = String(format: String(localized: "Associated with %@."), name)
            case .kept(let changedSome):
                // 確認ダイアログで「“〜”のままにする」を選んだ＝ユーザーの意思なので、案内のアラートは出さない。
                // 選択は現在の関連付け先に戻す
                self.refreshAssociation(selectCurrent: true)
                self.assocStatus = changedSome
                    ? String(format: String(localized: "Only some file types were associated with %@."), name)
                    : String(localized: "The file association was kept as it is.")
            case .notApplied:
                self.refreshAssociation(selectCurrent: false)
                self.assocStatus = ""
                FileAssociation.showNotAppliedAlert(for: self.window)
            }
        }
    }

    // MARK: アイコンの取り込み

    /// 説明・状態・ボタンの有効／無効を更新する。
    /// 書き込めない場合（管理者でないアカウントで、管理者が入れた Glow Ai を開いた等）はボタンを押せなくし、理由を出す
    func refreshIcons(status: String? = nil) {
        let aiName = FileAssociation.Target.illustrator.displayName
        iconNote = String(format: String(localized: "Copies the .ai, .ait, and .eps icons from %@ into Glow Ai, so files associated with Glow Ai also show the latest Illustrator icons."),
                          aiName ?? "Adobe Illustrator")

        let app = IllustratorApp.shared
        if aiName == nil || app.latestIconSources() == nil {
            iconButtonEnabled = false
            iconStatus = String(localized: "No Adobe Illustrator icons were found.")
            return
        }
        if let problem = app.iconImportProblem() {
            iconButtonEnabled = false
            switch problem {
            case .translocated:
                iconStatus = String(localized: "Move Glow Ai to the Applications folder, then open it again.")
            case .rootOwned:
                iconStatus = String(localized: "Glow Ai can't be changed because it's owned by the system.")
            case .notWritable:
                iconStatus = String(localized: "To import icons, log in with an administrator account.")
            }
            return
        }
        // 最新なら取り込んでも何も変わらないので押せなくする（取り込み直後も同じ）
        let upToDate = app.iconsAreUpToDate()
        iconButtonEnabled = !upToDate
        if let status {
            iconStatus = status
        } else {
            iconStatus = upToDate
                ? String(localized: "The icons in Glow Ai are up to date.")
                : ""
        }
    }

    func importIcons() {
        let name = FileAssociation.Target.illustrator.displayName ?? "Adobe Illustrator"
        if IllustratorApp.shared.importIcons() {
            refreshIcons(status: String(format: String(localized: "Imported the icons from %@."), name))
        } else {
            // 事前に調べて書き込めたのに失敗した場合（途中で権限が変わった等）。理由があればそちらを出す
            refreshIcons(status: String(localized: "The icons couldn't be imported."))
        }
    }
}

// MARK: - View

struct PreferencesView: View {

    static let width: CGFloat = 470

    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section("When Opening Files") {
                Toggle("Always show notification window (do not open automatically)", isOn: $model.alwaysNotify)
            }

            Section("Detection") {
                Toggle("Do not detect EPS compatible version (v9+)", isOn: $model.notDetectEPS)
                Toggle(model.timeLimitTitle, isOn: $model.useTimeLimit)
                Slider(value: $model.timeLimit, in: 1...10, step: 1) {
                    Text(model.timeLimitTitle)
                }
                .labelsHidden()
            }

            Section("File association (.ai / .ait / .eps)") {
                // 説明文は「ファイルアイコン」欄の説明と同じ体裁（caption・secondary）にする。
                // labelsHidden() で別の Text にするとラジオが1項目1行の右寄せに変わるので、
                // Picker のラベル自体を説明文の体裁にして、ラジオの縦並び・左寄せを保つ
                Picker(selection: $model.selectedTarget) {
                    Text(model.glowAiTitle).tag(FileAssociation.Target.glowAi)
                    Text(model.illustratorTitle).tag(FileAssociation.Target.illustrator)
                        .disabled(!model.illustratorAvailable)
                } label: {
                    Text("Choose the app that opens when you double-click a file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isAssociating)

                HStack(spacing: 12) {
                    Text(model.assocStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button("Associate") { model.associate() }
                        .disabled(!model.canAssociate)
                }
            }

            Section("File icons") {
                Text(model.iconNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(model.iconStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Import Icons") { model.importIcons() }
                        .disabled(!model.iconButtonEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}
