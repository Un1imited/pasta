import AppKit
import Carbon

/// 全局偏好设置，存在 UserDefaults，变更时发通知。
final class Settings {
    static let shared = Settings()

    static let hotKeyChanged = Notification.Name("Pasta.hotKeyChanged")
    static let expirationChanged = Notification.Name("Pasta.expirationChanged")
    static let themeChanged = Notification.Name("Pasta.themeChanged")

    private let defaults = UserDefaults.standard

    private enum K {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyDisplay = "hotKeyDisplay"
        static let plainTextPaste = "plainTextPaste"
        static let expirationDays = "expirationDays"
        static let themeID = "themeID"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let ignoredApps = "ignoredApps"
    }

    private init() {
        defaults.register(defaults: [
            K.hotKeyCode: Int(kVK_ANSI_V),
            K.hotKeyModifiers: Int(cmdKey | shiftKey),
            K.hotKeyDisplay: "⇧⌘V",
            K.plainTextPaste: false,
            K.expirationDays: 180,          // 默认 6 个月（不支持永久）
            K.themeID: "midnight",
        ])
    }

    // MARK: - 主题

    var themeID: String {
        get { defaults.string(forKey: K.themeID) ?? "midnight" }
        set {
            defaults.set(newValue, forKey: K.themeID)
            NotificationCenter.default.post(name: Settings.themeChanged, object: nil)
        }
    }
    var theme: Theme { Theme.resolved(id: themeID) }

    static let maxExpirationDays = 180      // 历史最长保留 6 个月

    // MARK: - 热键

    var hotKeyCode: UInt32 { UInt32(defaults.integer(forKey: K.hotKeyCode)) }
    var hotKeyModifiers: UInt32 { UInt32(defaults.integer(forKey: K.hotKeyModifiers)) }
    var hotKeyDisplay: String { defaults.string(forKey: K.hotKeyDisplay) ?? "⇧⌘V" }

    func setHotKey(code: UInt32, modifiers: UInt32, display: String) {
        defaults.set(Int(code), forKey: K.hotKeyCode)
        defaults.set(Int(modifiers), forKey: K.hotKeyModifiers)
        defaults.set(display, forKey: K.hotKeyDisplay)
        NotificationCenter.default.post(name: Settings.hotKeyChanged, object: nil)
    }

    // MARK: - 首次启动

    var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: K.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: K.hasCompletedFirstRun) }
    }

    // MARK: - 纯文本粘贴

    var plainTextPaste: Bool {
        get { defaults.bool(forKey: K.plainTextPaste) }
        set { defaults.set(newValue, forKey: K.plainTextPaste) }
    }

    // MARK: - 忽略来源 App

    /// 忽略的来源 App（bundle id，小写存储）：前台是这些 App 时剪贴板变更不入历史。
    /// 典型场景：终端「选中即复制」（iTerm2 / PyCharm 终端）持续污染历史。
    /// 只影响之后的记录，已有历史不动。
    var ignoredApps: [String] {
        get { defaults.stringArray(forKey: K.ignoredApps) ?? [] }
        set { defaults.set(newValue.map { $0.lowercased() }, forKey: K.ignoredApps) }
    }

    // MARK: - 过期清理

    /// 非置顶历史保留天数（1…180，不支持永久）。旧的「永不(0)」或越界值自动夹到 6 个月。
    var expirationDays: Int {
        get {
            let v = defaults.integer(forKey: K.expirationDays)
            return (v <= 0 || v > Settings.maxExpirationDays) ? Settings.maxExpirationDays : v
        }
        set {
            let v = min(max(1, newValue), Settings.maxExpirationDays)
            defaults.set(v, forKey: K.expirationDays)
            NotificationCenter.default.post(name: Settings.expirationChanged, object: nil)
        }
    }
}
