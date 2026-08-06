import AppKit

/// 轮询系统剪贴板（NSPasteboard 没有变更通知，只能轮询 changeCount）。
final class ClipboardMonitor {
    private let store: ClipboardStore
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.1   // 允许系统合并定时器唤醒，省电
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 内置敏感来源：从这些 App 复制的内容一律不入历史
    /// （多数密码管理器会打 Concealed 标记，这里是双保险）。
    /// 全部小写：比较侧已 lowercased，任何大写字母都会导致永不命中。
    private static let sensitiveSources = [
        "com.1password.1password", "com.agilebits.onepassword",
        "org.keepassxc.keepassxc", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.passwords",
    ]

    /// 我们自己往剪贴板写入时调用，避免把自己写入的内容又当成新历史。
    func suppressNextChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        readPasteboard()
    }

    private func readPasteboard() {
        let types = pasteboard.types ?? []

        // 跳过密码管理器等标记为「隐藏/瞬态」的内容。
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return }
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        // 接力（通用剪贴板）：iPhone/iPad 复制的内容默认不记——
        // iOS 端的 Concealed 标记不会跨设备传递，接力是敏感内容进历史的旁路（偏好可关）。
        if Settings.shared.ignoreRemoteClipboard,
           types.contains(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")) { return }

        // 复制来源 App（排除我们自己；密码管理器等敏感来源整体跳过）
        var src = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if src == Bundle.main.bundleIdentifier { src = nil }
        if let s = src?.lowercased(),
           Self.sensitiveSources.contains(where: { s.hasPrefix($0) }) { return }
        // 用户配置的忽略来源（偏好设置 → 忽略应用）
        if let s = src?.lowercased(), Settings.shared.ignoredApps.contains(s) { return }

        // 1. 文件（Finder 复制）——必须先于文本判断：
        //    Finder 复制文件时剪贴板同时带文件名字符串，文本分支在前会把文件截胡成纯文本。
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: "\n")
            store.add(ClipItem(kind: .file, text: paths, sourceBundleID: src))
            return
        }

        // 2. 文本（同时抓取富文本版本，供「保留格式」粘贴用）
        if let str = pasteboard.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rtf = pasteboard.data(forType: .rtf)
            store.add(ClipItem(kind: .text, text: str, rtfData: rtf, sourceBundleID: src))
            return
        }

        // 3. 图片：原始字节在主线程取（剪贴板访问），解码 + PNG 重编码是重活，
        //    移到后台再回主线程入库——否则复制大图后 0.4s 内唤起面板，
        //    热键回调会排在整图转码之后，表现为偶发卡顿。
        let png = pasteboard.data(forType: .png)
        let tiff = png == nil ? pasteboard.data(forType: .tiff) : nil
        // 罕见类型（PDF 矢量等）兜底：光栅化仍在主线程，仅此低频路径
        let rasterized = (png == nil && tiff == nil)
            ? NSImage(pasteboard: pasteboard)?.tiffRepresentation : nil
        guard png != nil || tiff != nil || rasterized != nil else { return }
        let source = src
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data: Data?
            if let png {
                data = png                            // 已是 PNG，零转码
            } else if let raw = tiff ?? rasterized, let rep = NSBitmapImageRep(data: raw) {
                data = rep.representation(using: .png, properties: [:])
            } else {
                data = nil
            }
            guard let self, let data else { return }
            DispatchQueue.main.async {
                self.store.add(ClipItem(kind: .image, imageData: data, sourceBundleID: source))
            }
        }
    }
}
