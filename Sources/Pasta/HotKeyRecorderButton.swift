import AppKit
import Carbon

/// 点击后进入录制状态，捕获下一个「修饰键 + 主键」组合作为全局热键。
final class HotKeyRecorderButton: NSButton {
    private var recording = false
    private var monitor: Any?

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

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil   // 录制期间吞掉按键
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTitle()
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
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "Key\(event.keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    ]
}
