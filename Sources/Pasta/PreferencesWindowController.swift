import AppKit

/// 偏好设置窗口：热键、纯文本粘贴、历史过期。
final class PreferencesWindowController: NSWindowController {
    private let recorder = HotKeyRecorderButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    private let plainCheck = NSButton(checkboxWithTitle: "粘贴为纯文本（去格式）", target: nil, action: nil)
    private let expirationPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let expirationOptions: [(title: String, days: Int)] = [
        ("保留 1 天", 1), ("保留 7 天", 7), ("保留 30 天", 30), ("保留 3 个月", 90), ("保留 6 个月", 180),
    ]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Pasta 偏好设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showCentered() {
        loadCurrentValues()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            return l
        }

        let rowHotkey = NSStackView(views: [label("唤起快捷键"), recorder])
        let rowPlain = NSStackView(views: [label("粘贴方式"), plainCheck])
        let rowExpire = NSStackView(views: [label("历史保留"), expirationPopup])

        for option in expirationOptions { expirationPopup.addItem(withTitle: option.title) }
        expirationPopup.target = self
        expirationPopup.action = #selector(expirationChanged)
        plainCheck.target = self
        plainCheck.action = #selector(plainChanged)

        for row in [rowHotkey, rowPlain, rowExpire] {
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            (row.views.first as? NSTextField)?.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }

        let hint = NSTextField(wrappingLabelWithString: "提示：列表中按 ⏎ 用上面设置的方式粘贴；按 ⌥⏎ 临时强制纯文本粘贴。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [rowHotkey, rowPlain, rowExpire, hint])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            recorder.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    private func loadCurrentValues() {
        plainCheck.state = Settings.shared.plainTextPaste ? .on : .off
        let days = Settings.shared.expirationDays
        let idx = expirationOptions.firstIndex { $0.days == days } ?? 0
        expirationPopup.selectItem(at: idx)
    }

    @objc private func plainChanged() {
        Settings.shared.plainTextPaste = (plainCheck.state == .on)
    }

    @objc private func expirationChanged() {
        let idx = expirationPopup.indexOfSelectedItem
        guard expirationOptions.indices.contains(idx) else { return }
        Settings.shared.expirationDays = expirationOptions[idx].days
    }
}
