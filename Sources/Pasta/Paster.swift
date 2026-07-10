import AppKit
import ApplicationServices
import Carbon

/// 负责申请辅助功能权限、模拟 ⌘V 把内容粘贴到目标 App。
enum Paster {
    /// 启动时检查/申请「辅助功能」权限（模拟按键需要）。
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 系统是否处于安全键盘输入状态（密码框、终端 Secure Keyboard Entry）。
    /// 此状态下模拟 ⌘V 会被系统抑制。
    static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// 打开系统设置的「隐私与安全性 → 辅助功能」页。
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 模拟一次 ⌘V。
    static func simulatePasteShortcut() {
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
