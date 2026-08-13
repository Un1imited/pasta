import AppKit
import Carbon
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private lazy var monitor = ClipboardMonitor(store: store)
    private let hotKey = HotKey()
    private lazy var panel = HistoryPanelController(store: store)
    private lazy var preferences = PreferencesWindowController()

    private var statusItem: NSStatusItem!
    private var showItem: NSMenuItem!
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
        // 「随色」主题：系统强调色变化时刷新（accent 族运行时现算，不快照）。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleColorPreferencesChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                if Settings.shared.themeID == Theme.accentFollowID {
                    NotificationCenter.default.post(name: Settings.themeChanged, object: nil)
                }
            }
        }

        panel.onPaste = { [weak self] item, plain in
            Settings.shared.hasCompletedFirstRun = true   // 用过一次粘贴 = 教学已完成
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
            self?.applyHotKeyToShowItem()   // 菜单里的快捷键展示跟随改键
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
        // 首启自动唤起面板后，在教学空态里以 toast + 「打开设置」引导配置（零风险时刻），
        // 错过引导则推迟到首次回车粘贴——面板的权限 toast 会就地解释并直达设置。

        // 首次启动：自动唤起一次面板，让教学空态（"复制任意内容试试…"）完成自我介绍。
        // 完成标记推迟到确认「教学被看到」：面板若在唤起瞬间被误点收掉（激活竞态/用户在别处点击），
        // 下次启动重试，教学时刻不蒸发。
        if !Settings.shared.hasCompletedFirstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.togglePanel(forceShow: true)
                // 面板稳定显示后：权限引导 toast（首启教学的「第 0 步」）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.panel.showPermissionOnboardingIfNeeded()
                }
                // 3 秒后还在屏上 = 教学被看到，才算完成首启
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    if self?.panel.isVisible == true { Settings.shared.hasCompletedFirstRun = true }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()   // 落盘挂起的写盘合并
    }

    // MARK: - 菜单栏

    /// 自绘的菜单栏单色模板图标 v2「单卡减法」：同样的「剪贴历史 = 不止一张卡」隐喻，
    /// 但前卡放大做主角、后卡只留一道更细的露角（呼吸缝 1.2pt）、内容行加粗到 1.6pt——
    /// 18pt 下更整（apple-design 第二轮图标评审选定，见 _design/menubar-icon-v2.png）。
    /// 纯面性无描边（1x 不糊化），关键几何落在 0.25pt 网格附近。
    private static func makeMenuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()

            // 后卡：右上方露出更细的一角
            NSBezierPath(roundedRect: NSRect(x: 7.2, y: 1.6, width: 8.6, height: 11.0),
                         xRadius: 2.2, yRadius: 2.2).fill()

            // 前卡外扩 1.2pt 的呼吸缝：把后卡被压住的部分挖掉
            ctx.setBlendMode(.destinationOut)
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.3, width: 10.7, height: 11.9).insetBy(dx: -1.2, dy: -1.2),
                         xRadius: 3.7, yRadius: 3.7).fill()
            ctx.setBlendMode(.normal)

            // 前卡：主体（比 v1 大 1.2pt，主角感）
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.3, width: 10.7, height: 11.9),
                         xRadius: 2.5, yRadius: 2.5).fill()

            // 前卡内容行：一长一短，镂空（1.6pt，比 v1 粗一档）
            ctx.setBlendMode(.destinationOut)
            NSBezierPath(roundedRect: NSRect(x: 4.9, y: 8.1, width: 6.2, height: 1.6),
                         xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 4.9, y: 11.3, width: 4.3, height: 1.6),
                         xRadius: 0.8, yRadius: 0.8).fill()
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
        showItem = menu.addItem(withTitle: "显示历史", action: #selector(showPanel), keyEquivalent: "")
        applyHotKeyToShowItem()
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

    /// 「显示历史」的快捷键放进原生 keyEquivalent 位（右对齐灰字，系统样式）。
    /// 状态栏菜单的 keyEquivalent 只在菜单展开时参与派发，不会与 Carbon 全局热键双触发。
    /// 主键不是单字符（Space / F 键等）时原生位放不下，退回写进标题的旧样式。
    private func applyHotKeyToShowItem() {
        let display = Settings.shared.hotKeyDisplay
        let mods = Settings.shared.hotKeyModifiers
        var mask: NSEvent.ModifierFlags = []
        if mods & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if mods & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if mods & UInt32(optionKey) != 0 { mask.insert(.option) }
        if mods & UInt32(controlKey) != 0 { mask.insert(.control) }
        let keyPart = display.drop(while: { "⌃⌥⇧⌘".contains($0) })
        if keyPart.count == 1, let ch = keyPart.first {
            showItem.title = "显示历史"
            showItem.keyEquivalent = String(ch).lowercased()
            showItem.keyEquivalentModifierMask = mask
        } else {
            showItem.title = "显示历史   \(display)"
            showItem.keyEquivalent = ""
        }
    }

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
