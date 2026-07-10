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

    /// 非 nil 时面板底改用横向渐变（玻璃拟态）；nil 用纯色 shelfTint。
    var gradient: [NSColor]? = nil
    var gradientLocations: [NSNumber]? = nil

    // MARK: - 品牌原色（单一事实源）
    /// Pasta 蓝 #189EF2。全部蓝系主题的 accent 从它按明度派生（色相 203° 不变）；
    /// _design/hero.html、icon-final.html 的强调色与此同源。
    static let brandBlue = NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 1)

    // MARK: - 当前主题（卡片视图取色用）
    static var current: Theme = .midnight

    static let all: [Theme] = [.midnight, .glass, .daylight, .ink]
    static func by(id: String) -> Theme { all.first { $0.id == id } ?? .midnight }

    /// 「跟随系统」伪主题 id：深色 → 午夜青，浅色 → 晨光。
    static let autoID = "auto"

    static func resolved(id: String) -> Theme {
        guard id == autoID else { return by(id: id) }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .midnight : .daylight
    }

    // MARK: - 1 · 午夜青（默认）
    static let midnight = Theme(
        id: "midnight", name: "午夜青",
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
        cardShadow: .black, cardShadowNormal: 0.36, cardShadowHover: 0.42)

    // MARK: - 2 · 晨光（浅）
    static let daylight = Theme(
        id: "daylight", name: "晨光",
        blurMaterial: .popover, appearance: .aqua,
        shelfTint: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.957, alpha: 0.74),
        topEdge: NSColor(white: 1, alpha: 0.95),
        glow: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 0.10),
        primaryText: NSColor(white: 0, alpha: 0.85),
        secondaryText: NSColor(white: 0, alpha: 0.62),   // ≥4.5:1（WCAG AA）
        accent: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 1),   // #1274B2 品牌蓝降明度（白卡上 5.0:1）
        accentGlow: NSColor(srgbRed: 0.069, green: 0.457, blue: 0.700, alpha: 0.55),
        cardBG: NSColor(white: 1, alpha: 1),
        cardHoverBG: NSColor(white: 1, alpha: 1),
        cardFG: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1),
        cardDim: NSColor(white: 0, alpha: 0.62),         // 6.2:1
        cardFaint: NSColor(white: 0, alpha: 0.54),       // 4.6:1
        cardBorder: NSColor(srgbRed: 0, green: 0.117, blue: 0.275, alpha: 0.08),
        cardInsetHi: NSColor(white: 1, alpha: 0.9),
        cardShadow: NSColor(srgbRed: 0.078, green: 0.176, blue: 0.333, alpha: 1),
        cardShadowNormal: 0.18, cardShadowHover: 0.26)

    // MARK: - 3 · 纯墨（OLED）
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
        cardBorder: NSColor(white: 1, alpha: 0.05),
        cardInsetHi: NSColor(white: 1, alpha: 0.10),
        cardShadow: .black, cardShadowNormal: 0.55, cardShadowHover: 0.62)

    // MARK: - 4 · 晶蓝（玻璃拟态）— 深蓝横向渐变底 + 半透玻璃卡
    static let glass = Theme(
        id: "glass", name: "晶蓝",
        blurMaterial: .hudWindow, appearance: .darkAqua,
        shelfTint: NSColor(srgbRed: 0.110, green: 0.153, blue: 0.251, alpha: 0.82),  // 渐变缺省时的兜底
        topEdge: NSColor(white: 1, alpha: 0.22),
        glow: NSColor(srgbRed: 0.355, green: 0.727, blue: 0.960, alpha: 0.16),
        primaryText: NSColor(white: 1, alpha: 0.95),
        secondaryText: NSColor(srgbRed: 0.824, green: 0.878, blue: 0.961, alpha: 0.72),  // ≥4.5:1（WCAG AA）
        accent: NSColor(srgbRed: 0.355, green: 0.727, blue: 0.960, alpha: 1),   // #5BB9F5 品牌蓝提明度降饱和（合成卡底上 5.2:1）
        accentGlow: NSColor(srgbRed: 0.355, green: 0.727, blue: 0.960, alpha: 0.55),
        cardBG: NSColor(srgbRed: 0.608, green: 0.745, blue: 0.910, alpha: 0.13),       // 半透，透出渐变
        cardHoverBG: NSColor(srgbRed: 0.647, green: 0.784, blue: 0.949, alpha: 0.20),
        cardFG: NSColor(white: 1, alpha: 0.92),
        cardDim: NSColor(srgbRed: 0.824, green: 0.878, blue: 0.961, alpha: 0.80),     // 6.0:1（对合成后卡底）
        cardFaint: NSColor(srgbRed: 0.824, green: 0.878, blue: 0.961, alpha: 0.65),   // 4.6:1
        cardBorder: NSColor(white: 1, alpha: 0.14),
        cardInsetHi: NSColor(white: 1, alpha: 0.24),
        cardShadow: .black, cardShadowNormal: 0.34, cardShadowHover: 0.46,
        gradient: [
            NSColor(srgbRed: 0.078, green: 0.094, blue: 0.122, alpha: 0.82),  // #14181f 左暗
            NSColor(srgbRed: 0.110, green: 0.153, blue: 0.251, alpha: 0.82),  // #1c2740
            NSColor(srgbRed: 0.161, green: 0.263, blue: 0.408, alpha: 0.82),  // #294368 中右最亮
            NSColor(srgbRed: 0.129, green: 0.188, blue: 0.290, alpha: 0.82),  // #21304a 右
        ],
        gradientLocations: [0.0, 0.36, 0.62, 1.0])
}

// MARK: - 字阶（5 档，步进 ≈1.125；UI 文字一律从这里取号）
enum Typo {
    static let caption: CGFloat = 11     // 卡片元信息/来源/字数、hint、偏好提示
    static let body: CGFloat = 12.5      // 卡片长正文、工具条条数、toast
    static let control: CGFloat = 13     // 系统控件默认字号（偏好窗口，不显式设置）
    static let emphasis: CGFloat = 14    // 卡片短内容、空状态
    static let title: CGFloat = 16       // 搜索框
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
