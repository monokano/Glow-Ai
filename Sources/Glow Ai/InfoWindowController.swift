
import AppKit
import Combine
import SwiftUI

// MARK: - AppListRow

struct AppListRow: Identifiable {
    let id = UUID()
    enum AppKind { case illustrator(IllustratorAppClass), photoshop(PhotoshopAppClass) }
    var kind: AppKind
    var name: String
    var version: String
    var icon: NSImage?
    var isBooted: Bool
    var isWillBoot: Bool
    var canOpen: Bool
    var isBeta: Bool

    var appURL: URL {
        switch kind {
        case .illustrator(let ac): return ac.appURL
        case .photoshop(let ac):   return ac.appURL
        }
    }
}

// MARK: - InfoViewModel

@MainActor
final class InfoViewModel: ObservableObject {

    var fc: FileClass

    @Published var tableRows: [AppListRow] = []
    @Published var selectedID: AppListRow.ID? = nil
    @Published var allowHigher: Bool {
        didSet { Preferences.shared.allowOpeningInHigherVersion = allowHigher; Preferences.shared.save(); rebuild() }
    }
    @Published var allowCompat: Bool {
        didSet { Preferences.shared.allowedToOpenInLowerVersion = allowCompat; Preferences.shared.save(); rebuild() }
    }
    private var terminationObserver: NSObjectProtocol?

    var selectedRow: AppListRow? {
        guard let id = selectedID else { return nil }
        return tableRows.first { $0.id == id }
    }

    // MARK: バルーン

    var hasBalloon: Bool { !balloonMessage.isEmpty }

    var balloonMessage: String {
        // モード 10（非Illustratorファイル）と 12（Illustrator編集機能保持PDF）は
        // 種類バルーン（kindBalloonMessage）で表示するためここでは扱わない
        let msgs: [Int: String] = [
            2:  "No Illustrator.app with matching minor version",
            3:  "No Illustrator.app with matching major version",
            4:  "Another Illustrator.app is already running",
            5:  "Version info cannot be detected",
            6:  "Compatible version has been downgraded",
            11: "Time limit reached",
        ]
        if let key = msgs[fc.infoWindowMode] { return String(localized: String.LocalizationValue(key)) }
        return ""
    }

    // MARK: 種類バルーン（アイコン左に表示）

    var hasKindBalloon: Bool { !kindBalloonMessage.isEmpty }

    /// 種類バルーンを危険色（赤）で表示すべきか（判定本体は FileClass.isKindDangerous）
    var kindBalloonIsDangerous: Bool { fc.isKindDangerous }

    var kindBalloonMessage: String {
        let ext = fc.file?.pathExtension.lowercased() ?? ""
        switch (fc.kind, fc.isIllustratorFile, fc.appName) {
        case ("PDF", true, _):
            return String(localized: "PDF file - with Illustrator editing capabilities (.pdf)")
        case ("Ai", true, _) where fc.isTemplate:
            return ext == "ait" ? "" : String(localized: "Illustrator Template format (.ait)")
        case ("Ai", true, _):
            return ext == "ai" ? "" : String(localized: "Adobe Illustrator format (.ai)")
        case ("PDF", _, _) where fc.isPhotoshopEditablePDF:
            return String(localized: "PDF file - with Photoshop editing capabilities (.pdf)")
        case ("PDF", false, _):
            return String(localized: "PDF file - without Illustrator editing capabilities (.pdf)")
        case ("EPS", true, _):
            return ext == "eps" ? "" : String(localized: "Illustrator EPS format (.eps)")
        case ("EPS", false, "Photoshop"):
            return String(localized: "Photoshop EPS format (.eps)")
        case ("EPS", false, _):
            // Illustrator/Photoshop いずれでもない EPS。B1/B2 と違い ext=="eps" でも空にせず常に返す（＝常に赤）。
            // バルーンは PDF 同様に改行入りキー（生成元が長い場合に折り返す）。空なら「生成元不明」。
            let producer = fc.creator1.isEmpty
                ? String(localized: "Unknown producer")
                : fc.creator1
            return String(format: String(localized: "EPS file - %@ (.eps)"), producer)
        case ("PSD", _, _):
            return String(localized: "Photoshop format (.psd)")
        case ("PSB", _, _):
            return String(localized: "Large Document format (.psb)")
        default:
            return String(localized: "Not an Illustrator file")
        }
    }

    // MARK: 開くボタン

    var openEnabled: Bool { selectedRow?.canOpen == true }

    var openTitle: String {
        guard let row = selectedRow, row.canOpen else { return String(localized: "Open") }
        let verName: String
        switch row.kind {
        case .illustrator: verName = FileInfo.versionName(row.version)
        case .photoshop:   verName = PhotoshopApp.versionName(row.version)
        }
        return String(format: String(localized: "Open with %@"), verName)
    }

    // MARK: 終了ボタン

    var quitEnabled: Bool {
        guard let row = selectedRow else { return false }
        return row.isBooted || row.isWillBoot
    }

    // MARK: Init

    init(fc: FileClass) {
        let p = Preferences.shared
        self.fc = fc
        self.allowHigher = p.allowOpeningInHigherVersion
        self.allowCompat = p.allowedToOpenInLowerVersion
        buildTableRows()
        selectedID = defaultSelectionID()
    }

    // MARK: テーブル構築

    func buildTableRows() {
        tableRows = []
        let prefs = Preferences.shared
        let targetMajor = Int(fc.determine_Created.components(separatedBy: ".").first ?? "") ?? 0
        let savedMajor  = Int(fc.determine_Saved.components(separatedBy:  ".").first ?? "") ?? 0
        let minAppMajor = IllustratorApp.shared.getMinimumVerAppClass()
            .flatMap { Int($0.version.components(separatedBy: ".").first ?? "") } ?? 0
        let isPDF = fc.kind == "PDF"

        if fc.isIllustratorFile {
            IllustratorApp.shared.getAppALLRefresh()
            for ac in IllustratorApp.shared.appClassALLIncludeBeta {
                let appMajor = Int(ac.version.components(separatedBy: ".").first ?? "") ?? 0
                let folder = ac.appURL.deletingLastPathComponent().lastPathComponent
                let isBeta = folder.contains("Beta") || folder.contains("Prerelease")
                var canOpen = false
                if !isBeta {
                    canOpen = prefs.allowOpeningInHigherVersion ? appMajor >= targetMajor : appMajor == targetMajor
                    if prefs.allowedToOpenInLowerVersion && savedMajor > 0
                        && targetMajor >= savedMajor && appMajor >= savedMajor && appMajor <= targetMajor {
                        canOpen = true
                    }
                    if minAppMajor > targetMajor { canOpen = true }
                    if isPDF && fc.isIllustratorFile {
                        if appMajor < targetMajor {
                            canOpen = false
                        } else if appMajor == targetMajor {
                            canOpen = true
                        } else {
                            canOpen = prefs.allowOpeningInHigherVersion
                        }
                    }
                }
                tableRows.append(AppListRow(
                    kind: .illustrator(ac), name: folder,
                    version: ac.version, icon: ac.icon,
                    isBooted: ac.isBooted,
                    isWillBoot: IllustratorApp.shared.isWillBootApp(appURL: ac.appURL),
                    canOpen: canOpen,
                    isBeta: isBeta
                ))
            }
        } else if fc.appName == "Photoshop" {
            PhotoshopApp.shared.getAppALLRefresh()
            let sortedPS = PhotoshopApp.shared.appClassALL.sorted { a, b in
                let av = a.version.split(separator: ".").compactMap { Int($0) }
                let bv = b.version.split(separator: ".").compactMap { Int($0) }
                for (x, y) in zip(av, bv) { if x != y { return x < y } }
                return av.count < bv.count
            }
            for ac in sortedPS {
                tableRows.append(AppListRow(
                    kind: .photoshop(ac),
                    name: ac.appURL.deletingLastPathComponent().lastPathComponent,
                    version: ac.version, icon: ac.icon,
                    isBooted: ac.isBooted, isWillBoot: false, canOpen: true, isBeta: false
                ))
            }
        }
    }

    private func defaultSelectionID() -> AppListRow.ID? {
        if fc.isIllustratorFile {
            let myMajor = fc.determine_Created.split(separator: ".").first.map(String.init) ?? ""

            // 1. 完全3パート一致（危険バージョン除く）
            for row in tableRows {
                let ver3 = row.version.split(separator: ".").prefix(3).joined(separator: ".")
                if ver3 == fc.determine_Created && row.version != "22.0.0" { return row.id }
            }

            // 2. メジャー一致の非Beta行（プレリリース・ベータ除く）
            if let row = tableRows.first(where: { row in
                !row.isBeta
                    && row.version.split(separator: ".").first.map(String.init) == myMajor
            }) { return row.id }
        }
        return tableRows.first(where: { $0.isBooted })?.id
    }

    func update(fc newFC: FileClass) {
        fc = newFC
        let prevURL = selectedRow?.appURL
        buildTableRows()
        selectedID = prevURL.flatMap { url in tableRows.first { $0.appURL == url }?.id }
            ?? defaultSelectionID()
    }

    func rebuild() {
        let prevURL = selectedRow?.appURL
        buildTableRows()
        selectedID = prevURL.flatMap { url in tableRows.first { $0.appURL == url }?.id }
    }

    // MARK: アクション

    func openFile(onClose: @escaping () -> Void, forced: Bool = false) {
        guard let item = selectedRow, (forced || item.canOpen), let fileURL = fc.file else { return }

        switch item.kind {
        case .illustrator(let ac):
            if !IllustratorApp.shared.isAppBooted(appURL: ac.appURL)
                && IllustratorApp.shared.isOtherVerAppBooted(excluding: ac.appURL)
                && !IllustratorApp.shared.isWillBootApp(appURL: ac.appURL) {
                switch showAlertMixedVersions() {
                case .notBoot:    return
                case .quitGlowAi: onClose(); NSApplication.shared.terminate(nil); return
                case .ignore:     IllustratorApp.shared.willBootAppClass.append(ac)
                }
            }
            ac.openFileURLs.append(fileURL)
        case .photoshop(let ac):
            ac.openFileURLs.append(fileURL)
        }
        onClose()
    }

    func quitAction() {
        guard let item = selectedRow else { return }
        if item.isWillBoot {
            IllustratorApp.shared.removeWillBootApp(appURL: item.appURL)
            rebuild()
        } else if item.isBooted {
            let appURL = item.appURL
            NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardized == appURL.standardized
            }.forEach { $0.terminate() }
            observeTermination(of: appURL)
        }
    }

    private func observeTermination(of appURL: URL) {
        let center = NSWorkspace.shared.notificationCenter
        // 既存のオブザーバを解除してから登録
        if let prev = terminationObserver { center.removeObserver(prev) }
        terminationObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleURL?.standardized == appURL.standardized else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                center.removeObserver(self.terminationObserver as Any)
                self.terminationObserver = nil
                // infoWindowMode を再評価してバルーン表示を更新
                IllustratorApp.shared.openWithSameApp(fc: self.fc, reView: true)
                self.buildTableRows()
                self.selectedID = self.defaultSelectionID()
            }
        }
    }

    // MARK: Beta 版を強制的に開く右クリックメニュー

    @MainActor
    func showBetaOpenMenu(for row: AppListRow, onClose: @escaping () -> Void) {
        let menu = NSMenu()
        let handler = ClosureMenuItem { [weak self] in
            self?.selectedID = row.id
            self?.openFile(onClose: onClose, forced: true)
        }
        let item = NSMenuItem(title: String(localized: "Open"),
                              action: #selector(ClosureMenuItem.invoke(_:)),
                              keyEquivalent: "")
        item.target = handler
        item.representedObject = handler   // handler を NSMenuItem に retain させる
        menu.addItem(item)
        if let event = NSApp.currentEvent, let view = NSApp.keyWindow?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    // MARK: 複数バージョン起動警告

    private enum AlertResult { case notBoot, quitGlowAi, ignore }

    private func showAlertMixedVersions() -> AlertResult {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Continuing will launch multiple Illustrator instances.")
        alert.informativeText = String(localized: "It is recommended to keep only one Illustrator running.")
        alert.addButton(withTitle: String(localized: "Not Boot"))
        alert.addButton(withTitle: String(localized: "Ignore warning"))
        let quitButton = alert.addButton(withTitle: String(localized: "Quit Glow Ai"))
        quitButton.keyEquivalent = "\u{1B}"  // ESC → キャンセルボタン扱い（他ボタンと間隔が広がる）
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .notBoot
        case .alertSecondButtonReturn: return .ignore
        default:                       return .quitGlowAi
        }
    }
}

// MARK: - ClosureMenuItem（NSMenu クロージャ用ヘルパー）

private final class ClosureMenuItem: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke(_ sender: Any?) { closure() }
}

// MARK: - InfoView

struct InfoView: View {

    @ObservedObject var vm: InfoViewModel
    let showAlertIcon: Bool
    let onClose: () -> Void
    let onMoreInfo: () -> Void
    @State private var balloonVisible = false

    // 作成バージョン（"Illustrator 2025 (29.8.5)" 形式）
    private var labelCreated: String {
        if vm.fc.appName == "Photoshop" {
            // cinf(PSD/PSB) / %%Creator(EPS) から取得した psVersion を表示（照合には使わない）
            return vm.fc.psVersion.isEmpty ? "Photoshop" :
                "Photoshop \(FileInfo.psVersionName(vm.fc.psVersion)) (\(vm.fc.psVersion))"
        }
        guard vm.fc.isIllustratorFile else { return "" }
        if vm.fc.determine_Created.isEmpty { return String(localized: "Unknown version") }
        return "\(vm.fc.appName) \(FileInfo.versionName(vm.fc.determine_Created)) (\(vm.fc.determine_Created))"
    }

    // 互換バージョン（作成メジャーバージョンと異なる場合、またはEPS検出オフ時、またはEPSで検出済みの場合）
    private var showSaved: Bool {
        guard vm.fc.isIllustratorFile else { return false }
        if showSavedEpsOff { return true }
        guard !vm.fc.determine_Saved.isEmpty else { return false }
        return true   // EPS・AI ともに検出済みなら常に表示（v17以下でメジャー一致でも表示）
    }

    // EPS互換バージョン検出オフで未検出の場合
    private var showSavedEpsOff: Bool {
        vm.fc.kind == "EPS" && Preferences.shared.isNotDetectEPSCompatibleVer && vm.fc.determine_Saved.isEmpty
    }
    private var labelSaved: String {
        if vm.fc.determine_Saved.isEmpty {
            if vm.fc.kind == "EPS" && Preferences.shared.isNotDetectEPSCompatibleVer {
                return String(localized: "Compat. detection OFF")
            }
            return String(localized: "Unknown compat. version")
        }
        let base = "\(vm.fc.appName) \(FileInfo.versionName(vm.fc.determine_Saved)) (\(vm.fc.determine_Saved))"
        return base
    }
    /// Illustrator編集機能を保持したPDF：互換バージョンが無視されることを示すフラグ
    private var labelSavedIgnored: Bool { vm.fc.infoWindowMode == 12 }

    private var minTableHeight: CGFloat {
        max(26, CGFloat(max(1, min(vm.tableRows.count, 3))) * 26 - 134)
    }

    private var minContentHeight: CGFloat {
        let extraRows = max(0, vm.tableRows.count - 3)
        return 304 + CGFloat(extraRows) * 26 + 26
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            appTableSection
            buttonBar
            Divider()
                .padding(.horizontal, 16)
            checkboxSection
        }
        .frame(width: 420)
        .frame(minHeight: minContentHeight)
        .offset(y: -6)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                balloonVisible = true
            }
        }
    }

    // MARK: ── ヘッダー ──────────────────────────────────

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            iconCluster
                .offset(y: -2)
            VStack(alignment: .leading, spacing: 7) {
                // ファイル名 ＋ 詳細情報ボタン
                HStack(alignment: .firstTextBaseline) {
                    Text(vm.fc.file?.lastPathComponent ?? "")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button("More Info") { onMoreInfo() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                }

                // 作成バージョン
                if !labelCreated.isEmpty {
                    HStack(alignment: Locale.current.language.languageCode?.identifier == "ja" ? .center : .firstTextBaseline, spacing: 6) {
                        Text("Created")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(labelCreated)
                            .font(.system(size: 16, weight: .medium))
                            .padding(.leading, 2)
                            .textSelection(.enabled)
                    }
                }

                // 互換バージョン（作成メジャーバージョンと異なる場合、またはEPS検出オフ時）
                if showSaved {
                    HStack(alignment: Locale.current.language.languageCode?.identifier == "ja" ? .center : .firstTextBaseline, spacing: 6) {
                        Text("Compat.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if showSavedEpsOff {
                            Text(String(localized: "EPS compat. detection OFF"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        } else {
                            Group {
                                if labelSavedIgnored {
                                    Text(labelSaved)
                                    + Text(String(localized: " ← Ignored"))
                                        .foregroundColor(.red)
                                        .bold()
                                } else {
                                    Text(labelSaved)
                                        .foregroundColor(vm.fc.isSavedLowerVersion ? .red : .primary)
                                }
                            }
                            .font(.system(size: 14))
                            .padding(.leading, 2)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.leading, -6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // アイコン ＋ 警告バッジ（BadgePopover のアンカー）
    private var iconCluster: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = vm.fc.file {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)
                        .resized(to: NSSize(width: 56, height: 56)))
                        .resizable()
                        .frame(width: 56, height: 56)
                } else {
                    Color.clear.frame(width: 56, height: 56)
                }
            }
            if showAlertIcon { alertBadge.offset(x: -7, y: 11) }
        }
        .badgePopover(vm.balloonMessage,
                      isPresented: .constant(vm.hasBalloon && balloonVisible),
                      edge: .top,
                      color: badgePopoverDefaultColor)
        .badgePopover(vm.kindBalloonMessage,
                      isPresented: .constant(vm.hasKindBalloon && balloonVisible),
                      edge: .leading,
                      color: vm.kindBalloonIsDangerous
                           ? NSColor(red: 0.698, green: 0.0, blue: 0.008, alpha: 1.0)
                           : badgePopoverDefaultColor)
    }

    @ViewBuilder
    private var alertBadge: some View {
        if vm.fc.infoWindowMode > 0 {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 36, weight: .bold))
        }
    }

    // MARK: ── アプリ一覧（NativeList） ────────────────────

    private var appTableSection: some View {
        NativeList(
            columns: [
                NativeListColumn(
                    String(localized: "Application"),
                    { $0.name },
                    textColor: { $0.canOpen ? .labelColor : .secondaryLabelColor },
                    icon: { $0.icon },
                    iconSize: 20,
                    resizable: true,
                    minWidth: 150,
                    width: 255
                ),
                NativeListColumn(
                    String(localized: "Version"),
                    { $0.version },
                    textColor: { $0.canOpen ? .labelColor : .secondaryLabelColor },
                    minWidth: 75,
                    width: 75,
                    alignment: .center
                ),
                NativeListColumn(
                    String(localized: "Status"),
                    { _ in "" },
                    customView: { row, isSelected in
                        guard row.isBooted else { return nil }
                        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
                        dot.wantsLayer = true
                        dot.layer?.backgroundColor = (isSelected ? NSColor.white : NSColor.controlAccentColor).cgColor
                        dot.layer?.cornerRadius = 4
                        return dot
                    },
                    fitLastColumn: true,
                    minWidth: 53,
                    width: 53,
                    alignment: .center
                ),
            ],
            items: vm.tableRows,
            selection: $vm.selectedID,
            onDoubleClick: { [vm] row in
                vm.selectedID = row.id
                if row.canOpen {
                    vm.openFile(onClose: onClose)
                } else {
                    vm.showBetaOpenMenu(for: row, onClose: onClose)
                }
            },
            showHeader: false,
            rowHeight: 26,
            fontSize: NSFont.systemFontSize,
            bounces: false,
            hasBorder: true,
            showColumnDividers: true,
            showRowDividers: true
        )
        .frame(minHeight: minTableHeight, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    // MARK: ── ボタン行 ──────────────────────────────────

    private var buttonBar: some View {
        HStack(spacing: 8) {
            FixedButton(String(localized: "Quit"), width: 100,
                        isDefault: false,
                        isEnabled: vm.quitEnabled) { vm.quitAction() }
            Spacer()
            FixedButton(String(localized: "Cancel"), width: 100,
                        isCancel: true) { onClose() }
            FixedButton(vm.openTitle, width: 140,
                        isDefault: true,
                        isEnabled: vm.openEnabled) { vm.openFile(onClose: onClose) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }

    // MARK: ── チェックボックス行 ─────────────────────────

    private var checkboxSection: some View {
        let isPhotoshop = vm.fc.appName == "Photoshop"
        let isEmpty = vm.tableRows.isEmpty
        return VStack(alignment: .leading, spacing: 9) {
            Toggle("Allow opening in compatible version",
                   isOn: $vm.allowCompat)
                .disabled(isEmpty || isPhotoshop ||
                          (vm.fc.kind == "PDF" && vm.fc.isIllustratorFile))
            Toggle("Allow opening in higher version",
                   isOn: $vm.allowHigher)
                .disabled(isEmpty || isPhotoshop)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: NSFont.systemFontSize))
        .padding(.leading, 17)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - InfoWindowController

class InfoWindowController: NSWindowController {

    var fc: FileClass
    let showAlertIcon: Bool
    private var viewModel: InfoViewModel?
    private var moreInfoController: MoreInfoWindowController?
    /// 「検出」後にモードを再評価するクロージャ（AppDelegate から注入）
    var onEvaluate: ((FileClass) -> Void)?

    init(fc: FileClass, showAlertIcon: Bool) {
        self.fc = fc
        self.showAlertIcon = showAlertIcon
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 304),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = String(localized: "Glow Ai - Notification")
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.maxSize = NSSize(width: 420, height: 1994)
        super.init(window: win)

        let vm = InfoViewModel(fc: fc)
        viewModel = vm
        let content = InfoView(
            vm: vm,
            showAlertIcon: showAlertIcon,
            onClose:    { [weak self] in self?.closeModal() },
            onMoreInfo: { [weak self] in self?.showMoreInfo() }
        )
        win.contentView = NSHostingView(rootView: content)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showModal() {
        guard let win = window else { return }
        // 4行以上のときウィンドウ高さを拡張（3行以下は 304+26=330pt）
        let rowCount = viewModel?.tableRows.count ?? 0
        let extraRows = max(0, rowCount - 3)
        let targetHeight = 304 + CGFloat(extraRows) * 26 + 26
        win.setContentSize(NSSize(width: 420, height: targetHeight))
        win.minSize = win.frame.size  // setContentSize 後のフレームサイズを最小値に設定
        centerWindow(win)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: win)
    }

    private func centerWindow(_ win: NSWindow) {
        if let screen = NSScreen.main {
            let sx = screen.visibleFrame
            let wx = win.frame
            let x = sx.minX + (sx.width  - wx.width)  / 2
            let y = sx.minY + (sx.height - wx.height) * 0.6
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    internal func closeModal() {
        Preferences.shared.infoWindowWidth = Int(window?.frame.width ?? 500)
        Preferences.shared.save()
        window?.orderOut(nil)   // アニメーションなしで即時非表示（close() はアニメーションが入り次ウィンドウと重なる）
        NSApp.stopModal()
    }

    private func showMoreInfo() {
        guard let parent = window else { return }
        let ctrl = MoreInfoWindowController(fc: fc)
        ctrl.onDetected = { [weak self] newFC in
            // 再検出後にモードを再評価する（onEvaluate 経由で AppDelegate を直接参照しないようにする）
            self?.onEvaluate?(newFC)
            self?.fc = newFC
            self?.viewModel?.update(fc: newFC)
        }
        moreInfoController = ctrl
        ctrl.showAsSheet(on: parent)
    }
}

// MARK: - MoreInfoRow

struct MoreInfoRow: Identifiable {
    let id = UUID()
    let label: String
    var value: String
    var time: String = ""
    var isBold: Bool = false
    var isAlert: Bool = false
}

// MARK: - MoreInfoView

struct MoreInfoView: View {
    let initialFC: FileClass
    let onClose: () -> Void
    var onDetected: ((FileClass) -> Void)?

    @State private var currentFC: FileClass
    @State private var notDetectXMP: Bool = true
    @State private var notDetectEPSCompatible: Bool
    @State private var useTimeLimit: Bool
    @State private var timeLimit: Int

    init(fc: FileClass, onClose: @escaping () -> Void, onDetected: ((FileClass) -> Void)? = nil) {
        self.initialFC = fc
        self.onClose = onClose
        self.onDetected = onDetected
        self._currentFC = State(initialValue: fc)
        let p = Preferences.shared
        self._notDetectEPSCompatible = State(initialValue: p.isNotDetectEPSCompatibleVer)
        self._useTimeLimit           = State(initialValue: p.useTimeLimit)
        self._timeLimit              = State(initialValue: p.timeLimit)
    }

    private var verdictAlignment: VerticalAlignment {
        Locale.current.language.languageCode?.identifier == "ja" ? .center : .firstTextBaseline
    }

    private var rows: [MoreInfoRow] {
        let boldCreated = !currentFC.determine_Created.isEmpty
        let boldCreator1 = !currentFC.determine_Saved.isEmpty && !(currentFC.kind == "EPS" && currentFC.hasCreator2)
        let boldCreator2 = !currentFC.determine_Saved.isEmpty &&   currentFC.kind == "EPS" && currentFC.hasCreator2
        let (kindValue, kindIsAlert) = Self.kindRowInfo(fc: currentFC)
        return [
            MoreInfoRow(label: String(localized: "Filename"),             value: currentFC.file?.lastPathComponent ?? ""),
            MoreInfoRow(label: String(localized: "Kind"),                 value: kindValue, isAlert: kindIsAlert),
            MoreInfoRow(label: "XMP: CreatorTool",                        value: currentFC.xmp_CreatorTool,    time: currentFC.time_XMP_CreatorTool),
            MoreInfoRow(label: "PostScript: Creator (1)",                 value: currentFC.creator1,           time: currentFC.time_Creator1,          isBold: boldCreator1),
            MoreInfoRow(label: "PostScript: AI8_CreatorVersion",          value: currentFC.ai8_CreatorVersion, time: currentFC.time_AI8_CreatorVersion, isBold: boldCreated),
            MoreInfoRow(label: "PostScript: Creator (2)",                 value: currentFC.creator2,           time: currentFC.time_Creator2,          isBold: boldCreator2),
        ]
    }

    // MARK: - 種類行

    private static func kindRowInfo(fc: FileClass) -> (value: String, isAlert: Bool) {
        let ext = fc.file?.pathExtension.lowercased() ?? ""
        switch (fc.kind, fc.isIllustratorFile, fc.appName) {
        case ("PDF", true, _):
            return (String(localized: "PDF with Illustrator native data (.pdf)"), ext != "pdf")
        case ("PDF", _, _) where fc.isPhotoshopEditablePDF:
            return (String(localized: "PDF with Photoshop native data (.pdf)"), ext != "pdf")
        case ("Ai", true, _) where fc.isTemplate:
            return (String(localized: "Illustrator Template format (.ait)"),            ext != "ai" && ext != "ait")
        case ("Ai", true, _):
            return (String(localized: "Adobe Illustrator format (.ai)"),                ext != "ai" && ext != "ait")
        case ("PDF", false, _):
            return (String(localized: "PDF without Illustrator native data (.pdf)"), ext != "pdf")
        case ("EPS", true, _):
            return (String(localized: "Illustrator EPS format (.eps)"),           ext != "eps")
        case ("EPS", false, "Photoshop"):
            return (String(localized: "Photoshop EPS format (.eps)"),             ext != "eps")
        case ("EPS", false, _):
            // Illustrator/Photoshop いずれでもない EPS（Ghostscript 等）。生成元（creator1）を畳み込む。
            // 空（%%Creator なし）なら「生成元不明」。両フラグ false ＝拡張子を問わず常に赤。
            let producer = fc.creator1.isEmpty
                ? String(localized: "Unknown producer")
                : fc.creator1
            return (String(format: String(localized: "EPS format - %@ (.eps)"), producer), true)
        case ("PSD", _, _):
            return (String(localized: "Photoshop format (.psd)"),                 ext != "psd")
        case ("PSB", _, _):
            return (String(localized: "Large Document format (.psb)"),            ext != "psb")
        default:
            return (fc.kind, true)
        }
    }

    private var labelCreated: String {
        if currentFC.appName == "Photoshop" {
            return currentFC.psVersion.isEmpty ? "Photoshop" :
                "Photoshop \(FileInfo.psVersionName(currentFC.psVersion)) (\(currentFC.psVersion))"
        }
        guard currentFC.isIllustratorFile, !currentFC.determine_Created.isEmpty else { return "" }
        return "\(currentFC.appName) \(FileInfo.versionName(currentFC.determine_Created)) (\(currentFC.determine_Created))"
    }
    private var labelSaved: String {
        guard currentFC.isIllustratorFile else { return "" }
        guard !currentFC.determine_Saved.isEmpty else { return "" }
        return "\(currentFC.appName) \(FileInfo.versionName(currentFC.determine_Saved)) (\(currentFC.determine_Saved))"
    }
    private var showCompatRow: Bool {
        guard currentFC.isIllustratorFile else { return false }
        // Illustrator EPS は検出状態に関わらず常に互換行を表示する
        if currentFC.kind == "EPS" && currentFC.appName != "Photoshop" { return true }
        return showSavedEpsOff || !labelSaved.isEmpty
    }
    private var showSavedEpsOff: Bool {
        currentFC.kind == "EPS" && notDetectEPSCompatible && currentFC.determine_Saved.isEmpty
    }
    /// Illustrator編集機能を保持したPDF（A1）：互換バージョンが無視されることを示すフラグ
    private var labelSavedIgnored: Bool {
        currentFC.kind == "PDF" && currentFC.isIllustratorFile
    }

    private var fileSizeText: String {
        guard let url = currentFC.file,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return "" }
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    private var timeTotalText: String {
        guard !currentFC.time_TotalSeconds.isEmpty else { return "" }
        return "\(currentFC.time_TotalSeconds) \(String(localized: "sec"))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 情報テーブル
            NativeList(
                columns: [
                    NativeListColumn(String(localized: "Info"),  { $0.label }, isBold: { $0.isBold }, minWidth: 198, width: 198),
                    NativeListColumn(String(localized: "Value"), { $0.value }, isBold: { $0.isBold || $0.isAlert }, textColor: { $0.isAlert ? .systemRed : .labelColor }, resizable: true, minWidth: 227, width: 227),
                    NativeListColumn(String(localized: "µs"),    { $0.time },  minWidth: 60, width: 79, alignment: .right),
                ],
                items: rows,
                selection: .constant(nil),
                showCompactHeader: true,
                rowHeight: 20,
                fontSize: NSFont.smallSystemFontSize,
                bounces: false,
                hasBorder: true
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .frame(height: 162)

            // ファイルサイズ・処理時間
            HStack {
                Text(fileSizeText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(timeTotalText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 28)

            // 判定結果
            VStack(alignment: .leading, spacing: 8) {
                if !labelCreated.isEmpty {
                    HStack(alignment: verdictAlignment, spacing: 6) {
                        Text("Created").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(labelCreated).font(.system(size: 16, weight: .medium))
                            .textSelection(.enabled)
                    }
                }
                if showCompatRow {
                    HStack(alignment: verdictAlignment, spacing: 6) {
                        Text("Compat.").font(.system(size: 11)).foregroundStyle(.secondary)
                        if showSavedEpsOff {
                            Text(String(localized: "EPS compat. detection OFF"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else if labelSavedIgnored {
                            (Text(labelSaved)
                             + Text(String(localized: " ← Ignored"))
                                .foregroundColor(.red)
                                .bold())
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                        } else {
                            Text(labelSaved).font(.system(size: 14))
                                .foregroundStyle(currentFC.isSavedLowerVersion ? Color.red : Color.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(height: 50)

            Divider().padding(.top, 20)

            // オプション・ボタン（Ai File Ver と同構成、コピー→閉じる）
            VStack(alignment: .leading, spacing: 6) {
                let isPhotoshop = currentFC.appName == "Photoshop"
                Toggle(isOn: $notDetectXMP) {
                    Text("Do not detect XMP: CreatorTool")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $notDetectEPSCompatible) {
                    Text("Do not detect EPS compatible version (v9+)")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .disabled(isPhotoshop)

                HStack(spacing: 12) {
                    Toggle(isOn: $useTimeLimit) {
                        Text(String(format: String(localized: "Time limit: %lld sec"), timeLimit))
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    Slider(value: Binding(get: { Double(timeLimit) }, set: { timeLimit = Int($0) }),
                           in: 1...10, step: 1)
                        .frame(width: 200)
                        .disabled(!useTimeLimit)
                }

                HStack(spacing: 8) {
                    FixedButton(String(localized: "Detect"), width: 70, style: .smallSquare, isSmall: true) {
                        if let url = initialFC.file,
                           let fc = FileInfo.getInfoMinimum(url: url, isLimit: useTimeLimit, timeLimitSec: timeLimit, notDetectXMP: notDetectXMP, notDetectEPSCompatibleVer: notDetectEPSCompatible) {
                            currentFC = fc; onDetected?(fc)
                        }
                    }
                    FixedButton(String(localized: "Detect (no limit)"), width: 120, style: .smallSquare, isSmall: true) {
                        if let url = initialFC.file,
                           let fc = FileInfo.getInfoMinimum(url: url, isLimit: false, timeLimitSec: timeLimit, notDetectXMP: notDetectXMP, notDetectEPSCompatibleVer: notDetectEPSCompatible) {
                            currentFC = fc; onDetected?(fc)
                        }
                    }
                    Spacer()
                    FixedButton(String(localized: "Close"), width: 80, isDefault: true, isSmall: true) { onClose() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, -8)
            .frame(height: 119)
        }
        .frame(minWidth: 550, maxWidth: .infinity, minHeight: 382, maxHeight: 382)   // 幅のみリサイズ可。高さは固定
    }
}

// MARK: - MoreInfoWindowController

class MoreInfoWindowController: NSWindowController {
    let fc: FileClass
    var onDetected: ((FileClass) -> Void)?

    init(fc: FileClass) {
        self.fc = fc
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 382),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        // 幅のみリサイズ可・高さは 382 に固定（min と max の高さを揃える）
        win.minSize = NSSize(width: 550, height: 382)
        win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 382)
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAsSheet(on parent: NSWindow) {
        guard let win = window else { return }
        win.contentView = NSHostingView(rootView: MoreInfoView(fc: fc, onClose: { [weak self] in
            self?.closeSheet()
        }, onDetected: { [weak self] newFC in
            self?.onDetected?(newFC)
        }))
        // 記憶した幅を復元（最小550でクランプ。高さは382固定）
        let savedWidth = max(550, CGFloat(Preferences.shared.moreInfoSheetWidth))
        win.setContentSize(NSSize(width: savedWidth, height: 382))
        parent.beginSheet(win)
    }

    private func closeSheet() {
        guard let win = window, let parent = win.sheetParent else { return }
        // 現在の幅を記憶（infoWindowWidth と同じパターン）
        Preferences.shared.moreInfoSheetWidth = Int(win.frame.width)
        Preferences.shared.save()
        parent.endSheet(win)
    }
}
