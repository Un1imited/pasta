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
    /// 右键菜单（由面板提供；弹出前先经 onSelect 选中本卡）。
    var menuProvider: (() -> NSMenu?)?

    private let metaLabel = NSTextField(labelWithString: "")   // 「类型 · 时间」单行
    private let badge = NSImageView()
    private let indexBadge = NSTextField(labelWithString: "")  // 按住 ⌘ 时的直达编号（⌘1-9）
    private let pinView = NSImageView()
    private let headerLine = NSBox()
    private let footerLine = NSBox()
    private let bodyText = NSTextField(wrappingLabelWithString: "")
    private let bodyImage = NSImageView()
    private let srcLabel = NSTextField(labelWithString: "")     // 底部左：来源 App
    private let countLabel = NSTextField(labelWithString: "")   // 底部右：字符数/尺寸
    private let ocrBadge = NSImageView()                        // 图片卡：OCR 完成（文字可搜）微标
    private let topHi = NSView()                                // 顶部内高光（机械质感）
    private let shortFont = NSFont.systemFont(ofSize: Typo.emphasis, weight: .medium)   // 短内容：大而醒目、居中
    private let longFont = NSFont.systemFont(ofSize: Typo.body)                         // 长内容：常规、顶对齐
    private var isImage = false
    private var theme = Theme.current
    private var bodyShort = false
    private(set) var selected = false
    private var selFocused = true        // 卡片区是否为当前焦点区（false 时蓝框降级为灰框）
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private var item: ClipItem?          // 拖出（drag-out）取内容用
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    static let cardW: CGFloat = 152
    static let cardH: CGFloat = 212
    /// 缩略图解码队列：主线程只查缓存，未命中转这里解码后回填。
    private static let thumbQueue = DispatchQueue(label: "com.local.pasta.thumb", qos: .userInitiated)

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardW, height: Self.cardH))
        wantsLayer = true
        layer?.cornerRadius = Metrics.radiusL
        layer?.masksToBounds = false        // 不裁剪，才能投浮起阴影
        layer?.borderWidth = 1

        // VoiceOver：整卡作为一个按钮元素朗读
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        metaLabel.font = .systemFont(ofSize: Typo.caption)

        badge.imageScaling = .scaleProportionallyUpOrDown
        pinView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "已收藏")
        pinView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

        headerLine.boxType = .custom
        headerLine.borderWidth = 0
        footerLine.boxType = .custom
        footerLine.borderWidth = 0

        bodyText.font = .systemFont(ofSize: Typo.body)   // 正文当主角，略大
        bodyText.maximumNumberOfLines = 0
        bodyText.lineBreakMode = .byTruncatingTail
        bodyText.cell?.wraps = true
        bodyText.cell?.truncatesLastVisibleLine = true

        bodyImage.imageScaling = .scaleProportionallyUpOrDown
        bodyImage.wantsLayer = true
        bodyImage.layer?.cornerRadius = Metrics.radiusS
        bodyImage.layer?.masksToBounds = true

        // 字数与来源同号（caption），层级只靠 cardFaint / cardDim 色彩区分
        countLabel.font = .systemFont(ofSize: Typo.caption)
        countLabel.alignment = .right
        srcLabel.font = .systemFont(ofSize: Typo.caption)
        srcLabel.lineBreakMode = .byTruncatingTail

        topHi.wantsLayer = true
        topHi.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor

        indexBadge.font = .systemFont(ofSize: Typo.badge, weight: .bold)
        indexBadge.alignment = .center
        indexBadge.wantsLayer = true
        indexBadge.layer?.cornerRadius = 4
        indexBadge.isHidden = true

        // OCR 完成微标：告诉用户「这张截图的文字已可搜索」——识别成败不再是薛定谔态
        ocrBadge.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "文字已识别，可搜索")
        ocrBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        ocrBadge.isHidden = true

        for v in [metaLabel, badge, pinView, headerLine, footerLine, bodyText, bodyImage, srcLabel, countLabel, topHi, indexBadge, ocrBadge] {
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ item: ClipItem, highlight: String? = nil) {
        // 复用卡片时清掉上一条的选中/hover/编号状态，避免残留高亮。
        selected = false
        hovering = false
        selFocused = true
        indexBadge.isHidden = true
        isImage = item.kind == .image
        theme = Theme.current
        self.item = item                 // 拖出用（值拷贝，重血包已外置不占内存）
        countLabel.stringValue = item.footerInfo
        srcLabel.stringValue = item.sourceAppName ?? ""
        pinView.isHidden = !item.pinned
        ocrBadge.isHidden = !(isImage && !(item.ocrText ?? "").isEmpty)

        if let icon = item.sourceAppIcon {
            badge.image = icon
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }

        if isImage {
            bodyImage.isHidden = false
            bodyText.isHidden = true
            if let cached = item.cachedThumbnail {
                bodyImage.image = cached
            } else {
                // 缓存未命中：主线程不做磁盘读+解码（这是唤起偶发卡顿的主因之一），
                // 后台解码完回填；回填前校验卡片没有被复用给别的条目。
                bodyImage.image = nil
                let id = item.id
                Self.thumbQueue.async { [weak self] in
                    let img = item.thumbnail
                    DispatchQueue.main.async {
                        guard let self, self.item?.id == id else { return }
                        self.bodyImage.image = img
                    }
                }
            }
        } else {
            bodyImage.isHidden = true
            bodyText.isHidden = false
            bodyText.stringValue = item.bodyText
            applyHighlight(highlight)
        }
        applyTone()
        applyMeta(item)        // 表头：纯文本只留时间，特殊类型才显示类型词
        applyState(animated: false)
        needsLayout = true

        // VoiceOver 标签：类型 + 摘要 + 来源 + 时间 + 收藏态，一句话读完整卡
        var ax = item.kindLabel
        ax += isImage ? "，\(item.footerInfo)" : "，\(String(item.bodyText.prefix(60)))"
        if let src = item.sourceAppName, !src.isEmpty { ax += "，来自 \(src)" }
        ax += "，\(item.relativeTime)"
        if item.pinned { ax += "，已收藏" }
        if !ocrBadge.isHidden { ax += "，文字已识别可搜索" }
        setAccessibilityLabel(ax)
        setAccessibilitySelected(false)
    }

    /// 搜索命中高亮：正文里的命中片段上 accent 色 + 淡底。只加色彩属性不动字体，
    /// 不影响 layout() 的文本测量。拼音命中（原文无该子串）不高亮——避免错标位置。
    private func applyHighlight(_ query: String?) {
        guard let q = query, !q.isEmpty else { return }
        let body = bodyText.stringValue
        let lower = body.lowercased()
        guard lower.contains(q) else { return }
        let attr = NSMutableAttributedString(string: body,
            attributes: [.foregroundColor: theme.cardFG])
        var searchFrom = lower.startIndex
        while let r = lower.range(of: q, range: searchFrom..<lower.endIndex) {
            attr.addAttributes([
                .foregroundColor: theme.accentTextColor,   // 亮 accent 主题（蜜柑橙）自动落到文字级深档
                .backgroundColor: theme.accent.withAlphaComponent(0.16),
            ], range: NSRange(r, in: body))
            searchFrom = r.upperBound
        }
        bodyText.attributedStringValue = attr
    }

    /// 表头内容：纯文本 → 仅时间；链接/图片/文件/邮箱 → 「类型(强调色) · 时间」。
    private func applyMeta(_ item: ClipItem) {
        if item.showsKindInHeader {
            let s = NSMutableAttributedString()
            // 类型词：有 typeTints 的主题走「糖纸贴纸」分色（字色+淡底），否则 accent 文字级单色
            let tint = theme.typeTints[item.kindLabel]
            var kindAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: tint?.fg ?? theme.accentTextColor,
                .font: NSFont.systemFont(ofSize: Typo.caption, weight: .semibold)]
            if let wash = tint?.wash { kindAttrs[.backgroundColor] = wash }
            s.append(NSAttributedString(string: item.kindLabel, attributes: kindAttrs))
            s.append(NSAttributedString(string: " · \(item.relativeTime)",
                attributes: [.foregroundColor: theme.cardDim, .font: NSFont.systemFont(ofSize: Typo.caption)]))
            metaLabel.attributedStringValue = s
        } else {
            metaLabel.stringValue = item.relativeTime
            metaLabel.textColor = theme.cardDim
        }
    }

    /// 按当前主题设置卡片文字/分隔线/内高光。
    private func applyTone() {
        bodyText.textColor = theme.cardFG
        srcLabel.textColor = theme.cardDim
        countLabel.textColor = theme.cardFaint
        ocrBadge.contentTintColor = theme.cardFaint
        pinView.contentTintColor = theme.pinColor
        headerLine.fillColor = theme.cardBorder
        footerLine.fillColor = theme.cardBorder
        topHi.layer?.backgroundColor = theme.cardInsetHi.cgColor
    }

    func setSelected(_ on: Bool, focused: Bool = true) {
        selected = on
        selFocused = focused
        setAccessibilitySelected(on)
        applyState(animated: true)
    }

    /// 按住 ⌘ 时显示直达编号（1-9），nil 隐藏。
    func setIndexBadge(_ n: Int?) {
        guard let n else { indexBadge.isHidden = true; return }
        indexBadge.stringValue = "\(n)"
        indexBadge.textColor = theme.onAccent   // 白字在亮 accent 上最低只有 1.6:1，按主题取配对色
        indexBadge.layer?.backgroundColor = theme.accent.cgColor
        indexBadge.isHidden = false
    }

    /// 计算并应用卡片当前状态（选中 / hover / 普通），animated 时做 0.14s 平滑过渡。
    private func applyState(animated: Bool) {
        let hot = hovering && !selected
        let selBorder = selFocused ? theme.accent : theme.cardDim
        let cardBG = hot ? theme.cardHoverBG : theme.cardBG
        let border = selected ? selBorder : theme.cardBorder
        let borderW: CGFloat = selected ? 2 : 1

        let shColor: CGColor, shOpacity: Float, shRadius: CGFloat, shOffset: CGSize
        if selected && selFocused {                    // 强调色微光浮起（卡片区聚焦）
            shColor = theme.accentGlow.cgColor; shOpacity = 1; shRadius = 15; shOffset = CGSize(width: 0, height: -2)
        } else if selected {                           // 选中但非聚焦：中性浮起
            shColor = theme.cardShadow.cgColor; shOpacity = theme.cardShadowHover; shRadius = 12; shOffset = CGSize(width: 0, height: -3)
        } else if hovering {                           // hover 略强投影
            shColor = theme.cardShadow.cgColor; shOpacity = theme.cardShadowHover; shRadius = 13; shOffset = CGSize(width: 0, height: -5)
        } else {                                       // 浮起投影
            shColor = theme.cardShadow.cgColor; shOpacity = theme.cardShadowNormal; shRadius = 10; shOffset = CGSize(width: 0, height: -4)
        }

        animate("backgroundColor", cardBG.cgColor, animated)
        animate("borderColor", border.cgColor, animated)
        animate("borderWidth", borderW as NSNumber, animated)
        animate("shadowColor", shColor, animated)
        animate("shadowOpacity", shOpacity as NSNumber, animated)
        animate("shadowRadius", shRadius as NSNumber, animated)
        layer?.shadowOffset = shOffset

        // hover 轻微放大（绕中心），并抬到最上层避免被邻卡盖住；系统开了减弱动态则不缩放
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale: CGFloat = (hot && !reduceMotion) ? Motion.hoverScale : 1.0
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
    /// 系统「减弱动态效果」开启时直接落值，不做过渡。
    private func animate(_ key: String, _ value: Any?, _ animated: Bool) {
        guard let layer else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            a.toValue = value
            a.duration = Motion.state
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
        let ins = Metrics.inset
        // 顶部内高光（横跨上沿，避开圆角）
        topHi.frame = NSRect(x: 8, y: h - 1, width: w - 16, height: 1)
        // ⌘ 直达编号：浮在卡外左上角（masksToBounds 关闭才画得出），不遮表头文字
        indexBadge.frame = NSRect(x: -5, y: h - 10, width: 16, height: 15)
        // 表头：meta + 右侧徽标
        badge.frame = NSRect(x: w - ins - 22, y: h - 32, width: 22, height: 22)
        metaLabel.frame = NSRect(x: ins, y: h - 28, width: w - ins - 30 - 8, height: 15)
        headerLine.frame = NSRect(x: ins, y: h - 44, width: w - ins * 2, height: 0.5)
        // 底部：左来源 App，右字符数；置顶角标在最右
        footerLine.frame = NSRect(x: ins, y: 33, width: w - ins * 2, height: 0.5)
        let countW: CGFloat = 70
        countLabel.frame = NSRect(x: w - ins - countW, y: 10, width: countW, height: 14)
        // OCR 微标：字符数左侧；未识别/非图片时隐藏不占位
        let hasOCR = !ocrBadge.isHidden
        ocrBadge.frame = NSRect(x: w - ins - countW - 16, y: 11, width: 12, height: 12)
        let pinned = !pinView.isHidden
        let srcRight = w - ins - countW - (hasOCR ? 22 : 6)
        srcLabel.frame = NSRect(x: pinned ? ins + 16 : ins, y: 10, width: max(0, srcRight - (pinned ? ins + 16 : ins)), height: 14)
        pinView.frame = NSRect(x: ins, y: 11, width: 12, height: 12)

        // 正文区 [33, h-44]
        let bodyTop = h - 44, bodyBottom: CGFloat = 33
        let areaH = bodyTop - bodyBottom
        let bw = w - ins * 2
        if isImage {
            bodyImage.frame = NSRect(x: ins, y: bodyBottom + 4, width: bw, height: areaH - 8)
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
        bodyText.frame = NSRect(x: ins, y: y, width: bw, height: textH)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
        if event.clickCount >= 2 { onActivate?() } else { onSelect?() }
    }

    // MARK: - 拖出（drag-out）

    /// 按下后拖动超过阈值 → 开始拖拽会话：文本拖字符串、文件拖真实 URL、
    /// 图片写友好命名的临时 PNG 再拖（直接拖 images/<uuid>.png 落到 Finder 名字太丑）。
    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = mouseDownEvent else { return }
        let dist = hypot(event.locationInWindow.x - down.locationInWindow.x,
                         event.locationInWindow.y - down.locationInWindow.y)
        guard dist > 5 else { return }
        dragStarted = true
        let writers = dragWriters()
        guard !writers.isEmpty else { return }
        let snapshot = cardSnapshot()
        let dragItems = writers.map { w -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: w)
            di.setDraggingFrame(bounds, contents: snapshot)
            return di
        }
        beginDraggingSession(with: dragItems, event: down, source: self)
    }

    private func dragWriters() -> [NSPasteboardWriting] {
        guard let item else { return [] }
        switch item.kind {
        case .text:
            let t = item.text ?? ""
            return t.isEmpty ? [] : [t as NSString]
        case .file:
            // 原始路径还在就拖真实文件（多文件全带上）；失效则退回路径文本
            let urls = (item.text ?? "").split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { return urls.map { $0 as NSURL } }
            let t = item.text ?? ""
            return t.isEmpty ? [] : [t as NSString]
        case .image:
            guard let data = item.imageBytes else { return [] }
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Pasta 图片 \(df.string(from: item.date)).png")
            guard (try? data.write(to: tmp, options: .atomic)) != nil else { return [] }
            return [tmp as NSURL]
        }
    }

    /// 卡片自身的视觉快照作拖拽图像。
    private func cardSnapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?()                       // 右键先选中，菜单动作作用于本卡
        return menuProvider?()
    }

    /// 让卡片内任意位置（含文字/图片子视图）的点击都落到卡片本身。
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point) != nil ? self : nil
    }
}

extension ClipCardView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 只允许拖出到其他 App（复制语义）；面板内部不做拖放排序
        context == .outsideApplication ? .copy : []
    }
}

/// 主题化胶囊标签（剪贴板 / 常用）。原生 NSSegmentedControl 的 Aqua 高光胶囊
/// 浮在深色磨砂 + 品牌蓝焦点环的自绘 chrome 上是全面板唯一材质出戏的控件，
/// 换成与焦点环同语言的 accent 半透胶囊（选中：accent 16% 底 + 45% 描边 + accent 字）。
final class PillTabControl: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private let titles: [String]
    private var buttons: [NSButton] = []
    private var theme = Theme.current
    private let padH: CGFloat = 14
    private let btnH: CGFloat = 26
    private let btnGap: CGFloat = 4

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        var x: CGFloat = 0
        for (i, t) in titles.enumerated() {
            let b = NSButton(title: t, target: self, action: #selector(clicked(_:)))
            b.isBordered = false
            b.tag = i
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            let w = ceil((t as NSString).size(withAttributes:
                [.font: NSFont.systemFont(ofSize: Typo.control, weight: .semibold)]).width) + padH * 2
            b.frame = NSRect(x: x, y: 0, width: w, height: btnH)
            x += w + btnGap
            addSubview(b)
            buttons.append(b)
        }
        setFrameSize(NSSize(width: max(0, x - btnGap), height: btnH))
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func clicked(_ sender: NSButton) {
        select(sender.tag)
        onChange?(sender.tag)
    }

    func select(_ i: Int) {
        guard buttons.indices.contains(i) else { return }
        selectedIndex = i
        restyle()
    }

    func applyTheme(_ t: Theme) {
        theme = t
        restyle()
    }

    private func restyle() {
        for (i, b) in buttons.enumerated() {
            let on = i == selectedIndex
            b.layer?.backgroundColor = on ? theme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            b.layer?.borderWidth = on ? 1 : 0
            b.layer?.borderColor = theme.accent.withAlphaComponent(0.45).cgColor
            // 选中/未选中都用 semibold 测宽（init 时按 semibold 算），避免切换时文字抖动
            b.attributedTitle = NSAttributedString(string: titles[i], attributes: [
                .font: NSFont.systemFont(ofSize: Typo.control, weight: on ? .semibold : .regular),
                .foregroundColor: on ? theme.accentTextColor : theme.secondaryText,
            ])
            b.setAccessibilityLabel(on ? "\(titles[i])，已选中" : titles[i])
        }
    }
}

/// 横向卡片条专用滚动视图：把纵向滚轮映射为横向滚动（纯纵向滚轮的鼠标才滚得动）。
final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // 触控板/妙控鼠标的精确滚动自带横向分量，原样放行系统手势（含回弹）
        if event.hasPreciseScrollingDeltas || abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        let x = contentView.bounds.origin.x - event.scrollingDeltaY * 3
        let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(max(0, x), maxX), y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// Paste 风格的底部卡片栏：贴屏幕底部、全宽、横向卡片。
final class HistoryPanelController: NSObject, NSTextFieldDelegate {
    private let store: ClipboardStore
    /// 选中某条 -> 由 AppDelegate 执行真正的写剪贴板 + 粘贴。第二个参数为是否纯文本粘贴。
    var onPaste: ((ClipItem, Bool) -> Void)?
    /// 缺辅助功能权限时的退路：只写剪贴板，不模拟粘贴（面板保持打开并就地提示）。
    var onCopyOnly: ((ClipItem, Bool) -> Void)?

    private var panel: KeyablePanel!
    private var blur: NSVisualEffectView!
    private var tint: NSView!
    private var shelfGradient: CAGradientLayer!     // 玻璃拟态：横向渐变底（非渐变主题时隐藏）
    private var brandGlow: NSView!
    private var glowLayer: CAGradientLayer!
    private var topHighlight: NSView!
    private var searchField: NSTextField!
    private var magnifier: NSImageView!
    private var clearButton: NSButton!
    private var countLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var flagsMonitor: Any?

    /// hint 文案随「全局纯文本粘贴」开关变化，保证状态可见。
    /// 常显版收敛为一短句（常显整行快捷键是持续性轻噪），完整教学面在按住 ⌘ 的展开版。
    private var hintShort: String {
        (Settings.shared.plainTextPaste ? "↩ 纯文本粘贴" : "↩ 粘贴") + " · 按住 ⌘ 全部快捷键"
    }
    private var hintFull: String {
        (Settings.shared.plainTextPaste ? "↩ 纯文本粘贴 · ⌥↩ 同" : "↩ 粘贴 · ⌥↩ 纯文本")
            + " · 空格 预览 · ⌘C 复制 · ⌘1-9 直达 · ⌘P 常用 · ⌘⌫ 删除 · ⌘Z 撤销 · ↑↓ 区域 · ⌘←→ 标签 · esc 关闭"
    }
    /// ⌘+数字 → 直达粘贴第 N 条（ANSI 键位码）
    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    private var tabControl: PillTabControl!
    private var tabContainer: NSView!
    private var hintPill: NSView!
    private var showPinnedOnly = false
    private var divider: NSBox!
    private var cardScroll: NSScrollView!
    private var cardStrip: NSView!
    private var emptyLabel: NSTextField!
    private var keyMonitor: Any?

    private enum Focus { case search, tabs, cards }
    private var focusZone: Focus = .cards
    private var searchContainer: NSView!
    private var theme: Theme = .midnight

    private var filtered: [ClipItem] = []
    private var cardViews: [ClipCardView] = []
    private var selectedIndex = 0
    /// 下一次重建卡片时优先选中的条目（撤销删除后定位用）。
    private var pendingSelectID: UUID?

    private var toastView: NSView?
    private var toastTimer: Timer?
    private var toastAction: (() -> Void)?
    private let preview = PreviewPanel()

    /// 最近一次唤起时间：失活收面板的宽限期判定用。
    private var shownAt = Date.distantPast
    /// 唤起后卡片建好前按下的 ⏎：暂存 plain 标记，卡片建好立即补执行（快手不落空）。
    private var pendingQuickPaste: Bool?
    /// 面板不可见时产生的提示（大图被丢弃、权限已授予等），下次唤起时补显示。
    private var pendingNotice: (text: String, actionTitle: String?, action: (() -> Void)?, duration: TimeInterval)?
    /// 数据库不可用只提醒一次（每次会话）。
    private var didWarnDBUnavailable = false
    /// 辅助功能授权轮询：打开设置后监测授权变化，主动补「已授权/需重启」提示。
    private var axWatchTimer: Timer?
    private let shelfHeight: CGFloat = 332
    private let toolbarH = Metrics.toolbarH
    private let gap = Metrics.gap
    private let pad = Metrics.pad

    init(store: ClipboardStore) {
        self.store = store
        super.init()
        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refilterIfVisible() }
        }
        // 超大图片被丢弃：面板可见就地 toast；不可见记下，下次唤起补提示
        store.onImageTooLarge = { [weak self] bytes in
            guard let self else { return }
            let mb = Double(bytes) / 1024 / 1024
            self.notice("图片 \(String(format: "%.0f", mb)) MB 超过 \(store.maxImageMB) MB 上限，未记入历史", duration: 5)
        }
        buildPanel()
        // App 失活 → 收面板（hidesOnDeactivate 的手动版，走 hide() 正规清理路径）。
        // 300ms 宽限期：唤起瞬间的激活竞态（协作激活先拒后成 / 前台 App 短暂抢回焦点）
        // 不应把刚显示的面板收掉。
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            if Date().timeIntervalSince(self.shownAt) < 0.3 {
                // 宽限期内不立即收，稍后复查：竞态失活会在片刻后重新激活（保面板）；
                // 若确实是用户点走了（始终未激活），补一次正常隐藏。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.panel.isVisible, !NSApp.isActive else { return }
                    self.hide()
                }
                return
            }
            self.hide()
        }
        NotificationCenter.default.addObserver(forName: Settings.themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
            self?.refilterIfVisible()     // 重建卡片以套用新主题色
        }
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
        // 失活收面板由 didResignActive 手动处理（见 init）：hidesOnDeactivate 会在
        // macOS 14+ 协作激活「先拒后成」的竞态里把刚唤出的面板立刻收掉（偶发拉起失败），
        // 且它绕过 hide()，键盘监视器/toast 清理不走正规路径。
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        // 磨砂上叠的色（主题驱动）
        tint = NSView()
        tint.wantsLayer = true
        tint.frame = blur.bounds
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)

        // 玻璃拟态横向渐变底（默认隐藏，仅渐变主题启用）
        shelfGradient = CAGradientLayer()
        shelfGradient.startPoint = CGPoint(x: 0, y: 0.5)
        shelfGradient.endPoint = CGPoint(x: 1, y: 0.5)
        shelfGradient.frame = CGRect(x: 0, y: 0, width: blur.bounds.width, height: shelfHeight)
        shelfGradient.isHidden = true
        tint.layer?.addSublayer(shelfGradient)

        // 顶部品牌色微光（主题驱动）
        brandGlow = NSView()
        brandGlow.wantsLayer = true
        brandGlow.frame = NSRect(x: 0, y: shelfHeight - 96, width: blur.bounds.width, height: 96)
        brandGlow.autoresizingMask = [.width, .minYMargin]
        glowLayer = CAGradientLayer()
        glowLayer.startPoint = CGPoint(x: 0.5, y: 1.0)   // 顶部 → 向下渐隐
        glowLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        glowLayer.frame = CGRect(x: 0, y: 0, width: 6000, height: 96)   // 超宽，覆盖任意屏宽
        brandGlow.layer?.addSublayer(glowLayer)
        blur.addSubview(brandGlow)

        // 上沿微光（主题驱动）
        topHighlight = NSView()
        topHighlight.wantsLayer = true
        topHighlight.frame = NSRect(x: 0, y: shelfHeight - 1, width: blur.bounds.width, height: 1)
        topHighlight.autoresizingMask = [.width, .minYMargin]
        blur.addSubview(topHighlight)

        // 工具条：搜索框（含焦点蓝环容器）
        searchContainer = NSView()
        searchContainer.wantsLayer = true
        searchContainer.layer?.masksToBounds = false
        searchContainer.layer?.cornerRadius = Metrics.radius
        searchContainer.layer?.borderWidth = 2
        searchContainer.layer?.borderColor = NSColor.clear.cgColor
        blur.addSubview(searchContainer)

        magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        magnifier.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        searchContainer.addSubview(magnifier)

        searchField = NSTextField()
        searchField.font = .systemFont(ofSize: Typo.title)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .white
        searchField.placeholderString = "搜索剪贴历史…"
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchField.setAccessibilityLabel("搜索剪贴历史")
        searchContainer.addSubview(searchField)

        // 清除按钮：有查询时出现
        clearButton = NSButton()
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除搜索")
        clearButton.isBordered = false
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.isHidden = true
        searchContainer.addSubview(clearButton)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: Typo.body)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        countLabel.alignment = .right
        blur.addSubview(countLabel)

        // hint 胶囊：短提示常驻（描边胶囊收敛存在感），按住 ⌘ 展开完整快捷键
        hintLabel = NSTextField(labelWithString: hintShort)
        hintLabel.font = .systemFont(ofSize: Typo.caption)
        hintLabel.lineBreakMode = .byTruncatingHead
        hintPill = NSView()
        hintPill.wantsLayer = true
        hintPill.layer?.cornerRadius = 6
        hintPill.layer?.borderWidth = 1
        hintPill.addSubview(hintLabel)
        blur.addSubview(hintPill)

        // 剪贴板 / 常用 标签页：主题化胶囊（与焦点环同语言）+ 外层容器（焦点蓝环）
        tabControl = PillTabControl(titles: ["剪贴板", "常用"])
        tabControl.onChange = { [weak self] i in
            guard let self else { return }
            self.showPinnedOnly = i == 1
            self.focusZone = .tabs
            self.refilter()
            self.updateFocusVisuals()
        }
        let cs = tabControl.frame.size
        tabControl.setFrameOrigin(NSPoint(x: 6, y: 6))
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
        cardScroll = HorizontalScrollView()
        cardScroll.drawsBackground = false
        cardScroll.hasVerticalScroller = false
        cardScroll.hasHorizontalScroller = false
        cardScroll.autohidesScrollers = true
        cardScroll.verticalScrollElasticity = .none
        cardStrip = NSView()
        cardStrip.setAccessibilityElement(true)
        cardStrip.setAccessibilityRole(.list)
        cardStrip.setAccessibilityLabel("剪贴历史")
        cardScroll.documentView = cardStrip
        blur.addSubview(cardScroll)

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: Typo.emphasis)
        emptyLabel.isHidden = true
        blur.addSubview(emptyLabel)

        applyTheme()
    }

    /// 弹性搜索框宽度：随面板宽在 236–340pt 之间伸展。
    private func searchWidth(width W: CGFloat) -> CGFloat {
        min(340, max(236, W * 0.16))
    }

    private func layoutShelf(width W: CGFloat) {
        let H = shelfHeight
        let yc = H - toolbarH / 2
        let searchW = searchWidth(width: W)
        searchContainer.frame = NSRect(x: 12, y: yc - 16, width: searchW, height: 32)
        magnifier.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
        searchField.frame = NSRect(x: 32, y: 4, width: searchW - 42 - 20, height: 24)
        clearButton.frame = NSRect(x: searchW - 26, y: 7, width: 18, height: 18)
        tabContainer.setFrameOrigin(NSPoint(x: 12 + searchW + 12, y: yc - tabContainer.frame.height / 2))
        countLabel.frame = NSRect(x: W - 148, y: yc - 9, width: 134, height: 18)   // 容「前 300 · 共 5000 条」
        layoutHintPill()
        divider.frame = NSRect(x: 0, y: H - toolbarH, width: W, height: 0.5)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shelfGradient.frame = CGRect(x: 0, y: 0, width: W, height: H)
        CATransaction.commit()
        cardScroll.frame = NSRect(x: 0, y: 0, width: W, height: H - toolbarH)
        emptyLabel.frame = NSRect(x: 0, y: 0, width: W, height: H - toolbarH)
    }

    /// hint 胶囊：右对齐在条数左缘，宽度随当前文本收缩（按住 ⌘ 展开时变宽）。
    private func layoutHintPill() {
        let W = panel.frame.width
        let yc = shelfHeight - toolbarH / 2
        let leftEdge = 12 + searchWidth(width: W) + 12 + tabContainer.frame.width + 16
        let rightEdge = W - 148 - 10   // 条数左缘再留 10pt
        let textW = ceil((hintLabel.stringValue as NSString).size(withAttributes:
            [.font: NSFont.systemFont(ofSize: Typo.caption)]).width)
        let pillW = min(textW + 20, max(0, rightEdge - leftEdge))
        hintPill.frame = NSRect(x: rightEdge - pillW, y: yc - 11, width: pillW, height: 22)
        hintLabel.frame = NSRect(x: 10, y: 3, width: max(0, pillW - 20), height: 16)
    }

    private func updateTabs() {
        tabControl.select(showPinnedOnly ? 1 : 0)
    }

    /// 焦点区视觉：聚焦的区域加强调色环 + 辉光；卡片区聚焦 → 选中卡强调框。
    private func updateFocusVisuals() {
        focusRing(searchContainer, focusZone == .search)
        focusRing(tabContainer, focusZone == .tabs)
        magnifier.contentTintColor = focusZone == .search ? theme.accent : theme.secondaryText
        if cardViews.indices.contains(selectedIndex) {
            cardViews[selectedIndex].setSelected(true, focused: focusZone == .cards)
        }
    }

    private func focusRing(_ view: NSView, _ on: Bool) {
        view.layer?.borderColor = (on ? theme.accent : NSColor.clear).cgColor
        view.layer?.shadowColor = theme.accentGlow.cgColor
        view.layer?.shadowOpacity = on ? 1 : 0
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = .zero
    }

    /// 应用当前主题：设置面板 chrome 的所有色值 + 同步给卡片。
    func applyTheme() {
        theme = Settings.shared.theme
        Theme.current = theme
        panel.appearance = NSAppearance(named: theme.appearance)
        blur.material = theme.blurMaterial
        tint.layer?.backgroundColor = theme.shelfTint.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let g = theme.gradient {
            shelfGradient.isHidden = false
            shelfGradient.colors = g.map { $0.cgColor }
            shelfGradient.locations = theme.gradientLocations
            tint.layer?.backgroundColor = NSColor.clear.cgColor   // 渐变层接管底色
        } else {
            shelfGradient.isHidden = true
        }
        CATransaction.commit()
        topHighlight.layer?.backgroundColor = theme.topEdge.cgColor
        glowLayer.colors = [theme.glow.cgColor, NSColor.clear.cgColor]
        divider.fillColor = theme.cardBorder
        magnifier.contentTintColor = theme.secondaryText
        clearButton.contentTintColor = theme.secondaryText
        searchField.textColor = theme.primaryText
        searchField.placeholderString = "搜索剪贴历史…"
        countLabel.textColor = theme.secondaryText
        hintLabel.textColor = theme.secondaryText   // 不再降 0.8：保住 ≥4.5:1 对比度
        hintPill.layer?.borderColor = theme.cardBorder.cgColor
        tabControl.applyTheme(theme)
        emptyLabel.textColor = theme.secondaryText
    }

    private func setZone(_ z: Focus) {
        guard focusZone != z else { return }
        focusZone = z
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
        // 「跟随系统」主题：系统外观通知可能与 effectiveAppearance 更新存在竞态，
        // 唤起时重解析一次兜底（非 auto 时零开销）。
        if Settings.shared.themeID == Theme.autoID { applyTheme() }

        // 跟随鼠标所在屏幕（多显示器），回退主屏
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.frame
        let finalFrame = NSRect(x: f.minX, y: f.minY, width: f.width, height: shelfHeight)
        panel.setFrame(finalFrame, display: true)
        layoutShelf(width: f.width)

        searchField.stringValue = ""
        clearButton.isHidden = true
        hintLabel.stringValue = hintShort
        layoutHintPill()
        showPinnedOnly = false
        focusZone = .cards
        updateTabs()

        // 先清掉上一次的卡片内容：既避免推迟构建期间残留旧数据，
        // 也防止用户在卡片建好前回车误粘上一次的选中项。
        filtered = []
        selectedIndex = 0
        cardViews.forEach { $0.isHidden = true }
        countLabel.stringValue = ""
        emptyLabel.isHidden = true

        // 出场动效：自底部 12pt 浮入 + 渐显（~140ms）；系统减弱动态时直落。
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            panel.alphaValue = 0
            panel.setFrame(finalFrame.offsetBy(dx: 0, dy: -12), display: false)
        }

        // 先把面板显示出来，让用户立刻看到它。
        shownAt = Date()
        pendingQuickPaste = nil
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(searchField)
        installKeyMonitor()

        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.panelIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(finalFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }

        // 卡片构建推迟到下一拍执行：面板已经出现，长历史也不会卡顿。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refilter()
            self.updateFocusVisuals()
            // 比卡片构建还快的 ⏎：现在卡片就绪，补执行那次粘贴
            if let plain = self.pendingQuickPaste {
                self.pendingQuickPaste = nil
                self.pasteSelected(plain: plain)
                return
            }
            self.showDeferredNotices()
        }
    }

    /// 唤起后补显示积压的提示：面板不可见期间的事件（大图丢弃/授权变化）+ 数据库告警。
    private func showDeferredNotices() {
        if let n = pendingNotice {
            pendingNotice = nil
            showToast(n.text, actionTitle: n.actionTitle, action: n.action, duration: n.duration)
        } else if store.dbUnavailable && !didWarnDBUnavailable {
            didWarnDBUnavailable = true
            showToast("历史数据库不可用，本次记录只保存在内存，退出后会丢失", duration: 8)
        }
    }

    /// 就地提示：面板可见立即 toast；不可见暂存，下次唤起补显示。
    private func notice(_ text: String, actionTitle: String? = nil,
                        action: (() -> Void)? = nil, duration: TimeInterval = 4) {
        if panel.isVisible {
            showToast(text, actionTitle: actionTitle, action: action, duration: duration)
        } else {
            pendingNotice = (text, actionTitle, action, duration)
        }
    }

    func hide() {
        // 刻意无退场动画（与 140ms 入场不对称）：粘贴完成的瞬间用户要的是「立刻让开」，
        // 任何退场编排都是在挡视线。
        preview.hide()
        hideToast()
        removeKeyMonitor()
        pendingQuickPaste = nil
        panel.orderOut(nil)
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        // 先移除旧监视器再装新的：show() 可能在面板已可见时重入（菜单"显示历史"重复唤起），
        // 否则旧引用丢失永久泄漏且按键被重复处理。
        removeKeyMonitor()
        // 按住 ⌘ → hint 栏展开全部快捷键
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let cmdDown = event.modifierFlags.contains(.command)
            self.hintLabel.stringValue = cmdDown ? self.hintFull : self.hintShort
            self.layoutHintPill()             // 胶囊宽度跟随文本伸缩
            self.updateIndexBadges(cmdDown)   // 前 9 张卡叠直达编号，⌘1-9 有了可视映射
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 面板不可见时放行一切（防御性兜底：任何绕过 hide() 的隐藏路径下，
            // 残留的监视器若继续吞键，会把偏好窗口里的回车变成一次对前台的意外粘贴）。
            guard self.panel.isVisible else { return event }
            // 输入法组词中（拼音等尚未上屏）：整套按键放行给输入法，
            // 否则回车"上屏"会被劫持成粘贴并关面板，组词内容全丢。
            if let tv = self.searchField.currentEditor() as? NSTextView, tv.hasMarkedText() {
                return event
            }
            let cmd = event.modifierFlags.contains(.command)
            // ⌘1-9：直达粘贴第 N 条
            if cmd, let n = Self.digitKeys[event.keyCode] {
                self.pasteAt(n - 1)
                return nil
            }
            switch event.keyCode {
            case 123 where cmd: self.selectTab(pinned: false); return nil  // ⌘← 剪贴板（全局）
            case 124 where cmd: self.selectTab(pinned: true); return nil   // ⌘→ 置顶（全局）
            case 124:                                          // → 搜索→标签→(剪贴板→置顶)
                switch self.focusZone {
                case .cards: self.moveSelection(1)
                case .search:
                    // 光标不在文本末尾：交还给输入框移动光标，不切区。
                    if let ed = self.searchField.currentEditor(),
                       ed.selectedRange.location + ed.selectedRange.length < (ed.string as NSString).length {
                        return event
                    }
                    self.setZone(.tabs)
                case .tabs: if !self.showPinnedOnly { self.selectTab(pinned: true) }
                }
                return nil
            case 123:                                          // ← (置顶→剪贴板→搜索)
                switch self.focusZone {
                case .cards: self.moveSelection(-1)
                case .tabs: self.showPinnedOnly ? self.selectTab(pinned: false) : self.setZone(.search)
                case .search: return event                     // 交还给输入框移动光标
                }
                return nil
            case 126:                                           // ↑ 预览开着滚预览；否则上到顶部
                if self.preview.isVisible { self.preview.scrollText(by: -44) }
                else if self.focusZone == .cards { self.setZone(.tabs) }
                return nil
            case 125:                                           // ↓ 预览开着滚预览；否则回卡片
                if self.preview.isVisible { self.preview.scrollText(by: 44) }
                else if self.focusZone != .cards { self.setZone(.cards) }
                return nil
            case 36, 76:                                        // return / enter → 一律粘贴选中项
                // 标签区不例外：切完 tab 直接回车是最常见的连贯动作，选中卡始终可见，
                // 「回车只切区不粘贴」会被当成粘贴失灵（进入卡片区交给 ↓）。
                if self.focusZone == .tabs { self.setZone(.cards) }   // 视觉归位（无权限时面板不关，焦点应在卡片区）
                let plain = Settings.shared.plainTextPaste || event.modifierFlags.contains(.option)
                self.pasteSelected(plain: plain)
                return nil
            case 49 where self.searchField.stringValue.isEmpty:  // 空格：Quick Look 式预览（有查询时空格归输入框）
                self.togglePreview()
                return nil
            case 53:                                            // esc：三段式，预览 → 清查询 → 关面板
                if self.preview.isVisible {
                    self.preview.hide()
                } else if !self.searchField.stringValue.isEmpty {
                    self.clearSearch()
                } else {
                    self.hide()
                }
                return nil
            case 35 where cmd: self.togglePinSelected(); return nil   // ⌘P
            case 8 where cmd:                                   // ⌘C：搜索框有选中文字时让位给系统复制
                if let ed = self.searchField.currentEditor(), ed.selectedRange.length > 0 {
                    return event
                }
                self.copySelected(); return nil                 // 否则复制选中卡片（不粘贴不关面板）
            case 51 where cmd: self.deleteSelected(); return nil      // ⌘⌫
            case 6 where cmd: self.undoDelete(); return nil           // ⌘Z 撤销删除
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    @objc private func clearSearch() {
        searchField.stringValue = ""
        clearButton.isHidden = true
        refilter()
    }

    /// 按住 ⌘ 时给前 9 张可见卡叠直达编号。
    private func updateIndexBadges(_ show: Bool) {
        for (i, card) in cardViews.enumerated() where i < filtered.count {
            card.setIndexBadge(show && i < 9 ? i + 1 : nil)
        }
    }

    /// ⌘1-9 直达：选中第 i 条并立即粘贴。
    private func pasteAt(_ i: Int) {
        guard filtered.indices.contains(i) else { return }
        selectIndex(i)
        pasteSelected(plain: Settings.shared.plainTextPaste)
    }

    // MARK: - 右键菜单

    /// 当前选中卡的上下文菜单（菜单动作与快捷键走同一批路径）。
    private func contextMenu() -> NSMenu? {
        guard filtered.indices.contains(selectedIndex) else { return nil }
        let item = filtered[selectedIndex]
        let menu = NSMenu()
        // keyEquivalent 仅作展示教学（动作实际走键盘监视器），右键菜单是最好的快捷键教学面
        let paste = menu.addItem(withTitle: Settings.shared.plainTextPaste ? "粘贴（纯文本模式）" : "粘贴",
                                 action: #selector(menuPaste), keyEquivalent: "\r")
        paste.keyEquivalentModifierMask = []
        let plain = menu.addItem(withTitle: "粘贴为纯文本", action: #selector(menuPastePlain), keyEquivalent: "\r")
        plain.keyEquivalentModifierMask = [.option]
        menu.addItem(.separator())
        let pv = menu.addItem(withTitle: "预览", action: #selector(menuPreview), keyEquivalent: " ")
        pv.keyEquivalentModifierMask = []
        menu.addItem(withTitle: "仅复制（不粘贴）", action: #selector(menuCopyOnly), keyEquivalent: "c")
        menu.addItem(.separator())
        menu.addItem(withTitle: item.pinned ? "移出常用" : "加入常用", action: #selector(menuTogglePin), keyEquivalent: "p")
        menu.addItem(.separator())
        let del = menu.addItem(withTitle: "删除", action: #selector(menuDelete), keyEquivalent: "\u{8}")
        del.keyEquivalentModifierMask = [.command]
        for m in menu.items { m.target = self }
        return menu
    }

    @objc private func menuPaste() { pasteSelected(plain: Settings.shared.plainTextPaste) }
    @objc private func menuPastePlain() { pasteSelected(plain: true) }
    @objc private func menuPreview() { togglePreview() }
    @objc private func menuCopyOnly() { copySelected() }
    @objc private func menuTogglePin() { togglePinSelected() }
    @objc private func menuDelete() { deleteSelected() }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectIndex(max(0, min(renderedCount - 1, selectedIndex + delta)))
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
        if preview.isVisible, filtered.indices.contains(i) {   // 预览开着：跟随选择切换内容
            preview.show(filtered[i], above: panel)
        }
        // VoiceOver 焦点同步：键盘 first responder 始终在搜索框，VO 光标不会自己跟过来，
        // 选中变化必须主动播报，否则 VO 用户听不到「当前选到哪张」。
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: cardStrip as Any, notification: .selectedChildrenChanged)
            if let label = cardViews[i].accessibilityLabel() {
                NSAccessibility.post(element: panel as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: label,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }

    /// 空格预览开关（选中项）。
    private func togglePreview() {
        if preview.isVisible { preview.hide(); return }
        guard filtered.indices.contains(selectedIndex) else { return }
        preview.show(filtered[selectedIndex], above: panel)
    }

    private func pasteSelected(plain: Bool) {
        guard filtered.indices.contains(selectedIndex) else {
            // 唤起后卡片还没建好（快手 ⏎ 比下一拍的 refilter 还快）：暂存，建好立即补执行
            if !store.items.isEmpty, Date().timeIntervalSince(shownAt) < 1.0 {
                pendingQuickPaste = plain
            }
            return
        }
        let item = filtered[selectedIndex]
        guard Paster.hasAccessibilityPermission else {
            // 内容照样进剪贴板，但不收面板：让用户看到失败原因，而不是静默消失。
            onCopyOnly?(item, plain)
            showToast("已复制，但自动粘贴需要「辅助功能」权限",
                      actionTitle: "打开设置",
                      action: { [weak self] in
                          Paster.openAccessibilitySettings()
                          self?.startAXWatch()   // 盯授权变化：授予后主动提示（含可能的重启）
                      },
                      duration: 8)
            return
        }
        guard !Paster.isSecureInputActive else {
            // 密码框/终端安全键盘输入期间，系统会抑制模拟按键：只复制并归因，不静默失败。
            onCopyOnly?(item, plain)
            showToast("已复制；当前处于安全输入状态（密码框/终端安全键盘），请手动 ⌘V", duration: 6)
            return
        }
        hide()
        onPaste?(item, plain)
    }

    /// ⌘C：只写回剪贴板，不模拟粘贴、不关面板——拿到内容自己找地方粘的路径。
    private func copySelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        onCopyOnly?(filtered[selectedIndex], Settings.shared.plainTextPaste)
        showToast("已复制", duration: 2)
    }

    private func togglePinSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        store.togglePin(id: filtered[selectedIndex].id)
    }

    private func deleteSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        store.delete(id: filtered[selectedIndex].id)
        showToast("已删除 · ⌘Z 撤销")
    }

    private func undoDelete() {
        guard let restored = store.undeleteLast() else { return }
        pendingSelectID = restored.id      // store.onChange 的异步 refilter 会选中它
        showToast("已恢复")
    }

    // MARK: - 辅助功能授权链路

    /// 首启教学时刻的「第 0 步」：面板已自动唤起、用户零风险，正是配置权限的最佳时机；
    /// 不做则推迟到首次粘贴失败——那是最高压的时刻。AppDelegate 在首启自动唤起后调用。
    func showPermissionOnboardingIfNeeded() {
        guard panel.isVisible, !Paster.hasAccessibilityPermission else { return }
        showToast("按 ⏎ 直接粘贴需要「辅助功能」权限，建议现在配置好",
                  actionTitle: "打开设置",
                  action: { [weak self] in
                      Paster.openAccessibilitySettings()
                      self?.startAXWatch()
                  },
                  duration: 12)
    }

    /// 打开设置后每秒轮询授权状态（上限 3 分钟）：授予后主动告知，并给「立即重启」出路——
    /// 运行中授予的权限对 CGEvent 的抑制可能要重启才解除，没人提示就是 toast 死循环。
    private func startAXWatch() {
        guard axWatchTimer == nil, !Paster.hasAccessibilityPermission else { return }
        var ticks = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            if Paster.hasAccessibilityPermission {
                self.stopAXWatch()
                self.notice("已获得辅助功能权限；若 ⏎ 粘贴仍无反应，重启一次即可生效",
                            actionTitle: "立即重启",
                            action: { Paster.relaunchApp() },
                            duration: 10)
            } else if ticks >= 180 {
                self.stopAXWatch()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        axWatchTimer = timer
    }

    private func stopAXWatch() {
        axWatchTimer?.invalidate()
        axWatchTimer = nil
    }

    // MARK: - 面板内轻提示（toast）

    /// 轻提示。短的纯文本提示（已复制/已删除…）内联进工具条 hint 位——工具条本就是状态区，
    /// 不遮任何卡片；长文案或带动作按钮的（权限引导等）仍用卡片区上方的浮层。
    private func showToast(_ text: String, actionTitle: String? = nil,
                           action: (() -> Void)? = nil, duration: TimeInterval = 4) {
        hideToast()
        let inline = actionTitle == nil && text.count <= 18
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.cardBG.withAlphaComponent(0.97).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = theme.accentGlow.cgColor

        let h: CGFloat = inline ? 24 : 32
        let padX: CGFloat = inline ? 10 : 14
        container.layer?.cornerRadius = inline ? 6 : Metrics.radiusL
        if !inline {
            container.layer?.shadowColor = theme.cardShadow.cgColor
            container.layer?.shadowOpacity = 0.3
            container.layer?.shadowRadius = 10
            container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: inline ? Typo.caption : Typo.body)
        label.textColor = theme.cardFG
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: padX, y: (h - label.frame.height) / 2))
        container.addSubview(label)
        var w = padX + label.frame.width + padX

        if let actionTitle {
            toastAction = action
            let btn = NSButton(title: actionTitle, target: self, action: #selector(toastActionFired))
            btn.isBordered = false
            btn.font = .systemFont(ofSize: Typo.body, weight: .semibold)
            btn.contentTintColor = theme.accent
            btn.sizeToFit()
            btn.setFrameOrigin(NSPoint(x: w - 4, y: (h - btn.frame.height) / 2))
            container.addSubview(btn)
            w += btn.frame.width + 10
        }

        if inline {
            // 内联：顶掉 hint 胶囊的位置，右对齐在条数左缘
            hintPill.isHidden = true
            let yc = shelfHeight - toolbarH / 2
            let rightEdge = panel.frame.width - 148 - 10
            container.frame = NSRect(x: rightEdge - w, y: yc - h / 2, width: w, height: h)
        } else {
            container.frame = NSRect(x: (panel.frame.width - w) / 2, y: shelfHeight - toolbarH - h - 12,
                                     width: w, height: h)
        }
        blur.addSubview(container)
        toastView = container

        // VoiceOver 同步播报
        NSAccessibility.post(element: panel as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            container.alphaValue = 1
        } else {
            container.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.toastIn
                container.animator().alphaValue = 1
            }
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hideToast()
        }
    }

    @objc private func toastActionFired() {
        toastAction?()
        hideToast()
    }

    private func hideToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        toastAction = nil
        toastView?.removeFromSuperview()
        toastView = nil
        if hintPill != nil { hintPill.isHidden = false }   // 内联 toast 归还 hint 位
    }

    // MARK: - 过滤 / 数据

    func controlTextDidChange(_ obj: Notification) {
        clearButton.isHidden = searchField.stringValue.isEmpty
        refilter()
    }

    private func refilterIfVisible() {
        if isVisible { refilter(preserveSelection: true) }   // store 变更（置顶/删除/新复制）不丢当前位置
    }

    /// preserveSelection：store 驱动的重建保持选中位置；搜索输入/切标签则回到第一条。
    private func refilter(preserveSelection: Bool = false) {
        let keepID: UUID? = pendingSelectID
            ?? (preserveSelection && filtered.indices.contains(selectedIndex) ? filtered[selectedIndex].id : nil)
        let keepIndex = preserveSelection ? selectedIndex : 0
        pendingSelectID = nil

        let q = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        currentQuery = q
        // 常用页按收藏时间倒序：位置只随收藏/移出变化（⌘1-9 成为事实上的稳定槽位），
        // 重新复制某条常用不会把它顶到最前扰乱肌肉记忆；旧数据无收藏时间用剪贴时间兜底。
        let base = showPinnedOnly
            ? store.items.filter { $0.pinned }.sorted { ($0.pinnedAt ?? $0.date) > ($1.pinnedAt ?? $1.date) }
            : store.displayItems
        filtered = q.isEmpty ? base : base.filter { $0.matches(q) }   // 子串 + 拼音全拼/首字母

        countLabel.stringValue = filtered.isEmpty ? ""
            : (filtered.count > Self.renderLimit
               ? "前 \(Self.renderLimit) · 共 \(filtered.count) 条"
               : "\(filtered.count) 条")
        emptyLabel.isHidden = !filtered.isEmpty
        if !q.isEmpty {
            // 有截图还在 OCR 队列里时给归因：让用户能区分「没有」和「还没识别完」
            let pending = store.pendingOCR.count
            emptyLabel.stringValue = pending > 0
                ? "无匹配结果 · 还有 \(pending) 张截图文字识别中 · esc 清空搜索"
                : "无匹配结果 · esc 清空搜索"
        } else {
            emptyLabel.stringValue = showPinnedOnly
                ? "暂无常用 · 选中卡片按 ⌘P 收藏"
                : "复制任意内容试试 · 按 \(Settings.shared.hotKeyDisplay) 随时唤起"
        }

        rebuildCards(keepID: keepID, keepIndex: keepIndex)
        if preview.isVisible {   // 搜索/切标签后：预览跟随新选中项，无结果则收起
            if filtered.indices.contains(selectedIndex) { preview.show(filtered[selectedIndex], above: panel) }
            else { preview.hide() }
        }
    }

    /// 重建代际：分帧补建前校验，防止上一轮的补建批次作用到更晚一次重建上。
    private var rebuildGeneration = 0
    /// 当前搜索词（已小写去空白），卡片命中高亮用。
    private var currentQuery = ""
    /// 面板渲染上限：容量 5000 时全量建卡（每卡约 10 个子视图）会卡在秒级，
    /// 只渲染前 N 张——没人用方向键翻到第 300 张，长尾靠搜索触达（搜索是全量内存过滤）。
    private static let renderLimit = 300
    /// 本轮实际渲染的卡数（选择移动的右边界）。
    private var renderedCount = 0

    private func rebuildCards(keepID: UUID? = nil, keepIndex: Int = 0) {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let scrollH = cardScroll.frame.height
        let cardY = (scrollH - ClipCardView.cardH) / 2
        // 卡片宽度自适应屏宽：一屏正好显示约 8 个
        let target: CGFloat = 8
        let scrollW = cardScroll.frame.width
        let cardW = min(260, max(170, (scrollW - pad * 2 - gap * (target - 1)) / target))

        // 渲染上限：只建前 renderLimit 张（长尾靠搜索触达），条数标签会标注「前 N · 共 M」
        let renderCount = min(filtered.count, Self.renderLimit)
        renderedCount = renderCount

        // 池外的旧卡先藏；硬上限只裁空闲卡（搜索清空后免于全量重建）。
        // 懒建池可能比 renderCount 小（首唤起为空）——dropFirst 越界安全，不能用 ..< 区间。
        for card in cardViews.dropFirst(renderCount) {
            card.isHidden = true
        }
        while cardViews.count > max(240, renderCount) {
            cardViews.removeLast().removeFromSuperview()
        }

        // 懒建 + 分片：本帧只创建/configure 可视区（约一屏 + 余量），其余按 32 张/拍分片补建。
        // 一次性建 300 个视图（每卡约 10 个子视图）或在同一拍 configure 288 张
        // （文本测量 + 冷缓存缩略图）都会与 140ms 入场动画抢帧——首唤起偶发卡顿的主因。
        let visibleCount = min(renderCount, Int(ceil(scrollW / (cardW + gap))) + 4)
        for i in 0..<visibleCount {
            buildCard(i, cardW: cardW, cardY: cardY, configure: true)
        }
        let contentW = pad * 2 + CGFloat(renderCount) * cardW
            + CGFloat(max(0, renderCount - 1)) * gap
        cardStrip.frame = NSRect(x: 0, y: 0, width: max(contentW, cardScroll.frame.width), height: scrollH)

        if renderCount > 0 {
            // 优先按 id 恢复选中（置顶/撤销后不丢位置）；条目已不在或超出渲染区则退到相邻位置。
            let idx: Int
            if let keepID, let found = filtered.prefix(renderCount).firstIndex(where: { $0.id == keepID }) {
                idx = found
            } else {
                idx = max(0, min(keepIndex, renderCount - 1))
            }
            selectedIndex = idx
            if idx >= visibleCount { buildCard(idx, cardW: cardW, cardY: cardY, configure: true) }   // 视区外恢复选中：先建好再高亮
            cardViews[idx].setSelected(true, focused: focusZone == .cards)
            if idx == 0 {
                cardScroll.contentView.scroll(to: .zero)
            } else {
                cardScroll.contentView.scrollToVisible(cardViews[idx].frame.insetBy(dx: -(gap + pad), dy: 0))
            }
        }

        scheduleChunkedBuild(from: visibleCount, to: renderCount,
                             cardW: cardW, cardY: cardY, generation: generation)
    }

    /// 补足视图池到第 i 张并布置（frame + 回调），configure 为真时同时填内容。
    private func buildCard(_ i: Int, cardW: CGFloat, cardY: CGFloat, configure: Bool) {
        while cardViews.count <= i {
            let card = ClipCardView()
            cardStrip.addSubview(card)
            cardViews.append(card)
        }
        let card = cardViews[i]
        card.isHidden = false
        card.frame = NSRect(x: pad + CGFloat(i) * (cardW + gap),
                            y: cardY, width: cardW, height: ClipCardView.cardH)
        if configure { card.configure(filtered[i], highlight: currentQuery) }
        let idx = i
        card.onSelect = { [weak self] in self?.selectIndex(idx) }
        card.onActivate = { [weak self] in
            self?.selectIndex(idx)
            self?.pasteSelected(plain: Settings.shared.plainTextPaste)
        }
        card.menuProvider = { [weak self] in self?.contextMenu() }
    }

    /// 视区外的卡片分片补建：每拍 32 张，代际校验防串批；选中卡跳过（configure 会重置选中态）。
    private func scheduleChunkedBuild(from start: Int, to end: Int,
                                      cardW: CGFloat, cardY: CGFloat, generation: Int) {
        guard start < end else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.rebuildGeneration else { return }
            let chunkEnd = min(start + 32, end, self.filtered.count)
            for i in start..<chunkEnd where i != self.selectedIndex {
                self.buildCard(i, cardW: cardW, cardY: cardY, configure: true)
            }
            self.scheduleChunkedBuild(from: chunkEnd, to: end,
                                      cardW: cardW, cardY: cardY, generation: generation)
        }
    }
}
