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
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 我们自己往剪贴板写入时调用，避免把自己写入的内容又当成新历史。
    func suppressNextChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let item = readPasteboard() else { return }
        store.add(item)
    }

    private func readPasteboard() -> ClipItem? {
        let types = pasteboard.types ?? []

        // 跳过密码管理器等标记为「隐藏/瞬态」的内容。
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return nil }
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return nil }

        // 复制来源 App（排除我们自己）
        var src = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if src == Bundle.main.bundleIdentifier { src = nil }

        // 1. 文本（同时抓取富文本版本，供「保留格式」粘贴用）
        if let str = pasteboard.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rtf = pasteboard.data(forType: .rtf)
            return ClipItem(kind: .text, text: str, rtfData: rtf, sourceBundleID: src)
        }

        // 2. 文件（Finder 复制）
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: "\n")
            return ClipItem(kind: .file, text: paths, sourceBundleID: src)
        }

        // 3. 图片
        if let img = NSImage(pasteboard: pasteboard), let png = img.pngData() {
            return ClipItem(kind: .image, imageData: png, sourceBundleID: src)
        }

        return nil
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
