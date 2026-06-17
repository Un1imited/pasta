import AppKit
import Carbon

/// 全局偏好设置，存在 UserDefaults，变更时发通知。
final class Settings {
    static let shared = Settings()

    static let hotKeyChanged = Notification.Name("Pasta.hotKeyChanged")
    static let expirationChanged = Notification.Name("Pasta.expirationChanged")

    private let defaults = UserDefaults.standard

    private enum K {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyDisplay = "hotKeyDisplay"
        static let plainTextPaste = "plainTextPaste"
        static let expirationDays = "expirationDays"
    }

    private init() {
        defaults.register(defaults: [
            K.hotKeyCode: Int(kVK_ANSI_V),
            K.hotKeyModifiers: Int(cmdKey | shiftKey),
            K.hotKeyDisplay: "⇧⌘V",
            K.plainTextPaste: false,
            K.expirationDays: 0,            // 0 = 永不过期
        ])
    }

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

    // MARK: - 纯文本粘贴

    var plainTextPaste: Bool {
        get { defaults.bool(forKey: K.plainTextPaste) }
        set { defaults.set(newValue, forKey: K.plainTextPaste) }
    }

    // MARK: - 过期清理

    /// 非置顶历史保留天数，0 表示永不过期。
    var expirationDays: Int {
        get { defaults.integer(forKey: K.expirationDays) }
        set {
            defaults.set(newValue, forKey: K.expirationDays)
            NotificationCenter.default.post(name: Settings.expirationChanged, object: nil)
        }
    }
}
