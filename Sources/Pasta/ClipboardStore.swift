import AppKit

/// 历史记录的内存模型 + 本地持久化。
///
/// 持久化格式 v2：history.json 只存元数据（带 version 信封），
/// 图片二进制外置到 images/<id>.png——避免 base64 膨胀与每次保存全量重编码。
/// v1（无信封的裸数组、图片内联）在 load 时自动迁移，原文件保留 .v1.bak。
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let maxItems = 200          // 非置顶记录的上限
    private let maxImageBytes = 8 * 1024 * 1024
    private static let schemaVersion = 2
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private struct HistoryFile: Codable {
        var version: Int
        var items: [ClipItem]
    }

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pasta", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("history.json")
        _ = ClipItem.imagesDir                       // 确保图片目录存在
        Self.excludeFromBackup(support)              // 剪贴历史不进 Time Machine：备份会让敏感内容永久化
        load()
        purgeExpiredInternal()
    }

    /// 单实例守护：对锁文件加排他 flock。返回 false 表示已有另一个 Pasta
    /// （App 或 `swift run`）在运行——双实例会竞写同一份 history.json。
    static func acquireSingleInstanceLock() -> Bool {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pasta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }           // 锁文件都打不开时不阻断启动
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }   // fd 故意不关，持锁到进程退出
        close(fd)
        return false
    }

    /// 按时间倒序（最近在前）用于面板展示。常用项不置顶到最前，仅在「常用」标签单独汇总。
    var displayItems: [ClipItem] {
        items
    }

    func add(_ newItem: ClipItem) {
        if newItem.kind == .image, (newItem.imageData?.count ?? 0) > maxImageBytes {
            return   // 超大图片不入库，避免历史膨胀。
        }
        purgeExpiredInternal()
        if let idx = items.firstIndex(where: { $0.sameContent(as: newItem) }) {
            // 已存在 -> 提到最前，保留置顶状态，刷新时间。
            var existing = items.remove(at: idx)
            existing.date = Date()
            items.insert(existing, at: 0)
        } else {
            persistImage(of: newItem)
            items.insert(newItem, at: 0)
        }
        trim()
        scheduleSave()
        onChange?()
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        scheduleSave()
        onChange?()
    }

    /// 最近一次删除的缓冲，供 ⌘Z 撤销。图片文件在缓冲期间保留，
    /// 直到被下一次删除顶替（或进程退出后由下次启动的孤儿清扫回收）。
    private var lastDeleted: (item: ClipItem, index: Int)?

    func delete(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let old = lastDeleted { removeArtifacts(of: old.item) }   // 顶替旧缓冲时才真正清理
        lastDeleted = (items[idx], idx)
        items.remove(at: idx)
        scheduleSave()
        onChange?()
    }

    /// 撤销最近一次删除，恢复到原位置。返回恢复的条目（无可撤销时为 nil）。
    @discardableResult
    func undeleteLast() -> ClipItem? {
        guard let (item, idx) = lastDeleted else { return nil }
        lastDeleted = nil
        items.insert(item, at: min(idx, items.count))
        scheduleSave()
        onChange?()
        return item
    }

    func clear() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }   // 保留置顶项
        removed.forEach(removeArtifacts)
        // 确认弹窗承诺"此操作不可撤销"：连同撤销缓冲一起清掉，语义一致
        if let old = lastDeleted {
            removeArtifacts(of: old.item)
            lastDeleted = nil
        }
        scheduleSave()
        onChange?()
    }

    /// 按过期设置清理非置顶的旧记录（外部/定时调用，会通知刷新）。
    func purgeExpired() {
        if purgeExpiredInternal() {
            scheduleSave()
            onChange?()
        }
    }

    @discardableResult
    private func purgeExpiredInternal() -> Bool {
        let days = Settings.shared.expirationDays
        guard days > 0 else { return false }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let expired = items.filter { !$0.pinned && $0.date < cutoff }
        guard !expired.isEmpty else { return false }
        items.removeAll { !$0.pinned && $0.date < cutoff }
        expired.forEach(removeArtifacts)
        return true
    }

    private func trim() {
        var kept = 0
        var dropped: [ClipItem] = []
        items = items.filter { item in
            if item.pinned { return true }
            if kept < maxItems { kept += 1; return true }
            dropped.append(item)
            return false
        }
        dropped.forEach(removeArtifacts)
    }

    // MARK: - 图片文件

    private func persistImage(of item: ClipItem) {
        guard item.kind == .image, let data = item.imageData else { return }
        do {
            try data.write(to: item.imageFileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: item.imageFileURL.path)
        } catch {
            NSLog("Pasta: 图片落盘失败 \(error)")   // 本次会话内仍有内存数据可用
        }
    }

    private func removeArtifacts(of item: ClipItem) {
        if item.kind == .image {
            try? FileManager.default.removeItem(at: item.imageFileURL)
        }
        ClipItem.purgeCaches(id: item.id)
    }

    /// 启动时回收无主图片文件（如撤销缓冲未消费就退出留下的）。
    private func sweepOrphanImages() {
        let ids = Set(items.map { $0.id.uuidString })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ClipItem.imagesDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "png"
            && !ids.contains(f.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - 持久化

    /// 写盘合并：0.5s 内的连续变更只落一次盘（复制高峰时避免每次全量重写）。
    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.saveNow()
            self?.saveWork = nil
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// 立即落盘挂起的变更（App 退出前调用）。
    func flush() {
        guard saveWork != nil else { return }
        saveWork?.cancel()
        saveWork = nil
        saveNow()
    }

    private func saveNow() {
        do {
            let data = try JSONEncoder().encode(HistoryFile(version: Self.schemaVersion, items: items))
            try data.write(to: fileURL, options: .atomic)
            // 剪贴历史可能含敏感文本：仅本用户可读
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Pasta: 保存历史失败 \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        if let file = try? dec.decode(HistoryFile.self, from: data) {
            items = file.items
        } else if let legacy = try? dec.decode([ClipItem].self, from: data) {
            // v1 → v2 迁移：内联图片落盘为独立文件；原文件保留 .v1.bak 供回滚
            try? FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("v1.bak"))
            items = legacy
            for item in items where item.kind == .image { persistImage(of: item) }
            saveNow()
            NSLog("Pasta: 历史已从 v1 迁移到 v2（图片外置；原文件保留为 history.json.v1.bak）")
        } else {
            // 损坏：保留现场，绝不让下一次 save 覆盖掉用户的历史。
            // 此时 items 为空，绝不能跑孤儿清扫——否则会把现场 json 引用的全部图片删光。
            let ts = Int(Date().timeIntervalSince1970)
            let corrupt = fileURL.appendingPathExtension("corrupt-\(ts)")
            try? FileManager.default.moveItem(at: fileURL, to: corrupt)
            NSLog("Pasta: history.json 解码失败，已保留现场为 \(corrupt.lastPathComponent)，从空历史启动")
            return
        }
        sweepOrphanImages()
    }

    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
