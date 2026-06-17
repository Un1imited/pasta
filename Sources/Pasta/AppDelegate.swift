import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private lazy var monitor = ClipboardMonitor(store: store)
    private let hotKey = HotKey()
    private lazy var panel = HistoryPanelController(store: store)
    private lazy var preferences = PreferencesWindowController()

    private var statusItem: NSStatusItem!
    private var launchItem: NSMenuItem!
    private var plainItem: NSMenuItem!
    private var expirationTimer: Timer?
    private weak var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        monitor.start()

        panel.onPaste = { [weak self] item, plain in
            self?.performPaste(item, plainText: plain)
        }

        // 全局热键：从设置读取，并监听改键。
        hotKey.setCallback { [weak self] in self?.togglePanel() }
        hotKey.update(keyCode: Settings.shared.hotKeyCode, modifiers: Settings.shared.hotKeyModifiers)
        NotificationCenter.default.addObserver(
            forName: Settings.hotKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotKey.update(
                keyCode: Settings.shared.hotKeyCode,
                modifiers: Settings.shared.hotKeyModifiers
            )
        }

        // 过期清理：设置变更时立即清，运行中每小时清一次。
        NotificationCenter.default.addObserver(
            forName: Settings.expirationChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.store.purgeExpired()
        }
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.store.purgeExpired()
        }

        // 模拟粘贴需要「辅助功能」权限，启动时引导一次。
        Paster.ensureAccessibilityPermission()
    }

    // MARK: - 菜单栏

    /// 自绘的菜单栏单色模板图标：精修剪贴板（板面 + 夹子 + 两行）。
    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            let s: CGFloat = 18.0 / 28.0            // 设计 viewBox 28 → 18pt
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            let lw: CGFloat = 1.5 * s               // 超细精准线条
            NSColor.black.setStroke()

            let board = NSBezierPath(roundedRect: NSRect(x: 6.5 * s, y: 5.5 * s, width: 15 * s, height: 18 * s),
                                     xRadius: 3 * s, yRadius: 3 * s)
            board.lineWidth = lw; board.lineJoinStyle = .round; board.stroke()

            let clip = NSBezierPath(roundedRect: NSRect(x: 10.7 * s, y: 3.5 * s, width: 6.6 * s, height: 4.6 * s),
                                    xRadius: 2.1 * s, yRadius: 2.1 * s)
            clip.lineWidth = lw; clip.lineJoinStyle = .round; clip.stroke()

            for (x2, y) in [(17.8, 13.0), (15.4, 17.0)] {
                let line = NSBezierPath()
                line.move(to: pt(10.2, y)); line.line(to: pt(x2, y))
                line.lineWidth = lw; line.lineCapStyle = .round; line.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.toolTip = "Pasta — 剪贴板历史"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示历史   \(Settings.shared.hotKeyDisplay)", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(.separator())

        plainItem = NSMenuItem(title: "粘贴为纯文本（去格式）", action: #selector(togglePlainText), keyEquivalent: "")
        plainItem.state = Settings.shared.plainTextPaste ? .on : .off
        menu.addItem(plainItem)

        menu.addItem(withTitle: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())

        menu.addItem(withTitle: "清空历史（保留置顶）", action: #selector(clearHistory), keyEquivalent: "")

        launchItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Pasta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showPanel() { togglePanel(forceShow: true) }

    @objc private func clearHistory() { store.clear() }

    @objc private func openPreferences() { preferences.showCentered() }

    @objc private func togglePlainText() {
        Settings.shared.plainTextPaste.toggle()
        plainItem.state = Settings.shared.plainTextPaste ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: - 面板

    private func togglePanel(forceShow: Bool = false) {
        if panel.isVisible && !forceShow {
            panel.hide()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.show()
    }

    // MARK: - 执行粘贴

    private func performPaste(_ item: ClipItem, plainText: Bool) {
        let pb = NSPasteboard.general
        switch item.kind {
        case .text:
            if !plainText, let rtf = item.rtfData {
                pb.clearContents()
                pb.declareTypes([.rtf, .string], owner: nil)
                pb.setData(rtf, forType: .rtf)
                pb.setString(item.text ?? "", forType: .string)
            } else {
                pb.clearContents()
                pb.setString(item.text ?? "", forType: .string)
            }
        case .file:
            pb.clearContents()
            let urls = (item.text ?? "")
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) as NSURL }
            if plainText || urls.isEmpty {
                pb.setString(item.text ?? "", forType: .string)   // 纯文本模式下粘贴路径文本
            } else {
                pb.writeObjects(urls)
            }
        case .image:
            pb.clearContents()
            if let data = item.imageData, let img = NSImage(data: data) {
                pb.writeObjects([img])
            }
        }
        monitor.suppressNextChange()

        // 让焦点回到唤起前的 App。优先精确激活，否则隐藏自己让系统自动回退。
        let myBundleID = Bundle.main.bundleIdentifier
        if let prev = previousApp, prev.bundleIdentifier != myBundleID {
            prev.activate()
        } else {
            NSApp.hide(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Paster.simulatePasteShortcut()
        }
    }
}
