import Foundation
import SQLite3

/// 持久层 v3：SQLite 元数据 + FTS5 索引（EcoPaste 同构：库存元数据，大对象外置文件）。
/// 零依赖，直接用系统 libsqlite3。所有调用必须在同一个串行队列上（ClipboardStore.dbQueue）。
///
/// 设计要点：
/// - rtf 存 BLOB 但不随 loadAll 返回（粘贴时按需单查），避免大血包常驻内存
/// - 图片仍走 images/<id>.png 外置文件，库里只有元数据
/// - FTS5 用 trigram tokenizer（CJK 子串匹配需要它；unicode61 对中文只会整段成词）；
///   运行时探测，建不了（老系统）就置 ftsAvailable=false，搜索由上层内存过滤兜底
final class HistoryDB {
    private var db: OpaquePointer?
    private(set) var ftsAvailable = false
    private let url: URL

    /// SQLITE_TRANSIENT：告诉 SQLite 立即拷贝绑定的内存（Swift 闭包指针转换写法）
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        self.url = url
        if !open() {
            // 损坏兜底：保留现场改名，重建空库——绝不覆盖用户数据
            sqlite3_close(db); db = nil
            let ts = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-\(ts)"))
            NSLog("Pasta: history.db 打开失败，已保留现场为 .corrupt-\(ts)，重建空库")
            guard open() else { return nil }
        }
        restrictPermissions()
    }

    deinit { sqlite3_close(db) }

    private func open() -> Bool {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return false }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        guard exec("""
            CREATE TABLE IF NOT EXISTS items (
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              text TEXT,
              rtf BLOB,
              pinned INTEGER NOT NULL DEFAULT 0,
              date REAL NOT NULL,
              source_bundle_id TEXT,
              ocr_text TEXT
            )
            """),
            exec("CREATE INDEX IF NOT EXISTS idx_items_date ON items(date DESC)")
        else { return false }
        // v3 早期库无 ocr_text 列：就地补列（幂等）
        if !columnExists("ocr_text", table: "items") {
            _ = exec("ALTER TABLE items ADD COLUMN ocr_text TEXT")
        }
        // 收藏时间列（常用页按它排序，位置稳定不随复制扰动）；存量收藏用当前 date 冻结为收藏时间
        if !columnExists("pinned_at", table: "items") {
            _ = exec("ALTER TABLE items ADD COLUMN pinned_at REAL")
            _ = exec("UPDATE items SET pinned_at = date WHERE pinned = 1 AND pinned_at IS NULL")
        }
        // FTS 是增强不是前提：trigram 不可用时静默降级
        ftsAvailable = exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts
            USING fts5(text, content='items', content_rowid='rowid', tokenize='trigram')
            """)
        if ftsAvailable {
            _ = exec("CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN INSERT INTO items_fts(rowid, text) VALUES (new.rowid, new.text); END")
            _ = exec("CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END")
            _ = exec("CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF text ON items BEGIN INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.rowid, old.text); INSERT INTO items_fts(rowid, text) VALUES (new.rowid, new.text); END")
        }
        return true
    }

    /// 剪贴历史可能含敏感文本：库文件（含 WAL/SHM）仅本用户可读
    private func restrictPermissions() {
        for suffix in ["", "-wal", "-shm"] {
            let p = url.path + suffix
            if FileManager.default.fileExists(atPath: p) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { NSLog("Pasta: SQL 失败 \(String(cString: err)) — \(sql.prefix(60))") }
            sqlite3_free(err)
            return false
        }
        return true
    }

    private func columnExists(_ column: String, table: String, schema: String = "main") -> Bool {
        guard let s = prepare("SELECT COUNT(*) FROM \(schema).pragma_table_info('\(table)') WHERE name=?") else { return false }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, column, -1, Self.transient)
        return sqlite3_step(s) == SQLITE_ROW && sqlite3_column_int(s, 0) > 0
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Pasta: SQL 编译失败 \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(60))")
            return nil
        }
        return stmt
    }

    // MARK: - CRUD

    func insert(_ item: ClipItem) {
        guard let s = prepare("INSERT OR REPLACE INTO items (id,kind,text,rtf,pinned,date,source_bundle_id,ocr_text,pinned_at) VALUES (?,?,?,?,?,?,?,?,?)") else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, item.id.uuidString, -1, Self.transient)
        sqlite3_bind_text(s, 2, item.kind.rawValue, -1, Self.transient)
        if let t = item.text { sqlite3_bind_text(s, 3, t, -1, Self.transient) } else { sqlite3_bind_null(s, 3) }
        if let r = item.rtfData {
            _ = r.withUnsafeBytes { sqlite3_bind_blob(s, 4, $0.baseAddress, Int32(r.count), Self.transient) }
        } else { sqlite3_bind_null(s, 4) }
        sqlite3_bind_int(s, 5, item.pinned ? 1 : 0)
        sqlite3_bind_double(s, 6, item.date.timeIntervalSince1970)
        if let b = item.sourceBundleID { sqlite3_bind_text(s, 7, b, -1, Self.transient) } else { sqlite3_bind_null(s, 7) }
        if let o = item.ocrText { sqlite3_bind_text(s, 8, o, -1, Self.transient) } else { sqlite3_bind_null(s, 8) }
        if let p = item.pinnedAt { sqlite3_bind_double(s, 9, p.timeIntervalSince1970) } else { sqlite3_bind_null(s, 9) }
        sqlite3_step(s)
        restrictPermissions()   // WAL/SHM 可能在首写时才出现
    }

    /// 图片 OCR 完成后落库。
    func updateOCR(id: UUID, text: String) {
        guard let s = prepare("UPDATE items SET ocr_text=? WHERE id=?") else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, text, -1, Self.transient)
        sqlite3_bind_text(s, 2, id.uuidString, -1, Self.transient)
        sqlite3_step(s)
    }

    /// 尚未 OCR 的图片记录 id（启动回填用）。
    func pendingOCRIDs() -> [UUID] {
        guard let s = prepare("SELECT id FROM items WHERE kind='image' AND (ocr_text IS NULL OR ocr_text='')") else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [UUID] = []
        while sqlite3_step(s) == SQLITE_ROW {
            if let str = sqlite3_column_text(s, 0).map({ String(cString: $0) }), let id = UUID(uuidString: str) {
                out.append(id)
            }
        }
        return out
    }

    func updatePinned(id: UUID, pinned: Bool, pinnedAt: Date?) {
        guard let s = prepare("UPDATE items SET pinned=?, pinned_at=? WHERE id=?") else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, pinned ? 1 : 0)
        if let p = pinnedAt { sqlite3_bind_double(s, 2, p.timeIntervalSince1970) } else { sqlite3_bind_null(s, 2) }
        sqlite3_bind_text(s, 3, id.uuidString, -1, Self.transient)
        sqlite3_step(s)
    }

    /// 去重命中：同内容重新复制 → 只刷新时间
    func touch(id: UUID, date: Date) {
        guard let s = prepare("UPDATE items SET date=? WHERE id=?") else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(s, 2, id.uuidString, -1, Self.transient)
        sqlite3_step(s)
    }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty, let s = prepare("DELETE FROM items WHERE id=?") else { return }
        defer { sqlite3_finalize(s) }
        for id in ids {
            sqlite3_bind_text(s, 1, id.uuidString, -1, Self.transient)
            sqlite3_step(s)
            sqlite3_reset(s)
        }
    }

    func deleteAllUnpinned() {
        exec("DELETE FROM items WHERE pinned=0")
    }

    /// 全量加载元数据（不含 rtf，按时间倒序）。仅启动时调用一次。
    func loadAll() -> [ClipItem] {
        guard let s = prepare("SELECT id,kind,text,pinned,date,source_bundle_id,ocr_text,pinned_at FROM items ORDER BY date DESC") else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [ClipItem] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(s, 0).map({ String(cString: $0) }),
                  let id = UUID(uuidString: idStr),
                  let kindStr = sqlite3_column_text(s, 1).map({ String(cString: $0) }),
                  let kind = ClipItem.Kind(rawValue: kindStr) else { continue }
            var item = ClipItem(
                id: id, kind: kind,
                text: sqlite3_column_text(s, 2).map { String(cString: $0) },
                pinned: sqlite3_column_int(s, 3) != 0,
                date: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                sourceBundleID: sqlite3_column_text(s, 5).map { String(cString: $0) })
            item.ocrText = sqlite3_column_text(s, 6).map { String(cString: $0) }
            if sqlite3_column_type(s, 7) != SQLITE_NULL {
                item.pinnedAt = Date(timeIntervalSince1970: sqlite3_column_double(s, 7))
            }
            out.append(item)
        }
        return out
    }

    /// 按需取单条 rtf（粘贴「保留格式」时用）。
    func rtfData(id: UUID) -> Data? {
        guard let s = prepare("SELECT rtf FROM items WHERE id=?") else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id.uuidString, -1, Self.transient)
        guard sqlite3_step(s) == SQLITE_ROW, let blob = sqlite3_column_blob(s, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(s, 0)))
    }

    var isEmpty: Bool {
        guard let s = prepare("SELECT COUNT(*) FROM items") else { return true }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int(s, 0) == 0 : true
    }

    // MARK: - 备份

    /// 把 WAL 合并回主库文件：导出前调用，保证单个 .db 文件即完整数据。
    func checkpoint() {
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// 从另一份 Pasta 备份库合并记录（按 id 去重，已存在的跳过）。返回新增条数。
    func merge(from dbPath: String) -> Int {
        guard let a = prepare("ATTACH DATABASE ? AS src") else { return 0 }
        sqlite3_bind_text(a, 1, dbPath, -1, Self.transient)
        let attached = sqlite3_step(a) == SQLITE_DONE
        sqlite3_finalize(a)
        guard attached else { return 0 }
        defer { exec("DETACH DATABASE src") }
        // 旧版备份包可能缺 ocr_text / pinned_at 列：按来源实际 schema 组列清单
        var cols = "id,kind,text,rtf,pinned,date,source_bundle_id"
        if columnExists("ocr_text", table: "items", schema: "src") { cols += ",ocr_text" }
        if columnExists("pinned_at", table: "items", schema: "src") { cols += ",pinned_at" }
        guard exec("INSERT OR IGNORE INTO items (\(cols)) SELECT \(cols) FROM src.items") else { return 0 }
        return Int(sqlite3_changes(db))
    }
}
