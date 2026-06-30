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
    let accentGlow: NSColor         // 选中卡片辉光

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
    let kindBG: NSColor             // 类型标签底色

    /// 非 nil 时面板底改用横向渐变（玻璃拟态）；nil 用纯色 shelfTint。
    var gradient: [NSColor]? = nil
    var gradientLocations: [NSNumber]? = nil

    // MARK: - 当前主题（卡片视图取色用）
    static var current: Theme = .midnight

    static let all: [Theme] = [.midnight, .glass, .daylight, .ink]
    static func by(id: String) -> Theme { all.first { $0.id == id } ?? .midnight }

    // MARK: - 1 · 午夜青（默认）
    static let midnight = Theme(
        id: "midnight", name: "午夜青",
        blurMaterial: .hudWindow, appearance: .darkAqua,
        shelfTint: NSColor(srgbRed: 0.149, green: 0.169, blue: 0.212, alpha: 0.42),
        topEdge: NSColor(white: 1, alpha: 0.16),
        glow: NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 0.13),
        primaryText: NSColor(white: 1, alpha: 0.95),
        secondaryText: NSColor(white: 1, alpha: 0.42),
        accent: NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 1),
        accentGlow: NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 0.3),
        cardBG: NSColor(srgbRed: 0.18, green: 0.192, blue: 0.22, alpha: 1),
        cardHoverBG: NSColor(srgbRed: 0.235, green: 0.25, blue: 0.285, alpha: 1),
        cardFG: NSColor(white: 1, alpha: 0.94),
        cardDim: NSColor(white: 1, alpha: 0.46),
        cardFaint: NSColor(white: 1, alpha: 0.30),
        cardBorder: NSColor(white: 1, alpha: 0.10),
        cardInsetHi: NSColor(white: 1, alpha: 0.13),
        cardShadow: .black, cardShadowNormal: 0.36, cardShadowHover: 0.42,
        kindBG: NSColor(srgbRed: 0.094, green: 0.62, blue: 0.95, alpha: 0.18))

    // MARK: - 2 · 晨光（浅）
    static let daylight = Theme(
        id: "daylight", name: "晨光",
        blurMaterial: .popover, appearance: .aqua,
        shelfTint: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.957, alpha: 0.74),
        topEdge: NSColor(white: 1, alpha: 0.95),
        glow: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 0.10),
        primaryText: NSColor(white: 0, alpha: 0.85),
        secondaryText: NSColor(white: 0, alpha: 0.42),
        accent: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1),
        accentGlow: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 0.25),
        cardBG: NSColor(white: 1, alpha: 1),
        cardHoverBG: NSColor(white: 1, alpha: 1),
        cardFG: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1),
        cardDim: NSColor(white: 0, alpha: 0.45),
        cardFaint: NSColor(white: 0, alpha: 0.30),
        cardBorder: NSColor(srgbRed: 0, green: 0.117, blue: 0.275, alpha: 0.08),
        cardInsetHi: NSColor(white: 1, alpha: 0.9),
        cardShadow: NSColor(srgbRed: 0.078, green: 0.176, blue: 0.333, alpha: 1),
        cardShadowNormal: 0.18, cardShadowHover: 0.26,
        kindBG: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 0.10))

    // MARK: - 3 · 纯墨（OLED）
    static let ink = Theme(
        id: "ink", name: "纯墨",
        blurMaterial: .hudWindow, appearance: .darkAqua,
        shelfTint: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.78),
        topEdge: NSColor(white: 1, alpha: 0.10),
        glow: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 0.06),
        primaryText: NSColor(white: 1, alpha: 0.93),
        secondaryText: NSColor(white: 1, alpha: 0.40),
        accent: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 1),
        accentGlow: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 0.26),
        cardBG: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.125, alpha: 1),
        cardHoverBG: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.175, alpha: 1),
        cardFG: NSColor(white: 1, alpha: 0.93),
        cardDim: NSColor(white: 1, alpha: 0.42),
        cardFaint: NSColor(white: 1, alpha: 0.28),
        cardBorder: NSColor(white: 1, alpha: 0.05),
        cardInsetHi: NSColor(white: 1, alpha: 0.10),
        cardShadow: .black, cardShadowNormal: 0.55, cardShadowHover: 0.62,
        kindBG: NSColor(srgbRed: 0.91, green: 0.788, blue: 0.478, alpha: 0.15))

    // MARK: - 4 · 晶蓝（玻璃拟态）— 深蓝横向渐变底 + 半透玻璃卡
    static let glass = Theme(
        id: "glass", name: "晶蓝",
        blurMaterial: .hudWindow, appearance: .darkAqua,
        shelfTint: NSColor(srgbRed: 0.110, green: 0.153, blue: 0.251, alpha: 0.82),  // 渐变缺省时的兜底
        topEdge: NSColor(white: 1, alpha: 0.22),
        glow: NSColor(srgbRed: 0.373, green: 0.588, blue: 0.922, alpha: 0.16),
        primaryText: NSColor(white: 1, alpha: 0.95),
        secondaryText: NSColor(srgbRed: 0.824, green: 0.878, blue: 0.961, alpha: 0.55),
        accent: NSColor(srgbRed: 0.353, green: 0.659, blue: 0.961, alpha: 1),         // #5AA8F5
        accentGlow: NSColor(srgbRed: 0.353, green: 0.659, blue: 0.961, alpha: 0.50),
        cardBG: NSColor(srgbRed: 0.608, green: 0.745, blue: 0.910, alpha: 0.13),       // 半透，透出渐变
        cardHoverBG: NSColor(srgbRed: 0.647, green: 0.784, blue: 0.949, alpha: 0.20),
        cardFG: NSColor(white: 1, alpha: 0.92),
        cardDim: NSColor(srgbRed: 0.824, green: 0.878, blue: 0.961, alpha: 0.55),
        cardFaint: NSColor(srgbRed: 0.824, green: 0.878, blue: 0.961, alpha: 0.40),
        cardBorder: NSColor(white: 1, alpha: 0.14),
        cardInsetHi: NSColor(white: 1, alpha: 0.24),
        cardShadow: .black, cardShadowNormal: 0.34, cardShadowHover: 0.46,
        kindBG: NSColor(srgbRed: 0.345, green: 0.651, blue: 0.961, alpha: 0.20),
        gradient: [
            NSColor(srgbRed: 0.078, green: 0.094, blue: 0.122, alpha: 0.82),  // #14181f 左暗
            NSColor(srgbRed: 0.110, green: 0.153, blue: 0.251, alpha: 0.82),  // #1c2740
            NSColor(srgbRed: 0.161, green: 0.263, blue: 0.408, alpha: 0.82),  // #294368 中右最亮
            NSColor(srgbRed: 0.129, green: 0.188, blue: 0.290, alpha: 0.82),  // #21304a 右
        ],
        gradientLocations: [0.0, 0.36, 0.62, 1.0])
}
