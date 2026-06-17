import AppKit

/// 历史记录的内存模型 + 本地持久化。
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let maxItems = 200          // 非置顶记录的上限
    private let maxImageBytes = 8 * 1024 * 1024
    private let fileURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pasta", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("history.json")
        load()
        purgeExpiredInternal()
    }

    /// 置顶在前、其余按时间倒序，用于面板展示。
    var displayItems: [ClipItem] {
        items.filter { $0.pinned } + items.filter { !$0.pinned }
    }

    func add(_ newItem: ClipItem) {
        if newItem.kind == .image, (newItem.imageData?.count ?? 0) > maxImageBytes {
            // 超大图片不入库，避免历史文件膨胀。
        }
        purgeExpiredInternal()
        if let idx = items.firstIndex(where: { $0.sameContent(as: newItem) }) {
            // 已存在 -> 提到最前，保留置顶状态，刷新时间。
            var existing = items.remove(at: idx)
            existing.date = Date()
            items.insert(existing, at: 0)
        } else {
            items.insert(newItem, at: 0)
        }
        trim()
        save()
        onChange?()
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        save()
        onChange?()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func clear() {
        items.removeAll { !$0.pinned }   // 保留置顶项
        save()
        onChange?()
    }

    /// 按过期设置清理非置顶的旧记录（外部/定时调用，会通知刷新）。
    func purgeExpired() {
        if purgeExpiredInternal() {
            save()
            onChange?()
        }
    }

    @discardableResult
    private func purgeExpiredInternal() -> Bool {
        let days = Settings.shared.expirationDays
        guard days > 0 else { return false }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let before = items.count
        items.removeAll { !$0.pinned && $0.date < cutoff }
        return items.count != before
    }

    private func trim() {
        var kept = 0
        items = items.filter { item in
            if item.pinned { return true }
            if kept < maxItems { kept += 1; return true }
            return false
        }
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Pasta: 保存历史失败 \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = decoded
        }
    }
}
