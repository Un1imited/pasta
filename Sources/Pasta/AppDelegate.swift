import AppKit
import UniformTypeIdentifiers

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

        // 「跟随系统」主题：系统深浅色切换时刷新。
        // 通知可能先于 NSApp.effectiveAppearance 更新到达，异步一拍再解析主题。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                if Settings.shared.themeID == Theme.autoID {
                    NotificationCenter.default.post(name: Settings.themeChanged, object: nil)
                }
            }
        }

        panel.onPaste = { [weak self] item, plain in
            self?.performPaste(item, plainText: plain)
        }
        // 缺辅助功能权限时的退路：只写剪贴板，不模拟 ⌘V（面板负责就地提示）。
        panel.onCopyOnly = { [weak self] item, plain in
            self?.writePasteboard(item, plainText: plain)
            self?.monitor.suppressNextChange()
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
        // 历史容量：调小后立即按新上限收缩
        NotificationCenter.default.addObserver(
            forName: Settings.historyLimitChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.store.applyHistoryLimit()
        }
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.store.purgeExpired()
            self?.autoBackupIfDue()
        }
        // 启动 1 分钟后补一次到期检查（比如隔了几天没开机）
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.autoBackupIfDue()
        }

        // 权限申请刻意不在启动时做：启动即弹系统授权吓人且归因不明。
        // 推迟到首次真正回车粘贴——面板的权限 toast 会就地解释并直达设置。

        // 首次启动：自动唤起一次面板，让教学空态（"复制任意内容试试…"）完成自我介绍。
        if !Settings.shared.hasCompletedFirstRun {
            Settings.shared.hasCompletedFirstRun = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePanel(forceShow: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()   // 落盘挂起的写盘合并
    }

    // MARK: - 菜单栏

    /// 自绘的菜单栏单色模板图标：「层叠卡片」——剪贴历史 = 不止一张卡。
    /// 后卡右上露出一角（上一条记录），前卡 = 面板卡片（圆角卡 + 一长一短内容行）。
    /// 纯面性无描边（1x 不糊化），关键几何落在 0.25pt 网格。设计稿见 _design/menubar-icon-v1.png。
    private static func makeMenuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()

            // 后卡：右上方露出一角
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: 2.0, width: 9.0, height: 11.5),
                         xRadius: 2.25, yRadius: 2.25).fill()

            // 前卡外扩 1.1pt 的呼吸缝：把后卡被压住的部分挖掉
            ctx.setBlendMode(.destinationOut)
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.5, width: 9.5, height: 11.5).insetBy(dx: -1.1, dy: -1.1),
                         xRadius: 3.35, yRadius: 3.35).fill()
            ctx.setBlendMode(.normal)

            // 前卡：主体
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.5, width: 9.5, height: 11.5),
                         xRadius: 2.25, yRadius: 2.25).fill()

            // 前卡内容行：一长一短，镂空
            ctx.setBlendMode(.destinationOut)
            NSBezierPath(roundedRect: NSRect(x: 4.75, y: 8.0, width: 5.0, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(roundedRect: NSRect(x: 4.75, y: 11.0, width: 3.5, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
            ctx.setBlendMode(.normal)
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
        menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "导出历史备份…", action: #selector(exportBackup), keyEquivalent: "")
        menu.addItem(withTitle: "导入历史备份…", action: #selector(importBackup), keyEquivalent: "")
        menu.addItem(withTitle: "清空历史（保留常用）", action: #selector(clearHistory), keyEquivalent: "")

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

    @objc private func clearHistory() {
        let count = store.items.filter { !$0.pinned }.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "清空剪贴历史？"
        alert.informativeText = "将删除 \(count) 条记录，常用（置顶）项会保留。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        // 破坏性动作标红，回车默认键让给"取消"（HIG：默认键不应指向不可撤销的删除）
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    @objc private func openPreferences() { preferences.showCentered() }

    // MARK: - 备份

    @objc private func exportBackup() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "Pasta-备份-\(df.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            do {
                try self.store.exportBackup(to: url)
                self.backupAlert("备份已导出", "共 \(self.store.items.count) 条记录（含图片）。\n文件：\(url.lastPathComponent)")
            } catch {
                self.backupAlert("导出失败", error.localizedDescription, style: .warning)
            }
        }
    }

    @objc private func importBackup() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "选择 Pasta 备份 zip：按记录合并导入，不会覆盖现有历史"
        panel.prompt = "导入"
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            do {
                let added = try self.store.importBackup(from: url)
                self.backupAlert("导入完成", added > 0 ? "新增 \(added) 条记录（重复记录已跳过）。" : "没有新增记录——备份内容与现有历史完全重合。")
            } catch {
                self.backupAlert("导入失败", error.localizedDescription, style: .warning)
            }
        }
    }

    private func backupAlert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    /// 每日自动备份：开关 + 目录都设好、距上次 ≥ 23 小时才执行；滚动保留最近 3 份。
    private func autoBackupIfDue() {
        guard Settings.shared.autoBackupEnabled,
              let dirPath = Settings.shared.autoBackupDir else { return }
        guard Date().timeIntervalSince(Settings.shared.lastAutoBackupAt) >= 23 * 3600 else { return }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            NSLog("Pasta: 自动备份目录不存在，跳过：\(dirPath)")
            return
        }
        Settings.shared.lastAutoBackupAt = Date()   // 先记时间：失败也不在同一小时内反复重试
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        let dest = dir.appendingPathComponent("Pasta-自动备份-\(df.string(from: Date())).zip")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.store.exportBackup(to: dest)
                // 滚动清理：只留最近 3 份自动备份
                let files = ((try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("Pasta-自动备份-") && $0.pathExtension == "zip" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                for old in files.dropFirst(3) { try? FileManager.default.removeItem(at: old) }
                NSLog("Pasta: 自动备份完成 → \(dest.lastPathComponent)")
            } catch {
                NSLog("Pasta: 自动备份失败 \(error)")
            }
        }
    }

    // MARK: - 检查更新（手动触发才发网络请求，遵守「无后台网络」承诺）

    @objc private func checkForUpdates() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let url = URL(string: "https://api.github.com/repos/Un1imited/pasta/releases/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                guard error == nil, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    self.backupAlert("检查更新失败", "无法连接 GitHub，请稍后再试或直接访问 Releases 页。", style: .warning)
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Self.isVersion(latest, newerThan: current) {
                    let alert = NSAlert()
                    alert.messageText = "有新版本 \(latest)"
                    alert.informativeText = "当前版本 \(current)。前往下载页获取更新。"
                    alert.addButton(withTitle: "前往下载")
                    alert.addButton(withTitle: "以后再说")
                    if alert.runModal() == .alertFirstButtonReturn,
                       let page = URL(string: (obj["html_url"] as? String) ?? "https://github.com/Un1imited/pasta/releases") {
                        NSWorkspace.shared.open(page)
                    }
                } else {
                    self.backupAlert("已是最新版本", "当前版本 \(current) 即为最新发布。")
                }
            }
        }.resume()
    }

    /// 语义化版本比较（按数字段逐位比）。
    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

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
        writePasteboard(item, plainText: plainText)
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

    /// 把选中项写入系统剪贴板（不模拟粘贴）。
    private func writePasteboard(_ item: ClipItem, plainText: Bool) {
        let pb = NSPasteboard.general
        switch item.kind {
        case .text:
            // rtf 入库后不常驻内存：先取内存（刚复制的在途条目），否则从库回读
            if !plainText, let rtf = item.rtfData ?? store.rtfData(for: item.id) {
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
            if let data = item.imageBytes, let img = NSImage(data: data) {
                pb.writeObjects([img])
            }
        }
    }
}
