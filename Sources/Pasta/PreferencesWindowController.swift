import AppKit
import UniformTypeIdentifiers

/// 偏好设置窗口：热键、纯文本粘贴、历史过期、忽略应用。
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let recorder = HotKeyRecorderButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    private let plainCheck = NSButton(checkboxWithTitle: "粘贴为纯文本（去格式）", target: nil, action: nil)
    private let expirationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let limitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ignoredTable = NSTableView()
    private let ignoredButtons = NSSegmentedControl()
    private let remoteCheck = NSButton(checkboxWithTitle: "忽略来自 iPhone / iPad 的接力内容", target: nil, action: nil)
    private let autoBackupCheck = NSButton(checkboxWithTitle: "每天自动备份（滚动保留 3 份）", target: nil, action: nil)
    private let autoBackupPathLabel = NSTextField(labelWithString: "未选择目录")
    private var ignoredApps: [String] = []

    private let expirationOptions: [(title: String, days: Int)] = [
        ("保留 1 天", 1), ("保留 7 天", 7), ("保留 30 天", 30), ("保留 3 个月", 90), ("保留 6 个月", 180),
    ]

    private let limitOptions: [(title: String, count: Int)] = [
        ("500 条", 500), ("1000 条", 1000), ("2000 条", 2000), ("5000 条", 5000),
    ]

    /// 主题下拉的选项：跟随系统 + 全部具名主题。
    private let themeOptions: [(id: String, name: String)] =
        [(Theme.autoID, "跟随系统（午夜青 / 晨光）")] + Theme.all.map { ($0.id, $0.name) }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
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

        let rowTheme = NSStackView(views: [label("主题皮肤"), themePopup])
        let rowHotkey = NSStackView(views: [label("唤起快捷键"), recorder])
        let rowPlain = NSStackView(views: [label("粘贴方式"), plainCheck])
        // 保留时长上限 6 个月是隐私立场（控制敏感内容留存面），不解释会被当成功能缺失
        let expireHint = NSTextField(wrappingLabelWithString:
            "最长 6 个月：限制敏感内容的留存时间。需要长期保留的记录请加入「常用」（⌘P），常用项永不过期。")
        expireHint.font = .systemFont(ofSize: Typo.caption)
        expireHint.textColor = .tertiaryLabelColor
        let expireBox = NSStackView(views: [expirationPopup, expireHint])
        expireBox.orientation = .vertical
        expireBox.spacing = 4
        expireBox.alignment = .leading
        let rowExpire = NSStackView(views: [label("历史保留"), expireBox])
        rowExpire.alignment = .top
        let rowLimit = NSStackView(views: [label("历史容量"), limitPopup])

        for (id, name) in themeOptions {
            themePopup.addItem(withTitle: name)
            // 色板预览：不唤面板也能看到主题长相；「跟随系统」用深浅拼半
            themePopup.lastItem?.image = id == Theme.autoID
                ? Self.splitSwatch(dark: .midnight, light: .daylight)
                : Self.swatch(for: Theme.by(id: id))
        }
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        for option in expirationOptions { expirationPopup.addItem(withTitle: option.title) }
        expirationPopup.target = self
        expirationPopup.action = #selector(expirationChanged)
        for option in limitOptions { limitPopup.addItem(withTitle: option.title) }
        limitPopup.target = self
        limitPopup.action = #selector(limitChanged)
        plainCheck.target = self
        plainCheck.action = #selector(plainChanged)

        for row in [rowTheme, rowHotkey, rowPlain, rowExpire, rowLimit] {
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            (row.views.first as? NSTextField)?.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        rowExpire.alignment = .top   // 多行内容：标签对齐首行（循环里统一设的 centerY 不适用）

        let hint = NSTextField(wrappingLabelWithString: "提示：列表中按 ⏎ 用上面设置的方式粘贴；按 ⌥⏎ 临时强制纯文本粘贴。")
        hint.font = .systemFont(ofSize: Typo.caption)
        hint.textColor = .tertiaryLabelColor

        // 忽略应用：表格 + 添加/移除按钮
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.width = 272                      // 撑满滚动区（296 − 滚动条），默认 100 会截断文字
        ignoredTable.addTableColumn(col)
        ignoredTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        ignoredTable.headerView = nil
        ignoredTable.rowHeight = 22
        ignoredTable.dataSource = self
        ignoredTable.delegate = self
        ignoredTable.setAccessibilityLabel("忽略应用列表")
        let ignoredScroll = NSScrollView()
        ignoredScroll.documentView = ignoredTable
        ignoredScroll.hasVerticalScroller = true
        ignoredScroll.borderType = .bezelBorder
        ignoredScroll.translatesAutoresizingMaskIntoConstraints = false

        ignoredButtons.segmentStyle = .smallSquare
        ignoredButtons.trackingMode = .momentary
        ignoredButtons.segmentCount = 2
        ignoredButtons.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "添加忽略应用"), forSegment: 0)
        ignoredButtons.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "移除选中的忽略应用"), forSegment: 1)
        ignoredButtons.setWidth(24, forSegment: 0)
        ignoredButtons.setWidth(24, forSegment: 1)
        ignoredButtons.target = self
        ignoredButtons.action = #selector(ignoredButtonsClicked)

        let ignoredHint = NSTextField(wrappingLabelWithString: "从这些 App 复制的内容不记入历史（已有记录不受影响）。适合终端「选中即复制」等场景。")
        ignoredHint.font = .systemFont(ofSize: Typo.caption)
        ignoredHint.textColor = .tertiaryLabelColor

        remoteCheck.target = self
        remoteCheck.action = #selector(remoteChanged)

        // 自动备份：开关 + 目录选择 + 当前路径
        autoBackupCheck.target = self
        autoBackupCheck.action = #selector(autoBackupToggled)
        let chooseBtn = NSButton(title: "选择目录…", target: self, action: #selector(chooseBackupDir))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.controlSize = .small
        autoBackupPathLabel.font = .systemFont(ofSize: Typo.caption)
        autoBackupPathLabel.textColor = .tertiaryLabelColor
        autoBackupPathLabel.lineBreakMode = .byTruncatingMiddle
        let backupLine = NSStackView(views: [autoBackupCheck, chooseBtn])
        backupLine.orientation = .horizontal
        backupLine.spacing = 8
        let backupBox = NSStackView(views: [backupLine, autoBackupPathLabel])
        backupBox.orientation = .vertical
        backupBox.spacing = 4
        backupBox.alignment = .leading
        let rowBackup = NSStackView(views: [label("自动备份"), backupBox])
        rowBackup.orientation = .horizontal
        rowBackup.spacing = 12
        rowBackup.alignment = .top
        rowBackup.translatesAutoresizingMaskIntoConstraints = false
        (rowBackup.views.first as? NSTextField)?.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let ignoredBox = NSStackView(views: [ignoredScroll, ignoredButtons, ignoredHint, remoteCheck])
        ignoredBox.orientation = .vertical
        ignoredBox.spacing = 6
        ignoredBox.alignment = .leading
        let rowIgnored = NSStackView(views: [label("忽略应用"), ignoredBox])
        rowIgnored.orientation = .horizontal
        rowIgnored.spacing = 12
        rowIgnored.alignment = .top     // 多行内容：标签对齐首行而非垂直居中
        rowIgnored.translatesAutoresizingMaskIntoConstraints = false
        (rowIgnored.views.first as? NSTextField)?.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let stack = NSStackView(views: [rowTheme, rowHotkey, rowPlain, rowExpire, rowLimit, rowBackup, rowIgnored, hint])
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
            expireHint.widthAnchor.constraint(equalToConstant: 296),
            ignoredScroll.widthAnchor.constraint(equalToConstant: 296),
            ignoredScroll.heightAnchor.constraint(equalToConstant: 84),
            ignoredHint.widthAnchor.constraint(equalToConstant: 296),
            autoBackupPathLabel.widthAnchor.constraint(equalToConstant: 296),
        ])
    }

    /// 主题色板缩略：面板底 + 卡底 + accent 圆点。
    private static func swatch(for theme: Theme) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            // 面板底（shelfTint 按不透明近似；渐变主题取中间色，色数不足时兜底）
            let shelf: NSColor = {
                guard let g = theme.gradient, g.count >= 2 else { return theme.shelfTint }
                return g[1]
            }()
            NSColor(srgbRed: shelf.usingColorSpace(.sRGB)!.redComponent,
                    green: shelf.usingColorSpace(.sRGB)!.greenComponent,
                    blue: shelf.usingColorSpace(.sRGB)!.blueComponent, alpha: 1).setFill()
            path.fill()
            // 卡底
            theme.cardBG.withAlphaComponent(1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 12, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            // accent 圆点
            theme.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: 17, y: 5, width: 5, height: 5)).fill()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    /// 「跟随系统」的对角拼半色板：左上深色、右下浅色。
    private static func splitSwatch(dark: Theme, light: Theme) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            dark.cardBG.withAlphaComponent(1).setFill()
            rect.fill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            tri.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            tri.line(to: NSPoint(x: rect.minX, y: rect.minY))
            tri.close()
            light.cardBG.withAlphaComponent(1).setFill()
            tri.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            dark.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 8, width: 5, height: 5)).fill()
            light.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: 3, width: 5, height: 5)).fill()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    // MARK: - 忽略应用

    func numberOfRows(in tableView: NSTableView) -> Int { ignoredApps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard ignoredApps.indices.contains(row) else { return nil }
        let bid = ignoredApps[row]
        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.spacing = 6
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        } else {
            iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            name = bid   // 未安装/已卸载：直接显示 bundle id
        }
        let text = NSTextField(labelWithString: name == bid ? bid : "\(name)（\(bid)）")
        text.font = .systemFont(ofSize: Typo.control)
        text.lineBreakMode = .byTruncatingMiddle
        cell.addArrangedSubview(iconView)
        cell.addArrangedSubview(text)
        return cell
    }

    @objc private func ignoredButtonsClicked() {
        if ignoredButtons.selectedSegment == 0 { addIgnoredApp() } else { removeIgnoredApp() }
    }

    private func addIgnoredApp() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.message = "选择要忽略的 App：从它复制的内容不记入历史"
        panel.prompt = "忽略"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK else { return }
            for url in panel.urls {
                guard let bid = Bundle(url: url)?.bundleIdentifier?.lowercased() else { continue }
                if !self.ignoredApps.contains(bid) { self.ignoredApps.append(bid) }
            }
            Settings.shared.ignoredApps = self.ignoredApps
            self.ignoredTable.reloadData()
        }
    }

    private func removeIgnoredApp() {
        let row = ignoredTable.selectedRow
        guard ignoredApps.indices.contains(row) else { return }
        ignoredApps.remove(at: row)
        Settings.shared.ignoredApps = ignoredApps
        ignoredTable.reloadData()
    }

    @objc private func remoteChanged() {
        Settings.shared.ignoreRemoteClipboard = (remoteCheck.state == .on)
    }

    @objc private func autoBackupToggled() {
        Settings.shared.autoBackupEnabled = (autoBackupCheck.state == .on)
        // 开了开关还没选目录：直接弹目录选择，别留半配置状态
        if Settings.shared.autoBackupEnabled, Settings.shared.autoBackupDir == nil { chooseBackupDir() }
    }

    @objc private func chooseBackupDir() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择自动备份目录（每天一份，滚动保留 3 份）"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            Settings.shared.autoBackupDir = url.path
            self.autoBackupPathLabel.stringValue = url.path
        }
    }

    private func loadCurrentValues() {
        ignoredApps = Settings.shared.ignoredApps
        ignoredTable.reloadData()
        remoteCheck.state = Settings.shared.ignoreRemoteClipboard ? .on : .off
        autoBackupCheck.state = Settings.shared.autoBackupEnabled ? .on : .off
        autoBackupPathLabel.stringValue = Settings.shared.autoBackupDir ?? "未选择目录"
        plainCheck.state = Settings.shared.plainTextPaste ? .on : .off
        let days = Settings.shared.expirationDays
        let idx = expirationOptions.firstIndex { $0.days == days } ?? 0
        expirationPopup.selectItem(at: idx)
        let limit = Settings.shared.maxHistoryItems
        let lIdx = limitOptions.firstIndex { $0.count == limit } ?? (limitOptions.count - 1)
        limitPopup.selectItem(at: lIdx)
        let tIdx = themeOptions.firstIndex { $0.id == Settings.shared.themeID } ?? 1  // 找不到时退到午夜青
        themePopup.selectItem(at: tIdx)
    }

    @objc private func themeChanged() {
        let idx = themePopup.indexOfSelectedItem
        guard themeOptions.indices.contains(idx) else { return }
        Settings.shared.themeID = themeOptions[idx].id
    }

    @objc private func plainChanged() {
        Settings.shared.plainTextPaste = (plainCheck.state == .on)
    }

    @objc private func expirationChanged() {
        let idx = expirationPopup.indexOfSelectedItem
        guard expirationOptions.indices.contains(idx) else { return }
        Settings.shared.expirationDays = expirationOptions[idx].days
    }

    @objc private func limitChanged() {
        let idx = limitPopup.indexOfSelectedItem
        guard limitOptions.indices.contains(idx) else { return }
        Settings.shared.maxHistoryItems = limitOptions[idx].count
    }
}
