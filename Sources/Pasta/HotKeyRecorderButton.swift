import AppKit
import Carbon

/// 点击后进入录制状态，捕获下一个「修饰键 + 主键」组合作为全局热键。
final class HotKeyRecorderButton: NSButton {
    private var recording = false
    private var monitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func refreshTitle() {
        title = recording ? "按下快捷键…  (esc 取消)" : Settings.shared.hotKeyDisplay
    }

    /// 录制态视觉：系统强调色描边（偏好窗口属于"系统世界"，用 controlAccentColor 而非面板主题色）。
    private func refreshRecordingVisual() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = recording ? 2 : 0
        layer?.borderColor = recording ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        refreshTitle()
        refreshRecordingVisual()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil   // 录制期间吞掉按键
        }
        // 关窗/失焦时必须停录：否则 monitor 残留，全 App 键盘被静默吞掉。
        if let win = window {
            let nc = NotificationCenter.default
            windowObservers = [
                nc.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                    self?.stopRecording()
                },
                nc.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
                    self?.stopRecording()
                },
            ]
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        refreshTitle()
        refreshRecordingVisual()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {   // esc 取消
            stopRecording()
            return
        }

        let flags = event.modifierFlags
        // 至少要有 ⌘ / ⌥ / ⌃ 之一，避免和普通输入冲突。
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            NSSound.beep()
            return
        }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        var display = ""
        if flags.contains(.control) { display += "⌃" }
        if flags.contains(.option) { display += "⌥" }
        if flags.contains(.shift) { display += "⇧" }
        if flags.contains(.command) { display += "⌘" }
        display += Self.keyName(for: event)

        Settings.shared.setHotKey(code: UInt32(event.keyCode), modifiers: carbon, display: display)
        stopRecording()
    }

    /// 主键的可读名称。
    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
           // 功能键等会给出 Unicode 私有区字符（0xF700-0xF8FF），显示出来是乱码
           !chars.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
            return chars.uppercased()
        }
        return "Key\(event.keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
