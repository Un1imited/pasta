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

        // 后台预热：拼音索引（避免首次搜索卡一拍）+ 渲染区内图片的缩略图
        // （避免首次唤起时面板边建卡边解码；NSCache 线程安全）
        let snapshot = items
        DispatchQueue.global(qos: .utility).async {
            snapshot.forEach { _ = $0.pinyinIndex }
            snapshot.prefix(300).filter { $0.kind == .image }.prefix(40).forEach { _ = $0.thumbnail }
        }

        // 历史图片的 OCR 回填：逐张排进 OCR 串行低优先级队列（文件读取也在该队列上）
        for id in db?.pendingOCRIDs() ?? [] {
            if let item = items.first(where: { $0.id == id }) { scheduleOCR(for: item) }
        }
    }

    // MARK: - OCR（图片文字进搜索索引）

    /// 图片入库/回填时排一次本地文字识别；识别到内容才更新（无文字的图不反复重试本次会话内已处理）。
    private func scheduleOCR(for item: ClipItem) {
        guard item.kind == .image else { return }
        let id = item.id
        let mem = item.imageData
        let file = item.imageFileURL
        OCRService.recognize(provider: { mem ?? (try? Data(contentsOf: file)) }) { [weak self] text in
            guard let text else { return }
            DispatchQueue.main.async { self?.applyOCR(id: id, text: text) }
        }
    }

    private func applyOCR(id: UUID, text: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].ocrText = text }
        ClipItem.purgeSearchIndex(id: id)   // searchText 变了，重建拼音索引
        dbQueue.async { [weak self] in self?.db?.updateOCR(id: id, text: text) }
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
            scheduleOCR(for: newItem)   // 图片：本地文字识别进搜索索引
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

    /// 容量设置变更后按新上限收缩（AppDelegate 监听设置变化调用）。
    func applyHistoryLimit() {
        let before = items.count
        trim()
        if items.count != before { onChange?() }
    }

    private func trim() {
        let limit = Settings.shared.maxHistoryItems   // 非收藏上限（偏好可调 500–5000）
        var kept = 0
        var dropped: [ClipItem] = []
        items = items.filter { item in
            if item.pinned { return true }
            if kept < limit { kept += 1; return true }
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

    // MARK: - 备份导出 / 导入

    /// 导出备份 zip：history.db（checkpoint 后的完整单文件）+ images/ 目录。
    func exportBackup(to dest: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try dbQueue.sync {
            db?.checkpoint()   // WAL 合并回主文件，单个 .db 即完整数据
            try FileManager.default.copyItem(at: dbURL, to: staging.appendingPathComponent("history.db"))
        }
        try FileManager.default.copyItem(at: ClipItem.imagesDir,
                                         to: staging.appendingPathComponent("images"))

        try? FileManager.default.removeItem(at: dest)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", staging.path, dest.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "Pasta", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "压缩备份失败（ditto 退出码 \(ditto.terminationStatus)）"])
        }
    }

    /// 导入备份 zip：按 id 合并（已存在的记录跳过，不覆盖现有历史），图片文件补拷贝。
    /// 返回新增条数。
    func importBackup(from zip: URL) throws -> Int {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "Pasta", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "解压失败：不是有效的 zip 文件"])
        }
        let srcDB = staging.appendingPathComponent("history.db")
        guard FileManager.default.fileExists(atPath: srcDB.path) else {
            throw NSError(domain: "Pasta", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "备份包里没有 history.db——不是 Pasta 备份"])
        }

        let added = dbQueue.sync { db?.merge(from: srcDB.path) ?? 0 }

        // 图片：只补缺，不覆盖本机已有文件
        let srcImages = staging.appendingPathComponent("images")
        if let files = try? FileManager.default.contentsOfDirectory(at: srcImages, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "png" {
                let target = ClipItem.imagesDir.appendingPathComponent(f.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.copyItem(at: f, to: target)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
            }
        }

        // 重载内存模型（保序去重后的全量），面板经 onChange 刷新
        items = dbQueue.sync { db?.loadAll() ?? [] }
        trim()
        onChange?()
        // 旧备份合并进来的图片可能没有 OCR：补排识别
        for id in dbQueue.sync(execute: { db?.pendingOCRIDs() ?? [] }) {
            if let item = items.first(where: { $0.id == id }) { scheduleOCR(for: item) }
        }
        return added
    }

    /// 自动备份的当前记录数（AppDelegate 提示用）。
    var count: Int { items.count }

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
