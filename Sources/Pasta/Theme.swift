import AppKit

/// 一套皮肤的全部色值。面板和卡片都从这里取色。
struct Theme {
    let id: String
    let name: String

    // 面板（磨砂栏）
    let blurMaterial: NSVisualEffectView.Material
    let appearance: NSAppearance.Name
    let shelfTint: NSColor          // 磨砂上叠的色
    let topEdge: NSColor            // 上沿白微光
    let glow: NSColor               // 顶部品牌光晕（渐变起色）
    let primaryText: NSColor        // 搜索框文字
    let secondaryText: NSColor      // 工具条次要文字/图标/条数/提示
    let accent: NSColor             // 强调色：焦点环、选中边框、链接、类型标签字
    let accentGlow: NSColor         // 辉光/强调描边（accent 同色 @0.55）：选中卡辉光、焦点环辉光、toast 边框

    // 卡片
    let cardBG: NSColor
    let cardHoverBG: NSColor
    let cardFG: NSColor             // 正文
    let cardDim: NSColor            // 类型/时间/来源
    let cardFaint: NSColor          // 字符数
    let cardBorder: NSColor         // 普通边框
    let cardInsetHi: NSColor        // 顶部内高光
    let cardShadow: NSColor         // 投影色
    let cardShadowNormal: Float     // 普通投影浓度
    let cardShadowHover: Float       // hover 投影浓度
    /// 收藏星色：深色主题金黄；浅色主题必须压暗（图形对象 WCAG AA 需 ≥3:1）。
    var pinColor: NSColor = .systemYellow

    /// 类型标签分色（kindLabel → 字色+淡底）。空 = 类型词用 accentText 单色（旧行为）。
    /// 彩色只做识别不做装饰：只落在 11px 类型词上，不碰正文。
    var typeTints: [String: TypeTint] = [:]

    /// accent 的文字级深档：亮 accent（如随色的黄/亮蓝）图形达标但文字不达标时，
    /// 文字场合（类型词兜底/命中高亮/选中 tab 字）用它。nil = accent 本身已达 4.5:1。
    var accentText: NSColor? = nil
    var accentTextColor: NSColor { accentText ?? accent }

    struct TypeTint {
        let fg: NSColor
        let wash: NSColor
    }

    /// 非 nil 时面板底改用横向渐变（玻璃拟态）；nil 用纯色 shelfTint。
    var gradient: [NSColor]? = nil
    var gradientLocations: [NSNumber]? = nil

    /// accent 底上的文字色（⌘ 直达角标等）。深色近黑默认适配 midnight/ink 的亮 accent
    /// （白字在这些 accent 上仅 1.6–2.9:1）；frost/paper 的深 accent 显式改用白。
    var onAccent: NSColor = NSColor(srgbRed: 0.04, green: 0.10, blue: 0.16, alpha: 1)

    /// 边框/分隔线的生效色：系统「增强对比度」开启时 alpha 提至 2.5 倍
    /// （Apple 规范：prefers-contrast 下要给出明确的对比边框，8–14% 的发丝线会消失）。
    var cardBorderEffective: NSColor {
        guard NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return cardBorder }
        return cardBorder.withAlphaComponent(min(1, cardBorder.alphaComponent * 2.5))
    }

    // MARK: - 品牌原色（单一事实源）
    /// Pasta 蓝 #189EF2。夜青/轻霜的 accent 从它按明度派生（色相 203° 不变）；
    /// _design/icon-v2.html 的强调色与此同源。
    static let brandBlue = NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 1)

    // MARK: - 当前主题（卡片视图取色用）
    static var current: Theme = .midnight

    // 2026-08-12 两轮收敛：8 → 5（删 晶蓝/青提/晴日）→ apple-design 轮新增 轻霜/随色 →
    // 晨光退役由轻霜继位（浅色基本盘从近实 0.74 升级为真材质 0.55）、蜜柑删除。
    // 存档在 _design/skins-explore-v3/v4.html 与 git 历史。被删 id 由 by(id:) 回退到夜青。
    static let all: [Theme] = [.midnight, .ink, .frost, .paper]
    static func by(id: String) -> Theme {
        if id == accentFollowID { return makeAccentFollow() }   // 机制型：每次现算，系统强调色不快照
        if id == "daylight" { return .frost }                   // 晨光退役（2026-08-12）：轻霜继位，老用户无感迁移
        return all.first { $0.id == id } ?? .midnight
    }

    /// 「跟随系统」伪主题 id：深色 → 夜青，浅色 → 轻霜。
    static let autoID = "auto"

    static func resolved(id: String) -> Theme {
        guard id == autoID else { return by(id: id) }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .midnight : .frost
    }

    // MARK: - 1 · 夜青（默认；2026-08-12 由「午夜青」更名，对齐两字命名族）
    static let midnight = Theme(
        id: "midnight", name: "夜青",
        blurMaterial: .hudWindow, appearance: .darkAqua,
        shelfTint: NSColor(srgbRed: 0.149, green: 0.169, blue: 0.212, alpha: 0.42),
        topEdge: NSColor(white: 1, alpha: 0.16),
        glow: Theme.brandBlue.withAlphaComponent(0.13),
        primaryText: NSColor(white: 1, alpha: 0.95),
        secondaryText: NSColor(white: 1, alpha: 0.55),   // ≥4.5:1（WCAG AA）
        accent: Theme.brandBlue,                          // = 品牌原色
        accentGlow: Theme.brandBlue.withAlphaComponent(0.55),
        cardBG: NSColor(srgbRed: 0.171, green: 0.182, blue: 0.209, alpha: 1),   // #2C2E35：accent 类型标签 4.6:1
        cardHoverBG: NSColor(srgbRed: 0.235, green: 0.25, blue: 0.285, alpha: 1),
        cardFG: NSColor(white: 1, alpha: 0.94),
        cardDim: NSColor(white: 1, alpha: 0.62),         // 6.0:1
        cardFaint: NSColor(white: 1, alpha: 0.50),       // 4.5:1
        cardBorder: NSColor(white: 1, alpha: 0.10),
        cardInsetHi: NSColor(white: 1, alpha: 0.13),
        cardShadow: .black, cardShadowNormal: 0.36, cardShadowHover: 0.42,
        typeTints: [   // 类型分色：链接留 accent 蓝族，图片琥珀、邮箱薄荷；暗卡 #2C2E35 上 6.6/6.4/7.0:1
            "链接": TypeTint(fg: NSColor(srgbRed: 0.435, green: 0.749, blue: 0.961, alpha: 1),    // #6FBFF5
                           wash: NSColor(srgbRed: 0.435, green: 0.749, blue: 0.961, alpha: 0.14)),
            "图片": TypeTint(fg: NSColor(srgbRed: 0.910, green: 0.706, blue: 0.361, alpha: 1),    // #E8B45C
                           wash: NSColor(srgbRed: 0.910, green: 0.706, blue: 0.361, alpha: 0.14)),
            "邮箱": TypeTint(fg: NSColor(srgbRed: 0.435, green: 0.827, blue: 0.659, alpha: 1),    // #6FD3A8
                           wash: NSColor(srgbRed: 0.435, green: 0.827, blue: 0.659, alpha: 0.14)),
        ])

    // MARK: - 2 · 纯墨（OLED）
    static let ink = Theme(
        id: "ink", name: "纯墨",
        blurMaterial: .hudWindow, appearance: .darkAqua,
        shelfTint: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.78),
        topEdge: NSColor(white: 1, alpha: 0.10),
        glow: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 0.06),
        primaryText: NSColor(white: 1, alpha: 0.93),
        secondaryText: NSColor(white: 1, alpha: 0.52),   // ≥4.5:1（WCAG AA）
        accent: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 1),   // OLED 金：有意区别于蓝系（唯一非品牌蓝主题）
        accentGlow: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 0.55),
        cardBG: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.125, alpha: 1),
        cardHoverBG: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.175, alpha: 1),
        cardFG: NSColor(white: 1, alpha: 0.93),
        cardDim: NSColor(white: 1, alpha: 0.60),         // 6.8:1
        cardFaint: NSColor(white: 1, alpha: 0.48),       // 4.8:1
        cardBorder: NSColor(white: 1, alpha: 0.08),   // OLED 黑上 5% 不可辨；8% 有轮廓无亮线（typeTints 刻意不启用：一色金纪律是纯墨的 signature）
        cardInsetHi: NSColor(white: 1, alpha: 0.10),
        cardShadow: .black, cardShadowNormal: 0.55, cardShadowHover: 0.62,
        pinColor: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 1))   // 与 OLED 金 accent 同源，收敛于纯墨的克制气质

    // MARK: - 3 · 宣纸（中性纸感浅色）— chroma≈0 纸白 + 印泥朱 accent + 低饱和印刷分色
    // 设计稿：_design/skins-explore-v3.html §04（第三轮四方向探索中被采纳的一支）。
    // 第三种浅色：非奶油的暖、非雪的冷，是纸。墨字 + 铅笔灰元信息，唯一的颜色是一枚印章。
    // 全部实算：黑/白双后景，文字对 5.1–14.8:1，hover 可辨比 1.12（faint 在 hover 上仍 4.58）。
    static let paper = Theme(
        id: "ricepaper", name: "宣纸",
        blurMaterial: .popover, appearance: .aqua,
        shelfTint: NSColor(srgbRed: 0.965, green: 0.961, blue: 0.941, alpha: 0.94),  // #F6F5F0 宣纸白（黑后景 sec 5.7:1）
        topEdge: NSColor(white: 1, alpha: 0.90),
        glow: NSColor(srgbRed: 0.757, green: 0.231, blue: 0.180, alpha: 0.07),       // 一点朱气
        primaryText: NSColor(srgbRed: 0.149, green: 0.145, blue: 0.137, alpha: 1),   // #262523 墨
        secondaryText: NSColor(srgbRed: 0.353, green: 0.345, blue: 0.314, alpha: 1), // #5A5850 铅笔灰 5.7:1
        accent: NSColor(srgbRed: 0.757, green: 0.231, blue: 0.180, alpha: 1),        // #C13B2E 印泥朱（纸卡上 5.15:1）
        accentGlow: NSColor(srgbRed: 0.757, green: 0.231, blue: 0.180, alpha: 0.55),
        cardBG: NSColor(srgbRed: 0.988, green: 0.984, blue: 0.965, alpha: 1),        // #FCFBF6 纸面（不透明：纸是哑光的）
        cardHoverBG: NSColor(srgbRed: 0.941, green: 0.933, blue: 0.898, alpha: 1),   // #F0EEE5 纸面压深：可辨比 1.12
        cardFG: NSColor(srgbRed: 0.149, green: 0.145, blue: 0.137, alpha: 1),        // 14.8:1
        cardDim: NSColor(srgbRed: 0.361, green: 0.353, blue: 0.322, alpha: 1),       // #5C5A52 6.7:1
        cardFaint: NSColor(srgbRed: 0.431, green: 0.420, blue: 0.384, alpha: 1),     // #6E6B62 5.1:1
        cardBorder: NSColor(srgbRed: 0.149, green: 0.145, blue: 0.137, alpha: 0.10), // 墨 10%，铅笔轮廓
        cardInsetHi: NSColor(white: 1, alpha: 0.90),
        cardShadow: NSColor(srgbRed: 0.235, green: 0.216, blue: 0.157, alpha: 1),    // 淡墨影
        cardShadowNormal: 0.12, cardShadowHover: 0.20,
        pinColor: NSColor(srgbRed: 0.561, green: 0.459, blue: 0, alpha: 1),          // #8F7500 赭金 4.3:1（图形级）
        typeTints: [   // 低饱和印刷感：印刷蓝/赭石/竹绿（6.3/5.7/5.7:1）
            "链接": TypeTint(fg: NSColor(srgbRed: 0.122, green: 0.373, blue: 0.627, alpha: 1),   // #1F5FA0 印刷蓝
                           wash: NSColor(srgbRed: 0.906, green: 0.933, blue: 0.973, alpha: 1)),  // #E7EEF8
            "图片": TypeTint(fg: NSColor(srgbRed: 0.541, green: 0.353, blue: 0.157, alpha: 1),   // #8A5A28 赭石
                           wash: NSColor(srgbRed: 0.965, green: 0.922, blue: 0.867, alpha: 1)),  // #F6EBDD
            "邮箱": TypeTint(fg: NSColor(srgbRed: 0.227, green: 0.439, blue: 0.282, alpha: 1),   // #3A7048 竹绿
                           wash: NSColor(srgbRed: 0.898, green: 0.945, blue: 0.902, alpha: 1)),  // #E5F1E6
        ],
        accentText: NSColor(srgbRed: 0.627, green: 0.165, blue: 0.122, alpha: 1),    // #A02A1F 印泥深档 7.1:1
        onAccent: .white)   // #C13B2E 上白字 5.3:1

    // MARK: - 4 · 轻霜（亮超薄玻璃，2026-08-12 起为「跟随系统」浅色分身）— 真透明，壁纸颜色即氛围
    // 探索稿：_design/skins-explore-v4.html §02（apple-design 镜头 · 真材质缺口）。
    // 超薄（0.55，晨光是 0.74）的代价按 Apple 规范对冲：黑壁纸最不利合成下没有「次级灰」
    // 的余量——工具条文字全部收敛到近墨（4.55–4.67），层级改由字重表达（vibrancy 补偿
    // 机制会给 <0.6 透明度的 shelf 自动升 medium）；卡片保持白实卡，不犯浅透明叠浅透明禁区。
    static let frost = Theme(
        id: "frost", name: "轻霜",
        blurMaterial: .popover, appearance: .aqua,
        shelfTint: NSColor(white: 1, alpha: 0.55),                                  // 黑后景合成 ≈ 中灰
        topEdge: NSColor(white: 1, alpha: 0.95),
        glow: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 0.08),
        primaryText: NSColor(srgbRed: 0.122, green: 0.141, blue: 0.161, alpha: 1),  // #1F2429 黑后景实算 4.67
        secondaryText: NSColor(srgbRed: 0.129, green: 0.149, blue: 0.169, alpha: 1),// #21262B 黑后景实算 4.55
        accent: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 1),       // #1274B2 与晨光同族，靠材质区分
        accentGlow: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 0.55),
        cardBG: NSColor(white: 1, alpha: 1),
        cardHoverBG: NSColor(srgbRed: 0.914, green: 0.941, blue: 0.976, alpha: 1),  // #E9F0F9 可辨比 1.15
        cardFG: NSColor(srgbRed: 0.122, green: 0.141, blue: 0.161, alpha: 1),
        cardDim: NSColor(white: 0, alpha: 0.62),         // 白卡 6.2:1
        cardFaint: NSColor(white: 0, alpha: 0.54),       // 白卡 4.6:1
        cardBorder: NSColor(srgbRed: 0.078, green: 0.157, blue: 0.235, alpha: 0.10),
        cardInsetHi: NSColor(white: 1, alpha: 0.9),
        cardShadow: NSColor(srgbRed: 0.078, green: 0.176, blue: 0.333, alpha: 1),
        cardShadowNormal: 0.16, cardShadowHover: 0.24,
        pinColor: NSColor(srgbRed: 0.69, green: 0.494, blue: 0, alpha: 1),          // #B07E00 琥珀
        typeTints: [   // 白卡语境的语义三色（承袭已退役的晨光，语义色跨主题稳定）
            "链接": TypeTint(fg: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 1),    // #1274B2
                           wash: NSColor(srgbRed: 0.890, green: 0.941, blue: 0.984, alpha: 1)),   // #E3F0FB
            "图片": TypeTint(fg: NSColor(srgbRed: 0.541, green: 0.392, blue: 0, alpha: 1),        // #8A6400
                           wash: NSColor(srgbRed: 1.0, green: 0.945, blue: 0.788, alpha: 1)),     // #FFF1C9
            "邮箱": TypeTint(fg: NSColor(srgbRed: 0.078, green: 0.478, blue: 0.361, alpha: 1),    // #147A5C
                           wash: NSColor(srgbRed: 0.875, green: 0.957, blue: 0.925, alpha: 1)),   // #DFF4EC
        ],
        onAccent: .white)   // #1274B2 上白字 5.0:1

    // MARK: - 5 · 随色（跟随系统强调色）— Apple 第 2 原则 Agency：颜色是用户的，不是皮肤的
    // 探索稿：_design/skins-explore-v4.html §01。中性无色相底 + accent 族运行时从
    // NSColor.controlAccentColor 现算：文字档压深到白卡 ≥4.5（textGrade）、角标配字黑白择优。
    // typeTints 刻意为空：一色纪律，色彩让位给用户选的强调色。
    static let accentFollowID = "syscolor"

    static func makeAccentFollow() -> Theme {
        let sys = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0.039, green: 0.51, blue: 1, alpha: 1)
        let ink = NSColor(srgbRed: 0.04, green: 0.09, blue: 0.13, alpha: 1)
        let onAcc: NSColor = contrastRatio(.white, sys) >= contrastRatio(ink, sys) ? .white : ink
        return Theme(
            id: accentFollowID, name: "随色",
            blurMaterial: .popover, appearance: .aqua,
            shelfTint: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 0.72),  // #F2F3F5 中性 chroma≈0
            topEdge: NSColor(white: 1, alpha: 0.92),
            glow: sys.withAlphaComponent(0.10),
            primaryText: NSColor(srgbRed: 0.137, green: 0.145, blue: 0.161, alpha: 1),   // #232529
            secondaryText: NSColor(srgbRed: 0.227, green: 0.239, blue: 0.259, alpha: 1), // #3A3D42 黑后景实算 4.98
            accent: sys,
            accentGlow: sys.withAlphaComponent(0.55),
            cardBG: NSColor(white: 1, alpha: 1),
            cardHoverBG: NSColor(srgbRed: 0.914, green: 0.918, blue: 0.925, alpha: 1),   // #E9EAEC 中性 wash，可辨比 1.20
            cardFG: NSColor(srgbRed: 0.137, green: 0.145, blue: 0.161, alpha: 1),
            cardDim: NSColor(srgbRed: 0.333, green: 0.345, blue: 0.373, alpha: 1),       // #55585F 7.1:1
            cardFaint: NSColor(srgbRed: 0.4, green: 0.412, blue: 0.435, alpha: 1),       // #66696F 5.5:1
            cardBorder: NSColor(srgbRed: 0.137, green: 0.145, blue: 0.161, alpha: 0.09),
            cardInsetHi: NSColor(white: 1, alpha: 0.9),
            cardShadow: NSColor(srgbRed: 0.118, green: 0.125, blue: 0.157, alpha: 1),
            cardShadowNormal: 0.14, cardShadowHover: 0.22,
            pinColor: NSColor(srgbRed: 0.69, green: 0.494, blue: 0, alpha: 1),           // #B07E00 琥珀
            accentText: textGrade(sys),
            onAccent: onAcc)
    }

    // MARK: - WCAG 运行时工具（随色派生用）

    private static func relLum(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (l1, l2) = (relLum(a), relLum(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// 把颜色按比例压深，直到白卡上文字级 ≥4.5:1（黄/亮蓝等亮强调色的文字档派生）。
    private static func textGrade(_ c: NSColor) -> NSColor {
        guard let s = c.usingColorSpace(.sRGB) else { return c }
        var f: CGFloat = 1
        var out = s
        while contrastRatio(out, .white) < 4.5 && f > 0.2 {
            f -= 0.05
            out = NSColor(srgbRed: s.redComponent * f, green: s.greenComponent * f, blue: s.blueComponent * f, alpha: 1)
        }
        return out
    }
}

// MARK: - 字阶（6 档，步进 ≈1.125；UI 文字一律从这里取号）
enum Typo {
    static let badge: CGFloat = 10       // ⌘ 直达角标（唯一比 caption 小的特例）
    static let caption: CGFloat = 11     // 卡片元信息/来源/字数、hint、偏好提示
    static let body: CGFloat = 12.5      // 卡片长正文、工具条条数、toast
    static let control: CGFloat = 13     // 系统控件默认字号（偏好窗口、预览正文）
    static let emphasis: CGFloat = 14    // 卡片短内容、空状态
    static let title: CGFloat = 16       // 搜索框
}

// MARK: - 动效（统一时长/幅度；全部动画路径均受系统「减弱动态」约束）
enum Motion {
    static let state: TimeInterval = 0.14     // 卡片选中/hover 颜色/投影过渡
    static let panelIn: TimeInterval = 0.14   // 面板底部浮入（隐藏刻意无动画：工具用完即走）
    static let toastIn: TimeInterval = 0.15   // toast 渐显
    static let hoverScale: CGFloat = 1.03     // 卡片 hover 轻微放大
    // 卡片 transform 用临界阻尼弹簧（Apple 默认档 damping 1.0 / response 0.3，无过冲）：
    // stiffness = (2π/T)²·m，damping = 2ζ√(k·m)，m=1
    static let springStiffness: CGFloat = 438.6
    static let springDamping: CGFloat = 41.9
    // Fluid 交互（设计稿 _design/fluid-v1.html）
    static let pressScale: CGFloat = 0.982        // 卡片按压态（press 快落，release 弹簧回）
    static let pressIn: TimeInterval = 0.10       // 按压下落时长（要快于回弹）
    static let badgeStagger: TimeInterval = 0.05  // ⌘ 角标从左到右的波浪间隔
    static let previewStiffness: CGFloat = 685.4  // 预览 materialize：response 0.24（浮层比卡片快半档）
    static let previewDamping: CGFloat = 52.4
}

// MARK: - 间距与圆角（4pt 基网格）
enum Metrics {
    static let inset: CGFloat = 12       // 卡片内边距
    static let gap: CGFloat = 16         // 卡片间距
    static let pad: CGFloat = 16         // 卡片条左右留白
    static let toolbarH: CGFloat = 48    // 面板工具条高
    static let radiusS: CGFloat = 6      // 缩略图
    static let radius: CGFloat = 8       // 输入框
    static let radiusL: CGFloat = 12     // 卡片 / toast 等浮出表面
}
