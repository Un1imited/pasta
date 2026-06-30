import AppKit
import ImageIO

/// 进程级缓存：来源 App 名/图标按 bundleID 缓存，缩略图/尺寸按记录 id 缓存。
/// 避免每次唤起面板都重复做磁盘查询与整图解码（长历史时这是卡顿主因）。
private enum ClipCaches {
    static var appNames: [String: String?] = [:]
    static var appIcons: [String: NSImage?] = [:]
    static let thumbnails = NSCache<NSUUID, NSImage>()
    static var imageSizes: [UUID: NSSize] = [:]
}

/// 一条剪贴板历史记录。文本 / 图片 / 文件三种类型。
struct ClipItem: Codable, Identifiable {
    enum Kind: String, Codable {
        case text
        case image
        case file
    }

    let id: UUID
    var kind: Kind
    var text: String?       // text 与 file 类型用（file 存换行分隔的路径）
    var rtfData: Data?      // text 类型的富文本版本（用于「保留格式」粘贴）
    var imageData: Data?    // image 类型用，存 PNG
    var pinned: Bool
    var date: Date
    var sourceBundleID: String?   // 复制来源 App 的 bundle id（卡片右上角徽标用）

    init(kind: Kind, text: String? = nil, rtfData: Data? = nil, imageData: Data? = nil,
         pinned: Bool = false, sourceBundleID: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.rtfData = rtfData
        self.imageData = imageData
        self.pinned = pinned
        self.date = Date()
        self.sourceBundleID = sourceBundleID
    }

    /// 用于去重的内容判等（忽略 id / date / pinned / 富文本差异）。
    func sameContent(as other: ClipItem) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .text, .file:
            return text == other.text
        case .image:
            return imageData == other.imageData
        }
    }

    /// 搜索用的纯文本。
    var searchText: String {
        switch kind {
        case .text, .file:
            return text ?? ""
        case .image:
            return "图片 image"
        }
    }

    /// 列表左侧图标用的 SF Symbol 名（图片类型走缩略图，不用这个）。
    var symbolName: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return "link" }
            if t.contains("@"), !t.contains(" "), t.contains(".") { return "envelope" }
            return "doc.text"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// 列表右侧显示的相对时间。
    var relativeTime: String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        if s < 172800 { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    /// 图片像素尺寸：用 ImageIO 只读元数据，不整图解码；按 id 缓存。
    var imageSize: NSSize? {
        guard kind == .image, let data = imageData else { return nil }
        if let s = ClipCaches.imageSizes[id] { return s }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let size = NSSize(width: w, height: h)
        ClipCaches.imageSizes[id] = size
        return size
    }

    /// 卡片底部信息：字符数 / 尺寸 / 文件数。
    var footerInfo: String {
        switch kind {
        case .image:
            if let s = imageSize {
                return "\(Int(s.width)) × \(Int(s.height))"
            }
            return "图片"
        case .file:
            let n = (text ?? "").split(separator: "\n").count
            return n > 1 ? "\(n) 个文件" : "文件"
        case .text:
            return "\(text?.count ?? 0) 字符"
        }
    }

    /// 来源 App 的显示名（飞书 / 终端 / PyCharm…），解析不到为 nil。按 bundleID 缓存。
    var sourceAppName: String? {
        guard let bid = sourceBundleID else { return nil }
        if let cached = ClipCaches.appNames[bid] { return cached }
        let resolved: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let name = FileManager.default.displayName(atPath: url.path)
            resolved = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        } else {
            resolved = nil
        }
        ClipCaches.appNames[bid] = resolved
        return resolved
    }

    /// 表头是否显示类型词（纯文本不显示，链接/图片/文件/邮箱等才显示）。
    var showsKindInHeader: Bool { kindLabel != "文本" }

    /// 卡片主体显示的（可多行）文本。
    var bodyText: String {
        switch kind {
        case .image: return ""
        case .text, .file: return String((text ?? "").prefix(400))
        }
    }

    /// 卡片是否用深色（来源是终端/编辑器/IDE → 深卡；无来源 → 默认深卡；其余 → 白卡）。
    var prefersDarkCard: Bool {
        guard let b = sourceBundleID?.lowercased() else { return true }
        if b.hasPrefix("com.jetbrains") { return true }   // PyCharm / IntelliJ / GoLand…
        let darkApps = [
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp",
            "com.github.wez.wezterm", "io.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper",
            "com.microsoft.vscode", "com.todesktop",        // VSCode / Cursor
            "com.sublimetext", "dev.zed.zed", "com.exafunction",  // Sublime / Zed / Windsurf
            "com.apple.dt.xcode", "com.panic.nova",
        ]
        return darkApps.contains { b.hasPrefix($0) }
    }

    /// 来源 App 图标（按 bundle id 解析）。按 bundleID 缓存。
    var sourceAppIcon: NSImage? {
        guard let bid = sourceBundleID else { return nil }
        if let cached = ClipCaches.appIcons[bid] { return cached }
        let icon: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = nil
        }
        ClipCaches.appIcons[bid] = icon
        return icon
    }

    /// 类型中文名（底栏显示）。
    var kindLabel: String {
        switch symbolName {
        case "link": return "链接"
        case "envelope": return "邮箱"
        case "photo": return "图片"
        case "doc": return "文件"
        default: return "文本"
        }
    }

    /// 列表里显示的单行正文（不含图标、置顶标记）。
    var previewBody: String {
        switch kind {
        case .image:
            if let s = imageSize {
                return "图片 \(Int(s.width))×\(Int(s.height))"
            }
            return "图片"
        case .text, .file:
            let raw = (text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(raw.prefix(160))
        }
    }

    /// 列表行的缩略图（仅图片有）。用 ImageIO 生成降采样缩略图（不整图解码）并按 id 缓存。
    var thumbnail: NSImage? {
        guard kind == .image, let data = imageData else { return nil }
        let key = id as NSUUID
        if let cached = ClipCaches.thumbnails.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        ClipCaches.thumbnails.setObject(img, forKey: key)
        return img
    }
}
