import AppKit
import Carbon

/// 全局偏好设置，存在 UserDefaults，变更时发通知。
final class Settings {
    static let shared = Settings()

    static let hotKeyChanged = Notification.Name("Pasta.hotKeyChanged")
    static let expirationChanged = Notification.Name("Pasta.expirationChanged")
    static let themeChanged = Notification.Name("Pasta.themeChanged")
    static let historyLimitChanged = Notification.Name("Pasta.historyLimitChanged")

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
        static let ignoreRemoteClipboard = "ignoreRemoteClipboard"
        static let maxHistoryItems = "maxHistoryItems"
        static let autoBackupEnabled = "autoBackupEnabled"
        static let autoBackupDir = "autoBackupDir"
        static let lastAutoBackupAt = "lastAutoBackupAt"
    }

    private init() {
        defaults.register(defaults: [
            K.hotKeyCode: Int(kVK_ANSI_V),
            K.hotKeyModifiers: Int(cmdKey | shiftKey),
            K.hotKeyDisplay: "⇧⌘V",
            K.plainTextPaste: false,
            K.expirationDays: 180,          // 默认 6 个月（不支持永久）
            K.themeID: "midnight",
            K.ignoreRemoteClipboard: true,  // 接力内容默认不记：iOS 密码管理器的 Concealed 标记不跨设备
            K.maxHistoryItems: 5000,        // 非收藏历史容量（SQLite 增量写，上限只受内存元数据体积约束）
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

    // MARK: - 历史容量

    /// 非收藏历史条数上限（收藏不占额度）。越界值夹回合法区间。
    var maxHistoryItems: Int {
        get {
            let v = defaults.integer(forKey: K.maxHistoryItems)
            return (v < 100 || v > 10000) ? 5000 : v
        }
        set {
            defaults.set(min(max(100, newValue), 10000), forKey: K.maxHistoryItems)
            NotificationCenter.default.post(name: Settings.historyLimitChanged, object: nil)
        }
    }

    // MARK: - 自动备份

    /// 每日自动备份开关（需同时设好目录才生效）。
    var autoBackupEnabled: Bool {
        get { defaults.bool(forKey: K.autoBackupEnabled) }
        set { defaults.set(newValue, forKey: K.autoBackupEnabled) }
    }

    /// 自动备份目标目录路径（无沙盒，直接存路径即可）。
    var autoBackupDir: String? {
        get { defaults.string(forKey: K.autoBackupDir) }
        set { defaults.set(newValue, forKey: K.autoBackupDir) }
    }

    /// 上次自动备份时间（epoch 秒）。
    var lastAutoBackupAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: K.lastAutoBackupAt)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: K.lastAutoBackupAt) }
    }

    // MARK: - 接力剪贴板

    /// 忽略「通用剪贴板」（iPhone/iPad 接力）内容。默认开：
    /// iOS 端密码管理器打的 Concealed 标记不会跨设备传递，接力是敏感内容进历史的旁路。
    var ignoreRemoteClipboard: Bool {
        get { defaults.bool(forKey: K.ignoreRemoteClipboard) }
        set { defaults.set(newValue, forKey: K.ignoreRemoteClipboard) }
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
