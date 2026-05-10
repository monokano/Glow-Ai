
import AppKit

class PreferencesWindowController: NSWindowController {

    // MARK: - UI

    private let checkEPS           = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let checkTimeLimit     = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let slider             = NSSlider()
    private let separator          = NSBox()
    /// 常に通知ウインドウを表示する（conditionsForOpeningAiFile == 2）
    private let checkAlwaysNotify  = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let checkAutoClaim     = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // MARK: - Init

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 179),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = String(localized: "Glow Ai Preferences")
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── EPS 互換バージョン検出チェック
        checkEPS.title = String(localized: "Do not detect EPS compatible version (v9+)")
        checkEPS.target = self
        checkEPS.action = #selector(checkEPSChanged)
        checkEPS.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(checkEPS)

        // ── 制限時間チェック＋スライダー
        checkTimeLimit.target = self
        checkTimeLimit.action = #selector(checkTimeLimitChanged)
        checkTimeLimit.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(checkTimeLimit)

        slider.minValue = 1; slider.maxValue = 10; slider.numberOfTickMarks = 10
        slider.allowsTickMarkValuesOnly = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(slider)

        // ── セパレータ
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        // ── 常に通知ウインドウを表示
        checkAlwaysNotify.title = String(localized: "Always show notification window (do not open automatically)")
        checkAlwaysNotify.target = self
        checkAlwaysNotify.action = #selector(checkAlwaysNotifyChanged)
        checkAlwaysNotify.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(checkAlwaysNotify)

        // ── 起動時に関連付けをする
        checkAutoClaim.title = String(localized: "Associate file types on launch (.ai / .ait / .eps)")
        checkAutoClaim.target = self
        checkAutoClaim.action = #selector(checkAutoClaimChanged)
        checkAutoClaim.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(checkAutoClaim)

        setupConstraints(content: content)
    }

    private func setupConstraints(content: NSView) {
        NSLayoutConstraint.activate([
            // EPS チェック（左上）
            checkEPS.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            checkEPS.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            // 制限時間チェック
            checkTimeLimit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            checkTimeLimit.topAnchor.constraint(equalTo: checkEPS.bottomAnchor, constant: 10),

            // スライダー
            slider.leadingAnchor.constraint(equalTo: checkTimeLimit.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            slider.centerYAnchor.constraint(equalTo: checkTimeLimit.centerYAnchor),

            // セパレータ
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            separator.topAnchor.constraint(equalTo: checkTimeLimit.bottomAnchor, constant: 18),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // 常に通知ウインドウ
            checkAlwaysNotify.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            checkAlwaysNotify.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            checkAlwaysNotify.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18),

            // 起動時に関連付けをする
            checkAutoClaim.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            checkAutoClaim.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            checkAutoClaim.topAnchor.constraint(equalTo: checkAlwaysNotify.bottomAnchor, constant: 14),

            // ウィンドウ下端
            content.bottomAnchor.constraint(equalTo: checkAutoClaim.bottomAnchor, constant: 26),
        ])
    }

    // MARK: - Load / Update

    private func loadValues() {
        let prefs = Preferences.shared
        checkAlwaysNotify.state = (prefs.conditionsForOpeningAiFile == 2) ? .on : .off
        checkEPS.state          = prefs.isNotDetectEPSCompatibleVer ? .on : .off
        checkTimeLimit.state    = prefs.useTimeLimit ? .on : .off
        slider.integerValue     = prefs.timeLimit
        checkAutoClaim.state    = prefs.autoClaimFileAssociations ? .on : .off
        updateTimeLimitLabel()
    }

    private func updateTimeLimitLabel() {
        let sec = slider.integerValue
        checkTimeLimit.title = String(format: String(localized: "Limit read size (%lld sec)"), sec)
    }

    // MARK: - Actions

    @objc private func checkAlwaysNotifyChanged() {
        Preferences.shared.conditionsForOpeningAiFile = (checkAlwaysNotify.state == .on) ? 2 : 0
        Preferences.shared.save()
    }

    @objc private func checkEPSChanged() {
        Preferences.shared.isNotDetectEPSCompatibleVer = (checkEPS.state == .on)
        Preferences.shared.save()
    }

    @objc private func checkTimeLimitChanged() {
        Preferences.shared.useTimeLimit = (checkTimeLimit.state == .on)
        Preferences.shared.save()
    }

    @objc private func sliderChanged() {
        Preferences.shared.timeLimit = slider.integerValue
        Preferences.shared.save()
        updateTimeLimitLabel()
    }

    @objc private func checkAutoClaimChanged() {
        let on = (checkAutoClaim.state == .on)
        Preferences.shared.autoClaimFileAssociations = on
        Preferences.shared.save()
        if on {
            AppDelegate.shared?.claimFileAssociations()
        } else {
            AppDelegate.shared?.claimFileAssociationsToTopIllustrator()
        }
    }
}
