import Foundation

/// 每条记录持有自己的索引；值拷贝共享，正文/OCR 改变时换新，删除后随记录释放。
/// 不使用容量小于历史数的 NSCache，避免全量扫描时反复淘汰、重新转拼音。
final class ClipSearchIndex {
    private let lock = NSLock()
    private var normalized: String?
    private var pinyin: (full: String, initials: String)?

    func lowercased(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let normalized { return normalized }
        let value = text.lowercased()
        normalized = value
        return value
    }

    func pinyin(for text: String) -> (full: String, initials: String) {
        lock.lock()
        defer { lock.unlock() }
        if let pinyin { return pinyin }
        let m = NSMutableString(string: String(text.prefix(512)))
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let words = (m as String).lowercased().split { !($0.isLetter || $0.isNumber) }
        let value = (full: words.joined(), initials: words.compactMap { $0.first.map(String.init) }.joined())
        pinyin = value
        return value
    }
}

/// 搜索只处理值快照，后台过滤；新的查询、清空、隐藏都会取消旧批次。
/// completion 始终在主线程，且只允许当前查询回填 UI。
final class ClipSearch {
    private let queue = DispatchQueue(label: "com.local.pasta.search", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    @discardableResult
    func cancel() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    func search(_ items: [ClipItem], query: String, completion: @escaping ([ClipItem]) -> Void) {
        let token = cancel()
        queue.async { [self] in
            var result: [ClipItem] = []
            for item in items {
                guard isCurrent(token) else { return }
                if item.matches(query) { result.append(item) }
            }
            DispatchQueue.main.async { [self] in
                guard isCurrent(token) else { return }
                completion(result)
            }
        }
    }
}
