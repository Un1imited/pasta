import AppKit
import ImageIO

/// 进程级缓存：来源 App 名/图标按 bundleID 缓存，缩略图/尺寸/图片二进制按记录 id 缓存。
/// 避免每次唤起面板都重复做磁盘查询与整图解码（长历史时这是卡顿主因）。
private enum ClipCaches {
    static var appNames: [String: String?] = [:]
    static var appIcons: [String: NSImage?] = [:]
    static let thumbnails: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>()
        c.countLimit = 80                        // 400px 缩略图约 0.6MB/张，上限 ~50MB
        return c
    }()
    static let imageSizes: NSCache<NSUUID, NSValue> = {
        let c = NSCache<NSUUID, NSValue>()
        c.countLimit = 400
        return c
    }()
    static let imageBlobs: NSCache<NSUUID, NSData> = {
        let c = NSCache<NSUUID, NSData>()
        c.countLimit = 12                        // 原图二进制只为粘贴/去重短暂驻留
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    static let pinyins: NSCache<NSUUID, NSArray> = {
        let c = NSCache<NSUUID, NSArray>()
        c.countLimit = 1200                      // [全拼, 首字母] 两个短串/条，覆盖满仓 1000 条
        return c
    }()

    static func purge(id: UUID) {
        let key = id as NSUUID
        thumbnails.removeObject(forKey: key)
        imageSizes.removeObject(forKey: key)
        imageBlobs.removeObject(forKey: key)
        pinyins.removeObject(forKey: key)
    }
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
    var imageData: Data?    // image 类型的 PNG，仅运行时持有；持久化在独立文件（v2），不入 JSON
    var pinned: Bool
    var date: Date
    var sourceBundleID: String?   // 复制来源 App 的 bundle id（卡片右上角徽标用）
    var ocrText: String?          // 图片的 OCR 识别文本（Vision 本地识别，仅参与搜索不参与显示）

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
        self.ocrText = nil
    }

    /// 从持久层（SQLite）还原：rtf / 图片二进制不随加载常驻内存，用到时按需回读。
    init(id: UUID, kind: Kind, text: String?, pinned: Bool, date: Date, sourceBundleID: String?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtfData = nil
        self.imageData = nil
        self.pinned = pinned
        self.date = date
        self.sourceBundleID = sourceBundleID
        self.ocrText = nil
    }

    /// OCR 完成后重建该条的拼音索引（searchText 变了，旧索引失效）。
    static func purgeSearchIndex(id: UUID) {
        ClipCaches.pinyins.removeObject(forKey: id as NSUUID)
    }

    // MARK: - Codable（imageData 不编码；解码保留以兼容 v1 内联格式的迁移）

    enum CodingKeys: String, CodingKey {
        case id, kind, text, rtfData, imageData, pinned, date, sourceBundleID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)   // v1 旧文件的内联图片
        pinned = try c.decode(Bool.self, forKey: .pinned)
        date = try c.decode(Date.self, forKey: .date)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        ocrText = nil   // 旧 JSON 无此字段；迁移后由启动回填补算
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(rtfData, forKey: .rtfData)
        // imageData 刻意不编码：图片落 images/<id>.png，避免 base64 膨胀 + 每次保存全量重编码
        try c.encode(pinned, forKey: .pinned)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
    }

    // MARK: - 图片文件（v2 持久化）

    /// 图片二进制的独立存储目录：Application Support/Pasta/images/
    static let imagesDir: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pasta/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var imageFileURL: URL { Self.imagesDir.appendingPathComponent("\(id.uuidString).png") }

    /// 图片二进制：优先运行时内存 → NSCache → 磁盘文件。
    var imageBytes: Data? {
        guard kind == .image else { return nil }
        if let imageData { return imageData }
        let key = id as NSUUID
        if let cached = ClipCaches.imageBlobs.object(forKey: key) { return cached as Data }
        guard let data = try? Data(contentsOf: imageFileURL) else { return nil }
        ClipCaches.imageBlobs.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    /// 删除该记录时清理缓存（文件删除由 ClipboardStore 负责）。
    static func purgeCaches(id: UUID) { ClipCaches.purge(id: id) }

    /// 图片字节数：内存有数据直接取，否则 stat 磁盘文件（微秒级，不读内容）。
    /// 去重判等的廉价先决条件——没有它，每复制一张新图都会把历史图片全量读盘。
    var imageByteCount: Int? {
        guard kind == .image else { return nil }
        if let imageData { return imageData.count }
        let attrs = try? FileManager.default.attributesOfItem(atPath: imageFileURL.path)
        return (attrs?[.size] as? NSNumber)?.intValue
    }

    /// 用于去重的内容判等（忽略 id / date / pinned / 富文本差异）。
    func sameContent(as other: ClipItem) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .text, .file:
            return text == other.text
        case .image:
            guard imageByteCount == other.imageByteCount else { return false }   // 先比大小，免读盘
            return imageBytes == other.imageBytes
        }
    }

    /// 搜索用的纯文本。图片附带 OCR 识别文本——截图可以按内容搜到。
    var searchText: String {
        switch kind {
        case .text, .file:
            return text ?? ""
        case .image:
            if let ocr = ocrText, !ocr.isEmpty { return "图片 image " + ocr }
            return "图片 image"
        }
    }

    /// 拼音索引（全拼 + 首字母，均小写）：CFStringTransform 系统转换，零依赖。
    /// 汉字逐字成音节（首字母逐字取），英文词原样保留。只取前 512 字符，按 id 缓存。
    /// 多音字取系统默认读音（如「长」固定 zhang 或 chang）——可接受的已知局限。
    var pinyinIndex: (full: String, initials: String) {
        let key = id as NSUUID
        if let cached = ClipCaches.pinyins.object(forKey: key) as? [String], cached.count == 2 {
            return (cached[0], cached[1])
        }
        let m = NSMutableString(string: String(searchText.prefix(512)))
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let words = (m as String).lowercased().split { !($0.isLetter || $0.isNumber) }
        let full = words.joined()
        let initials = words.compactMap { $0.first.map(String.init) }.joined()
        ClipCaches.pinyins.setObject([full, initials] as NSArray, forKey: key)
        return (full, initials)
    }

    /// 面板搜索匹配：原文子串命中；查询为纯 ASCII 字母数字时叠加拼音全拼/首字母匹配
    /// （「jtb」「jiantieban」都能找到「剪贴板」）。query 需已 lowercased。
    func matches(_ query: String) -> Bool {
        if searchText.lowercased().contains(query) { return true }
        guard query.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let py = pinyinIndex
        return py.full.contains(query) || py.initials.contains(query)
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

    /// 「M月d日」格式化器进程级复用：DateFormatter 创建毫秒级，
    /// 全量重建卡片时每张旧卡新建一个会直接吃掉入场动画的帧预算。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    /// 列表右侧显示的相对时间。
    var relativeTime: String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        if s < 172800 { return "昨天" }
        return Self.dayFormatter.string(from: date)
    }

    /// 图片像素尺寸：用 ImageIO 只读元数据，不整图解码；按 id 缓存。
    var imageSize: NSSize? {
        guard kind == .image else { return nil }
        if let s = ClipCaches.imageSizes.object(forKey: id as NSUUID) { return s.sizeValue }
        guard let data = imageBytes,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let size = NSSize(width: w, height: h)
        ClipCaches.imageSizes.setObject(NSValue(size: size), forKey: id as NSUUID)
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

    /// 列表行的缩略图（仅图片有）。用 ImageIO 生成降采样缩略图（不整图解码）并按 id 缓存。
    var thumbnail: NSImage? {
        guard kind == .image else { return nil }
        let key = id as NSUUID
        if let cached = ClipCaches.thumbnails.object(forKey: key) { return cached }
        guard let data = imageBytes else { return nil }
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
