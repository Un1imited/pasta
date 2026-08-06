import AppKit

/// 历史记录的内存模型 + 本地持久化。
///
/// 持久化 v3（EcoPaste 同构）：SQLite 存元数据 + rtf（history.db，WAL），
/// 图片二进制外置 images/<id>.png。内存里只保留展示/搜索所需的元数据，
/// rtf / 图片入库后即从内存释放，粘贴时按需回读。
/// v2（history.json + 图片外置）与 v1（裸数组、图片内联）在首启时自动迁移，
/// 原 JSON 保留为 history.json.v2.bak。
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let maxItems = 1000         // 非置顶记录上限（v3：SQLite 增量写，上限不再受整文件重写约束）
    private let maxImageBytes = 8 * 1024 * 1024
    private let dbURL: URL
    private let jsonURL: URL            // 仅迁移用
    private var db: HistoryDB?
    /// 所有 DB 写操作的串行队列；读在启动时同步做一次
    private let dbQueue = DispatchQueue(label: "com.local.pasta.db", qos: .utility)

    /// 迁移解码用（v2 信封格式）
    private struct HistoryFile: Codable {
        var version: Int
        var items: [ClipItem]
    }

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pasta", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        dbURL = support.appendingPathComponent("history.db")
        jsonURL = support.appendingPathComponent("history.json")
        _ = ClipItem.imagesDir                       // 确保图片目录存在
        Self.excludeFromBackup(support)              // 剪贴历史不进 Time Machine：备份会让敏感内容永久化

        db = HistoryDB(url: dbURL)
        if db == nil { NSLog("Pasta: 数据库不可用，本次会话仅内存运行") }
        migrateFromJSONIfNeeded()
        items = db?.loadAll() ?? []
        purgeExpiredInternal()
        sweepOrphanImages()

        // 拼音索引预热：避免首次搜索时为全部条目同时算拼音卡一拍（NSCache 线程安全）
        let snapshot = items
        DispatchQueue.global(qos: .utility).async { snapshot.forEach { _ = $0.pinyinIndex } }
    }

    /// 单实例守护：对锁文件加排他 flock。返回 false 表示已有另一个 Pasta
    /// （App 或 `swift run`）在运行——双实例会竞写同一份历史库。
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
            let id = existing.id, date = existing.date
            dbQueue.async { [weak self] in self?.db?.touch(id: id, date: date) }
        } else {
            items.insert(newItem, at: 0)
            let persisted = newItem      // 值拷贝：带 rtf / 图片二进制进队列
            dbQueue.async { [weak self] in
                guard let self else { return }
                self.persistImage(of: persisted)
                self.db?.insert(persisted)
                // 入库后释放内存里的大血包（图片从文件回读、rtf 从库回读）
                DispatchQueue.main.async { self.freeHeavyBlobs(id: persisted.id) }
            }
        }
        trim()
        onChange?()
    }

    /// 入库完成后释放该条目的 rtf / 图片内存（持久层已可回读）。
    private func freeHeavyBlobs(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].rtfData = nil
        items[idx].imageData = nil
    }

    /// 粘贴「保留格式」时按需回读 rtf（内存里不再常驻）。
    func rtfData(for id: UUID) -> Data? {
        dbQueue.sync { db?.rtfData(id: id) }
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        let pinned = items[idx].pinned
        dbQueue.async { [weak self] in self?.db?.updatePinned(id: id, pinned: pinned) }
        onChange?()
    }

    /// 最近一次删除的缓冲，供 ⌘Z 撤销。图片文件在缓冲期间保留，
    /// 直到被下一次删除顶替（或进程退出后由下次启动的孤儿清扫回收）。
    private var lastDeleted: (item: ClipItem, index: Int)?

    func delete(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let old = lastDeleted { removeArtifacts(of: old.item) }   // 顶替旧缓冲时才真正清理
        var buffered = items[idx]
        buffered.rtfData = rtfData(for: id)   // 撤销要能整条恢复：删行前先把 rtf 捞回缓冲
        lastDeleted = (buffered, idx)
        items.remove(at: idx)
        dbQueue.async { [weak self] in self?.db?.delete(ids: [id]) }
        onChange?()
    }

    /// 撤销最近一次删除，恢复到原位置。返回恢复的条目（无可撤销时为 nil）。
    @discardableResult
    func undeleteLast() -> ClipItem? {
        guard let (item, idx) = lastDeleted else { return nil }
        lastDeleted = nil
        items.insert(item, at: min(idx, items.count))
        dbQueue.async { [weak self] in
            self?.db?.insert(item)
            DispatchQueue.main.async { self?.freeHeavyBlobs(id: item.id) }
        }
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
        dbQueue.async { [weak self] in self?.db?.deleteAllUnpinned() }
        onChange?()
    }

    /// 按过期设置清理非置顶的旧记录（外部/定时调用，会通知刷新）。
    func purgeExpired() {
        if purgeExpiredInternal() {
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
        let ids = expired.map { $0.id }
        dbQueue.async { [weak self] in self?.db?.delete(ids: ids) }
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
        guard !dropped.isEmpty else { return }
        dropped.forEach(removeArtifacts)
        let ids = dropped.map { $0.id }
        dbQueue.async { [weak self] in self?.db?.delete(ids: ids) }
    }

    /// 退出前排空在途的数据库写（每笔写本就即时提交，这里只等队列清空）。
    func flush() {
        dbQueue.sync {}
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

    // MARK: - v1/v2 → v3 迁移

    /// 库为空且存在 history.json 时执行一次性迁移；原文件保留 .v2.bak 供回滚。
    /// v1（裸数组、图片内联）与 v2（信封、图片外置）都能吃。
    private func migrateFromJSONIfNeeded() {
        guard let db, db.isEmpty,
              let data = try? Data(contentsOf: jsonURL) else { return }
        let dec = JSONDecoder()
        let migrated: [ClipItem]
        if let file = try? dec.decode(HistoryFile.self, from: data) {
            migrated = file.items
        } else if let legacy = try? dec.decode([ClipItem].self, from: data) {
            migrated = legacy
        } else {
            // 损坏：保留现场，从空库启动；不动图片目录（现场 json 可能还引用它们）
            let ts = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: jsonURL, to: jsonURL.appendingPathExtension("corrupt-\(ts)"))
            NSLog("Pasta: history.json 解码失败，已保留现场，从空库启动")
            return
        }
        for item in migrated {
            if item.kind == .image, item.imageData != nil { persistImage(of: item) }  // v1 内联图片落盘
            db.insert(item)
        }
        try? FileManager.default.moveItem(at: jsonURL, to: jsonURL.appendingPathExtension("v2.bak"))
        NSLog("Pasta: 历史已迁移到 SQLite（\(migrated.count) 条；原 JSON 保留为 history.json.v2.bak）")
    }

    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
