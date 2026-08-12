import AppKit

/// 空格键预览浮层（Quick Look 式）：悬在卡片栏上方居中，随选中项切换内容。
/// 文本 → 可滚动全文；图片 → 等比大图；文件 → 路径清单。
/// 作为主面板的子窗口存在：主面板隐藏/移动时自动跟随。
///
/// Fluid 交互（设计稿 _design/fluid-v1.html §01）：
/// - 材质：大表面用比卡片更厚的磨砂（NSVisualEffectView + 主题色罩），替代旧实色底
/// - materialize：进场自下方「生长」（底缘锚定 scale 0.94→1 + 上浮 10pt 弹簧 + 渐显），
///   退出反向同路径（§7 空间一致性）；减弱动态 → 纯 crossfade
/// - 方向滑动：←→ 切换选中时内容 8pt 方向滑入（§8 方向暗示）
final class PreviewPanel {
    private var panel: NSPanel?
    private var glass: NSVisualEffectView!
    private var tint: NSView!
    private var contentHost: NSView!
    private var textScroll: NSScrollView!
    private var textView: NSTextView!
    private var imageView: NSImageView!
    /// 退场取消令牌：退场动画期间再次唤起时作废挂起的 orderOut。
    private var hideToken = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    private static let maxSize = NSSize(width: 640, height: 400)
    private static let minSize = NSSize(width: 280, height: 120)

    /// 显示（或刷新）预览，锚定在 shelf 窗口上方居中。
    /// slide：内容切换方向（+1 → 下一张，内容从右滑入；-1 反向；0 无方向）。
    func show(_ item: ClipItem, above shelf: NSWindow, slide: Int = 0) {
        let theme = Theme.current
        if panel == nil { build() }
        guard let panel else { return }
        let wasVisible = panel.isVisible
        hideToken += 1                     // 作废挂起的退场
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

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible {
            materializeIn(reduceMotion: reduceMotion)
        } else if slide != 0, !reduceMotion {
            slideContent(direction: slide)
        }
    }

    /// 进场：材质到场（scale 0.94 + 上浮 10pt 底缘锚定弹簧 + 渐显），不是贴图淡入。
    private func materializeIn(reduceMotion: Bool) {
        guard let panel else { return }
        glass.layer?.removeAllAnimations()
        glass.layer?.transform = CATransform3DIdentity
        if reduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
            return
        }
        if let l = glass.layer {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1
            spring.stiffness = Motion.previewStiffness
            spring.damping = Motion.previewDamping
            spring.fromValue = NSValue(caTransform3D: bottomPinnedTransform(scale: 0.94, rise: -10, layer: l))
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.duration = spring.settlingDuration
            l.add(spring, forKey: "matz")
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// 底缘中点钉住的缩放变换（不改 anchorPoint，避免与 AppKit 图层管理冲突）：
    /// 任意 anchor 下补偿平移，使底缘中点仅位移 rise。
    private func bottomPinnedTransform(scale s: CGFloat, rise: CGFloat, layer l: CALayer) -> CATransform3D {
        let w = l.bounds.width, h = l.bounds.height
        let c = CGPoint(x: l.anchorPoint.x * w, y: l.anchorPoint.y * h)   // 缩放中心（层坐标）
        let bc = CGPoint(x: w / 2, y: 0)                                   // 底缘中点
        let tx = (1 - s) * (bc.x - c.x)
        let ty = (1 - s) * (bc.y - c.y) + rise
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                   CATransform3DMakeTranslation(tx, ty, 0))
    }

    /// 内容方向滑动：新内容从移动方向滑入 8pt（§8 方向暗示）。
    private func slideContent(direction: Int) {
        guard let l = contentHost.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = CGFloat(direction) * 8
        slide.toValue = 0
        slide.duration = 0.15
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 1
        fade.duration = 0.15
        l.add(slide, forKey: "slidein")
        l.add(fade, forKey: "fadein")
    }

    /// 退出：反向同路径（scale→0.96 + 下沉 + 渐隐，0.12s 截断即可）；
    /// animated=false（主面板整体关闭）时立即消失，不留浮层单独表演。
    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.alphaValue = 1
            glass.layer?.removeAllAnimations()
            glass.layer?.transform = CATransform3DIdentity
            return
        }
        hideToken += 1
        let token = hideToken
        if let l = glass.layer {
            let out = CABasicAnimation(keyPath: "transform")
            out.fromValue = NSValue(caTransform3D: l.presentation()?.transform ?? CATransform3DIdentity)
            out.toValue = NSValue(caTransform3D: bottomPinnedTransform(scale: 0.96, rise: -6, layer: l))
            out.duration = 0.12
            out.timingFunction = CAMediaTimingFunction(name: .easeIn)
            l.add(out, forKey: "matzout")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let panel = self.panel, token == self.hideToken else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.glass.layer?.removeAllAnimations()
            self.glass.layer?.transform = CATransform3DIdentity
        })
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

    /// 翻页滚动（PageUp/PageDown）：一页 = 可视高 − 一行重叠。
    func scrollPage(_ direction: Int) {
        let page = max(textScroll.contentView.bounds.height - 24, 40)
        scrollText(by: CGFloat(direction) * page)
    }

    /// Home/End 直达顶/底。
    func scrollToEdge(top: Bool) {
        guard let panel, panel.isVisible, !textScroll.isHidden,
              let doc = textScroll.documentView else { return }
        let cv = textScroll.contentView
        let y = top ? 0 : max(0, doc.frame.height - cv.bounds.height)
        cv.scroll(to: NSPoint(x: 0, y: y))
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

        // 容器透明不裁剪：给玻璃层的 materialize 变换留出活动空间
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        p.contentView = container

        // 玻璃表面：大表面用厚磨砂（比卡片厚一档），主题色罩在其上
        glass = NSVisualEffectView()
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        container.addSubview(glass)

        tint = NSView()
        tint.wantsLayer = true
        glass.addSubview(tint)

        contentHost = NSView()
        contentHost.wantsLayer = true
        glass.addSubview(contentHost)

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        contentHost.addSubview(textScroll)

        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        contentHost.addSubview(imageView)

        panel = p
    }

    private func apply(theme: Theme) {
        guard let panel else { return }
        panel.appearance = NSAppearance(named: theme.appearance)
        glass.material = theme.blurMaterial
        glass.layer?.borderColor = theme.cardBorderEffective.cgColor
        tint.layer?.backgroundColor = theme.cardBG.withAlphaComponent(0.72).cgColor
    }

    private func layoutContent(size: NSSize) {
        let inner = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        glass.frame = inner
        tint.frame = inner
        contentHost.frame = inner
        textScroll.frame = inner
        imageView.frame = inner.insetBy(dx: 12, dy: 12)
        // 文本视图宽度跟随容器（NSTextView 在 scrollview 里需要手动同步容器宽）
        textView.frame = NSRect(x: 0, y: 0, width: inner.width, height: inner.height)
        textView.textContainer?.containerSize = NSSize(width: inner.width - 24, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.scrollToBeginningOfDocument(nil)
    }
}
