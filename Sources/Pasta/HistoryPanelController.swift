import AppKit

/// 可成为 key window 的无边框面板（borderless 默认不能接收键盘输入）。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Paste 风格的剪贴板卡片。
final class ClipCardView: NSView {
    var onSelect: (() -> Void)?
    var onActivate: (() -> Void)?

    private let metaLabel = NSTextField(labelWithString: "")   // 「类型 · 时间」单行
    private let badge = NSImageView()
    private let pinView = NSImageView()
    private let headerLine = NSBox()
    private let footerLine = NSBox()
    private let bodyText = NSTextField(wrappingLabelWithString: "")
    private let bodyImage = NSImageView()
    private let srcLabel = NSTextField(labelWithString: "")     // 底部左：来源 App
    private let countLabel = NSTextField(labelWithString: "")   // 底部右：字符数/尺寸
    private let topHi = NSView()                                // 顶部内高光（机械质感）
    private let blue = NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 1)   // #18c3f4
    private let shortFont = NSFont.systemFont(ofSize: 14.5, weight: .medium)        // 短内容：大而醒目、居中
    private let longFont = NSFont.systemFont(ofSize: 12.5)                          // 长内容：常规、顶对齐
    private var isImage = false
    private var dark = true
    private var bodyShort = false
    private(set) var selected = false
    private var selFocused = true        // 卡片区是否为当前焦点区（false 时蓝框降级为灰框）
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    static let cardW: CGFloat = 152
    static let cardH: CGFloat = 212

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardW, height: Self.cardH))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = false        // 不裁剪，才能投浮起阴影
        layer?.borderWidth = 1

        metaLabel.font = .systemFont(ofSize: 11)

        badge.imageScaling = .scaleProportionallyUpOrDown
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        pinView.contentTintColor = .systemOrange

        headerLine.boxType = .custom
        headerLine.borderWidth = 0
        footerLine.boxType = .custom
        footerLine.borderWidth = 0

        bodyText.font = .systemFont(ofSize: 12.5)   // 正文当主角，略大
        bodyText.maximumNumberOfLines = 0
        bodyText.lineBreakMode = .byTruncatingTail
        bodyText.cell?.wraps = true
        bodyText.cell?.truncatesLastVisibleLine = true

        bodyImage.imageScaling = .scaleProportionallyUpOrDown
        bodyImage.wantsLayer = true
        bodyImage.layer?.cornerRadius = 6
        bodyImage.layer?.masksToBounds = true

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.alignment = .right
        srcLabel.font = .systemFont(ofSize: 10.5)
        srcLabel.lineBreakMode = .byTruncatingTail

        topHi.wantsLayer = true
        topHi.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor

        for v in [metaLabel, badge, pinView, headerLine, footerLine, bodyText, bodyImage, srcLabel, countLabel, topHi] {
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ item: ClipItem) {
        isImage = item.kind == .image
        dark = true        // 统一亮卡：不再跟随来源深浅（重度 IDE 用户几乎全是深色源）
        countLabel.stringValue = item.footerInfo
        srcLabel.stringValue = item.sourceAppName ?? ""
        pinView.isHidden = !item.pinned

        if let icon = item.sourceAppIcon {
            badge.image = icon
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }

        if isImage {
            bodyImage.isHidden = false
            bodyText.isHidden = true
            bodyImage.image = item.thumbnail
        } else {
            bodyImage.isHidden = true
            bodyText.isHidden = false
            bodyText.stringValue = item.bodyText
        }
        applyTone()
        applyMeta(item)        // 表头：纯文本只留时间，特殊类型才显示类型词
        applyState(animated: false)
        needsLayout = true
    }

    /// 表头内容：纯文本 → 仅时间；链接/图片/文件/邮箱 → 「类型(蓝) · 时间」。
    private func applyMeta(_ item: ClipItem) {
        let dim = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.42)
        if item.showsKindInHeader {
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: item.kindLabel,
                attributes: [.foregroundColor: blue, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            s.append(NSAttributedString(string: " · \(item.relativeTime)",
                attributes: [.foregroundColor: dim, .font: NSFont.systemFont(ofSize: 11)]))
            metaLabel.attributedStringValue = s
        } else {
            metaLabel.stringValue = item.relativeTime
            metaLabel.textColor = dim
        }
    }

    /// 根据来源深浅设置卡片配色（深卡白字 / 米白卡黑字）。
    private func applyTone() {
        let fg = dark ? NSColor.white : NSColor.black
        bodyText.textColor = fg.withAlphaComponent(dark ? 0.90 : 0.86)
        srcLabel.textColor = fg.withAlphaComponent(0.5)
        countLabel.textColor = fg.withAlphaComponent(0.32)
        let line = fg.withAlphaComponent(dark ? 0.07 : 0.06)
        headerLine.fillColor = line
        footerLine.fillColor = line
    }

    func setSelected(_ on: Bool, focused: Bool = true) {
        selected = on
        selFocused = focused
        applyState(animated: true)
    }

    /// 计算并应用卡片当前状态（选中 / hover / 普通），animated 时做 0.14s 平滑过渡。
    private func applyState(animated: Bool) {
        let hot = hovering && !selected
        let selBorder = selFocused ? blue : (dark ? NSColor.white.withAlphaComponent(0.5) : NSColor.black.withAlphaComponent(0.4))
        // 米白卡 #f6f6f7（hover 提亮到纯白）/ 深卡 #1e1e20（hover 提亮）
        let cardBG: NSColor
        let border: NSColor
        if dark {
            // 提亮卡片：冷调炭灰 #2e3138，从深底里浮出来
            cardBG = hot ? NSColor(srgbRed: 0.235, green: 0.25, blue: 0.285, alpha: 1)
                         : NSColor(srgbRed: 0.18, green: 0.192, blue: 0.22, alpha: 1)
            border = selected ? selBorder : NSColor.white.withAlphaComponent(hot ? 0.18 : 0.10)
        } else {
            cardBG = hot ? NSColor(white: 1.0, alpha: 1.0) : NSColor(white: 0.965, alpha: 1.0)
            border = selected ? selBorder : NSColor.black.withAlphaComponent(hot ? 0.10 : 0.05)
        }
        let borderW: CGFloat = selected ? 2 : 1

        let shColor: CGColor, shOpacity: Float, shRadius: CGFloat, shOffset: CGSize
        if selected && selFocused {                    // 蓝色微光浮起（卡片区聚焦）
            shColor = blue.cgColor; shOpacity = 0.55; shRadius = 15; shOffset = CGSize(width: 0, height: -2)
        } else if selected {                           // 选中但非聚焦：中性浮起
            shColor = NSColor.black.cgColor; shOpacity = 0.4; shRadius = 12; shOffset = CGSize(width: 0, height: -3)
        } else if hovering {                           // 略强黑影
            shColor = NSColor.black.cgColor; shOpacity = 0.42; shRadius = 13; shOffset = CGSize(width: 0, height: -5)
        } else {                                       // 浮起黑影（让卡片从深底弹出）
            shColor = NSColor.black.cgColor; shOpacity = 0.36; shRadius = 10; shOffset = CGSize(width: 0, height: -4)
        }

        animate("backgroundColor", cardBG.cgColor, animated)
        animate("borderColor", border.cgColor, animated)
        animate("borderWidth", borderW as NSNumber, animated)
        animate("shadowColor", shColor, animated)
        animate("shadowOpacity", shOpacity as NSNumber, animated)
        animate("shadowRadius", shRadius as NSNumber, animated)
        layer?.shadowOffset = shOffset

        // hover 轻微放大（绕中心），并抬到最上层避免被邻卡盖住
        let scale: CGFloat = hot ? 1.03 : 1.0
        animate("transform", NSValue(caTransform3D: centeredScale(scale)), animated)
        layer?.zPosition = hot ? 1 : 0
    }

    /// 绕卡片中心缩放（不改 anchorPoint，避免 AppKit 几何冲突）。
    private func centeredScale(_ s: CGFloat) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    /// 给单个 layer 属性加显式过渡动画（layer-backed view 默认不做隐式动画）。
    private func animate(_ key: String, _ value: Any?, _ animated: Bool) {
        guard let layer else { return }
        if animated {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            a.toValue = value
            a.duration = 0.14
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "state_" + key)
        }
        layer.setValue(value, forKeyPath: key)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyState(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; applyState(animated: true) }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // 顶部内高光（横跨上沿，避开圆角）
        topHi.frame = NSRect(x: 8, y: h - 1, width: w - 16, height: 1)
        // 表头：meta + 右侧徽标
        badge.frame = NSRect(x: w - 13 - 22, y: h - 32, width: 22, height: 22)
        metaLabel.frame = NSRect(x: 13, y: h - 28, width: w - 13 - 30 - 8, height: 15)
        headerLine.frame = NSRect(x: 13, y: h - 44, width: w - 26, height: 0.5)
        // 底部：左来源 App，右字符数；置顶角标在最右
        footerLine.frame = NSRect(x: 13, y: 33, width: w - 26, height: 0.5)
        let countW: CGFloat = 70
        countLabel.frame = NSRect(x: w - 13 - countW, y: 10, width: countW, height: 14)
        let pinned = !pinView.isHidden
        let srcRight = w - 13 - countW - 6
        srcLabel.frame = NSRect(x: pinned ? 13 + 16 : 13, y: 10, width: max(0, srcRight - (pinned ? 13 + 16 : 13)), height: 14)
        pinView.frame = NSRect(x: 13, y: 11, width: 12, height: 12)

        // 正文区 [33, h-44]
        let bodyTop = h - 44, bodyBottom: CGFloat = 33
        let areaH = bodyTop - bodyBottom
        let bw = w - 26
        if isImage {
            bodyImage.frame = NSRect(x: 13, y: bodyBottom + 4, width: bw, height: areaH - 8)
            return
        }
        // 智能对齐：先以常规字体量高度，判断长短
        func measure(_ font: NSFont) -> CGFloat {
            (bodyText.stringValue as NSString).boundingRect(
                with: NSSize(width: bw, height: 4000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]).height
        }
        bodyShort = measure(longFont) <= areaH * 0.5
        let font = bodyShort ? shortFont : longFont
        bodyText.font = font
        let natural = ceil(measure(font)) + 2
        let textH = min(natural, areaH)
        let y = bodyShort
            ? bodyBottom + (areaH - textH) / 2          // 短内容：垂直居中
            : bodyTop - textH - 2                        // 长内容：顶对齐
        bodyText.frame = NSRect(x: 13, y: y, width: bw, height: textH)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onActivate?() } else { onSelect?() }
    }

    /// 让卡片内任意位置（含文字/图片子视图）的点击都落到卡片本身。
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point) != nil ? self : nil
    }
}

/// Paste 风格的底部卡片栏：贴屏幕底部、全宽、横向卡片。
final class HistoryPanelController: NSObject, NSTextFieldDelegate {
    private let store: ClipboardStore
    /// 选中某条 -> 由 AppDelegate 执行真正的写剪贴板 + 粘贴。第二个参数为是否纯文本粘贴。
    var onPaste: ((ClipItem, Bool) -> Void)?

    private var panel: KeyablePanel!
    private var blur: NSVisualEffectView!
    private var searchField: NSTextField!
    private var magnifier: NSImageView!
    private var countLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var tabControl: NSSegmentedControl!
    private var tabContainer: NSView!
    private var showPinnedOnly = false
    private var divider: NSBox!
    private var cardScroll: NSScrollView!
    private var cardStrip: NSView!
    private var emptyLabel: NSTextField!
    private var keyMonitor: Any?

    private enum Focus { case search, tabs, cards }
    private var focusZone: Focus = .cards
    private var searchContainer: NSView!
    private let accentBlue = NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 1)   // #18c3f4

    private var filtered: [ClipItem] = []
    private var cardViews: [ClipCardView] = []
    private var selectedIndex = 0

    private let shelfHeight: CGFloat = 332
    private let toolbarH: CGFloat = 46
    private let gap: CGFloat = 14
    private let pad: CGFloat = 18

    init(store: ClipboardStore) {
        self.store = store
        super.init()
        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refilterIfVisible() }
        }
        buildPanel()
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - 构建界面

    private func buildPanel() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: shelfHeight),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)

        blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        // 提亮磨砂：更淡更透的冷调 tint，让毛玻璃通透不沉闷
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.149, green: 0.169, blue: 0.212, alpha: 0.40).cgColor
        tint.frame = blur.bounds
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)

        // 顶部品牌色微光（青）：破掉全黑、注入一点生气
        let brandGlow = NSView()
        brandGlow.wantsLayer = true
        brandGlow.frame = NSRect(x: 0, y: shelfHeight - 96, width: blur.bounds.width, height: 96)
        brandGlow.autoresizingMask = [.width, .minYMargin]
        let glowLayer = CAGradientLayer()
        glowLayer.colors = [
            NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 0.14).cgColor,
            NSColor.clear.cgColor,
        ]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 1.0)   // 顶部青 → 向下渐隐
        glowLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        glowLayer.frame = CGRect(x: 0, y: 0, width: 6000, height: 96)   // 超宽，覆盖任意屏宽
        brandGlow.layer?.addSublayer(glowLayer)
        blur.addSubview(brandGlow)

        // 顶部一道白微光，勾出磨砂面板的上边缘
        let topHighlight = NSView()
        topHighlight.wantsLayer = true
        topHighlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        topHighlight.frame = NSRect(x: 0, y: shelfHeight - 1, width: blur.bounds.width, height: 1)
        topHighlight.autoresizingMask = [.width, .minYMargin]
        blur.addSubview(topHighlight)

        // 工具条：搜索框（含焦点蓝环容器）
        searchContainer = NSView()
        searchContainer.wantsLayer = true
        searchContainer.layer?.masksToBounds = false
        searchContainer.layer?.cornerRadius = 8
        searchContainer.layer?.borderWidth = 2
        searchContainer.layer?.borderColor = NSColor.clear.cgColor
        blur.addSubview(searchContainer)

        magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        magnifier.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        searchContainer.addSubview(magnifier)

        searchField = NSTextField()
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .white
        searchField.placeholderString = "搜索剪贴历史…"
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchContainer.addSubview(searchField)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        countLabel.alignment = .right
        blur.addSubview(countLabel)

        hintLabel = NSTextField(labelWithString: "↩ 粘贴 · ⌘P 置顶")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.32)
        hintLabel.alignment = .right
        blur.addSubview(hintLabel)

        // 剪贴板 / 置顶 标签页
        // 原生分段控件（系统级选中样式）+ 外层容器（焦点蓝环）
        tabControl = NSSegmentedControl(labels: ["剪贴板", "置顶"], trackingMode: .selectOne,
                                        target: self, action: #selector(tabClicked))
        tabControl.segmentStyle = .capsule
        tabControl.selectedSegment = 0
        tabControl.sizeToFit()
        let cs = tabControl.frame.size
        tabControl.frame = NSRect(x: 6, y: 6, width: cs.width, height: cs.height)
        tabContainer = NSView(frame: NSRect(x: 0, y: 0, width: cs.width + 12, height: cs.height + 12))
        tabContainer.wantsLayer = true
        tabContainer.layer?.masksToBounds = false
        tabContainer.layer?.cornerRadius = (cs.height + 12) / 2
        tabContainer.layer?.borderWidth = 2
        tabContainer.layer?.borderColor = NSColor.clear.cgColor
        tabContainer.addSubview(tabControl)
        blur.addSubview(tabContainer)
        updateTabs()

        divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = NSColor.white.withAlphaComponent(0.08)
        blur.addSubview(divider)

        // 卡片横向滚动区
        cardScroll = NSScrollView()
        cardScroll.drawsBackground = false
        cardScroll.hasVerticalScroller = false
        cardScroll.hasHorizontalScroller = false
        cardScroll.autohidesScrollers = true
        cardScroll.verticalScrollElasticity = .none
        cardStrip = NSView()
        cardScroll.documentView = cardStrip
        blur.addSubview(cardScroll)

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        emptyLabel.isHidden = true
        blur.addSubview(emptyLabel)
    }

    private func layoutShelf(width W: CGFloat) {
        let H = shelfHeight
        let yc = H - toolbarH / 2
        let searchW: CGFloat = 236
        searchContainer.frame = NSRect(x: 12, y: yc - 16, width: searchW, height: 32)
        magnifier.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
        searchField.frame = NSRect(x: 32, y: 4, width: searchW - 42, height: 24)
        tabContainer.setFrameOrigin(NSPoint(x: 12 + searchW + 12, y: yc - tabContainer.frame.height / 2))
        hintLabel.frame = NSRect(x: W - 230, y: yc - 8, width: 150, height: 16)
        countLabel.frame = NSRect(x: W - 70, y: yc - 9, width: 56, height: 18)
        divider.frame = NSRect(x: 0, y: H - toolbarH, width: W, height: 0.5)
        cardScroll.frame = NSRect(x: 0, y: 0, width: W, height: H - toolbarH)
        emptyLabel.frame = NSRect(x: 0, y: 0, width: W, height: H - toolbarH)
    }

    private func updateTabs() {
        tabControl.selectedSegment = showPinnedOnly ? 1 : 0
    }

    /// 焦点区视觉：聚焦的区域加蓝环 + 蓝色辉光；卡片区聚焦 → 选中卡蓝框。
    private func updateFocusVisuals() {
        focusRing(searchContainer, focusZone == .search)
        focusRing(tabContainer, focusZone == .tabs)
        magnifier.contentTintColor = focusZone == .search
            ? accentBlue : NSColor.white.withAlphaComponent(0.45)
        if cardViews.indices.contains(selectedIndex) {
            cardViews[selectedIndex].setSelected(true, focused: focusZone == .cards)
        }
    }

    private func focusRing(_ view: NSView, _ on: Bool) {
        view.layer?.borderColor = (on ? accentBlue : NSColor.clear).cgColor
        view.layer?.shadowColor = accentBlue.cgColor
        view.layer?.shadowOpacity = on ? 0.55 : 0
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = .zero
    }

    private func setZone(_ z: Focus) {
        guard focusZone != z else { return }
        focusZone = z
        updateFocusVisuals()
    }

    /// 鼠标点击分段控件 → 焦点切到标签区，之后方向键作用在标签上。
    @objc private func tabClicked() {
        showPinnedOnly = tabControl.selectedSegment == 1
        focusZone = .tabs
        refilter()
        updateFocusVisuals()
    }

    /// 切到指定标签（剪贴板 / 置顶）。
    private func selectTab(pinned: Bool) {
        guard showPinnedOnly != pinned else { return }
        showPinnedOnly = pinned
        updateTabs()
        refilter()
    }

    // MARK: - 显隐

    func show() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: shelfHeight), display: true)
        layoutShelf(width: f.width)

        searchField.stringValue = ""
        showPinnedOnly = false
        focusZone = .cards
        updateTabs()
        refilter()
        updateFocusVisuals()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(searchField)
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 124:                                          // → 搜索→标签→(剪贴板→置顶)
                switch self.focusZone {
                case .cards: self.moveSelection(1)
                case .search: self.setZone(.tabs)
                case .tabs: if !self.showPinnedOnly { self.selectTab(pinned: true) }
                }
                return nil
            case 123:                                          // ← (置顶→剪贴板→搜索)
                switch self.focusZone {
                case .cards: self.moveSelection(-1)
                case .tabs: self.showPinnedOnly ? self.selectTab(pinned: false) : self.setZone(.search)
                case .search: break
                }
                return nil
            case 126: if self.focusZone == .cards { self.setZone(.tabs) }; return nil   // ↑ 上到顶部
            case 125: if self.focusZone != .cards { self.setZone(.cards) }; return nil  // ↓ 回卡片
            case 36, 76:                                        // return / enter
                if self.focusZone == .tabs {
                    self.setZone(.cards)                        // 标签区回车 → 切到卡片区
                } else {
                    let plain = Settings.shared.plainTextPaste || event.modifierFlags.contains(.option)
                    self.pasteSelected(plain: plain)           // 搜索/卡片区回车 → 粘贴选中项
                }
                return nil
            case 53: self.hide(); return nil                   // esc
            case 35 where cmd: self.togglePinSelected(); return nil   // ⌘P
            case 51 where cmd: self.deleteSelected(); return nil      // ⌘⌫
            case 18 where cmd: self.selectTab(pinned: false); return nil  // ⌘1 剪贴板
            case 19 where cmd: self.selectTab(pinned: true); return nil   // ⌘2 置顶
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectIndex(max(0, min(filtered.count - 1, selectedIndex + delta)))
    }

    private func selectIndex(_ i: Int) {
        guard cardViews.indices.contains(i) else { return }
        if cardViews.indices.contains(selectedIndex) { cardViews[selectedIndex].setSelected(false) }
        selectedIndex = i
        focusZone = .cards                                  // 选/点卡片 → 焦点回到卡片区
        tabContainer.layer?.borderColor = NSColor.clear.cgColor
        cardViews[i].setSelected(true, focused: true)
        let r = cardViews[i].frame.insetBy(dx: -(gap + pad), dy: 0)
        cardScroll.contentView.scrollToVisible(r)
    }

    private func pasteSelected(plain: Bool) {
        guard filtered.indices.contains(selectedIndex) else { return }
        let item = filtered[selectedIndex]
        hide()
        onPaste?(item, plain)
    }

    private func togglePinSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        store.togglePin(id: filtered[selectedIndex].id)
    }

    private func deleteSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        store.delete(id: filtered[selectedIndex].id)
    }

    // MARK: - 过滤 / 数据

    func controlTextDidChange(_ obj: Notification) {
        refilter()
    }

    private func refilterIfVisible() {
        if isVisible { refilter() }
    }

    private func refilter() {
        let q = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        let base = showPinnedOnly ? store.items.filter { $0.pinned } : store.displayItems
        filtered = q.isEmpty ? base : base.filter { $0.searchText.lowercased().contains(q) }

        countLabel.stringValue = filtered.isEmpty ? "" : "\(filtered.count) 条"
        emptyLabel.isHidden = !filtered.isEmpty
        if !q.isEmpty {
            emptyLabel.stringValue = "无匹配结果"
        } else {
            emptyLabel.stringValue = showPinnedOnly ? "暂无置顶 · 选中卡片按 ⌘P 置顶" : "暂无剪贴历史"
        }

        rebuildCards()
    }

    private func rebuildCards() {
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = []

        let scrollH = cardScroll.frame.height
        let cardY = (scrollH - ClipCardView.cardH) / 2
        // 卡片宽度自适应屏宽：一屏正好显示约 8 个
        let target: CGFloat = 8
        let scrollW = cardScroll.frame.width
        let cardW = min(260, max(170, (scrollW - pad * 2 - gap * (target - 1)) / target))
        for (i, item) in filtered.enumerated() {
            let card = ClipCardView()
            card.frame = NSRect(x: pad + CGFloat(i) * (cardW + gap),
                                y: cardY, width: cardW, height: ClipCardView.cardH)
            card.configure(item)
            let idx = i
            card.onSelect = { [weak self] in self?.selectIndex(idx) }
            card.onActivate = { [weak self] in
                self?.selectIndex(idx)
                self?.pasteSelected(plain: Settings.shared.plainTextPaste)
            }
            cardStrip.addSubview(card)
            cardViews.append(card)
        }
        let contentW = pad * 2 + CGFloat(filtered.count) * cardW
            + CGFloat(max(0, filtered.count - 1)) * gap
        cardStrip.frame = NSRect(x: 0, y: 0, width: max(contentW, cardScroll.frame.width), height: scrollH)

        if !filtered.isEmpty {
            selectedIndex = 0
            cardViews[0].setSelected(true, focused: focusZone == .cards)
            cardScroll.contentView.scroll(to: .zero)
        }
    }
}
