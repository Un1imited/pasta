import AppKit

/// 空格键预览浮层（Quick Look 式）：悬在卡片栏上方居中，随选中项切换内容。
/// 文本 → 可滚动全文；图片 → 等比大图；文件 → 路径清单。
/// 作为主面板的子窗口存在：主面板隐藏/移动时自动跟随。
final class PreviewPanel {
    private var panel: NSPanel?
    private var textScroll: NSScrollView!
    private var textView: NSTextView!
    private var imageView: NSImageView!

    var isVisible: Bool { panel?.isVisible ?? false }

    private static let maxSize = NSSize(width: 640, height: 400)
    private static let minSize = NSSize(width: 280, height: 120)

    /// 显示（或刷新）预览，锚定在 shelf 窗口上方居中。
    func show(_ item: ClipItem, above shelf: NSWindow) {
        let theme = Theme.current
        if panel == nil { build() }
        guard let panel else { return }
        apply(theme: theme)

        var contentSize: NSSize
        switch item.kind {
        case .image:
            imageView.isHidden = false
            textScroll.isHidden = true
            let img = item.imageBytes.flatMap { NSImage(data: $0) }
            imageView.image = img
            // VoiceOver：图片说不了话，但 OCR 文本可以——识别结果直接作为朗读内容
            if let ocr = item.ocrText, !ocr.isEmpty {
                imageView.setAccessibilityLabel("图片预览，识别文字：\(String(ocr.prefix(200)))")
            } else {
                imageView.setAccessibilityLabel("图片预览，\(item.footerInfo)")
            }
            // 等比缩进最大框
            let px = item.imageSize ?? NSSize(width: 400, height: 300)
            let scale = min(1, min((Self.maxSize.width - 24) / max(px.width, 1),
                                   (Self.maxSize.height - 24) / max(px.height, 1)))
            contentSize = NSSize(width: max(Self.minSize.width, px.width * scale + 24),
                                 height: max(Self.minSize.height, px.height * scale + 24))
        case .text, .file:
            imageView.isHidden = true
            textScroll.isHidden = false
            let content = item.text ?? ""
            textView.string = content
            textView.textColor = theme.cardFG
            textView.font = .systemFont(ofSize: Typo.control)
            // 按内容量高度：以最大宽度排版一次
            let width = Self.maxSize.width
            let bounding = (content as NSString).boundingRect(
                with: NSSize(width: width - 32, height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: Typo.control)])
            contentSize = NSSize(width: width,
                                 height: min(Self.maxSize.height,
                                             max(Self.minSize.height, ceil(bounding.height) + 32)))
        }

        // 锚定：shelf 顶边上方 12pt，水平居中（跟随 shelf 所在屏幕）
        let sf = shelf.frame
        let origin = NSPoint(x: sf.midX - contentSize.width / 2,
                             y: sf.maxY + 12)
        panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
        layoutContent(size: contentSize)
        if panel.parent == nil { shelf.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// 键盘滚动长文（↑↓ 转发到这里；预览打开时上下键不再切焦点区）。
    /// dy 为正向下滚动；图片预览无滚动，忽略。
    func scrollText(by dy: CGFloat) {
        guard let panel, panel.isVisible, !textScroll.isHidden,
              let doc = textScroll.documentView else { return }
        let cv = textScroll.contentView
        var p = cv.bounds.origin
        p.y = max(0, min(p.y + dy, max(0, doc.frame.height - cv.bounds.height)))
        cv.scroll(to: p)
        textScroll.reflectScrolledClipView(cv)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.minSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = Metrics.radiusL
        root.layer?.borderWidth = 1
        p.contentView = root

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        root.addSubview(textScroll)

        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        root.addSubview(imageView)

        panel = p
    }

    private func apply(theme: Theme) {
        guard let root = panel?.contentView else { return }
        root.layer?.backgroundColor = theme.cardBG.withAlphaComponent(0.98).cgColor
        root.layer?.borderColor = theme.cardBorder.cgColor
    }

    private func layoutContent(size: NSSize) {
        let inner = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        textScroll.frame = inner
        imageView.frame = inner.insetBy(dx: 12, dy: 12)
        // 文本视图宽度跟随容器（NSTextView 在 scrollview 里需要手动同步容器宽）
        textView.frame = NSRect(x: 0, y: 0, width: inner.width, height: inner.height)
        textView.textContainer?.containerSize = NSSize(width: inner.width - 24, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.scrollToBeginningOfDocument(nil)
    }
}
