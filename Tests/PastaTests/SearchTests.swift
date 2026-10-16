import XCTest
@testable import Pasta

final class SearchTests: XCTestCase {
    // 等价类：文本/文件/OCR；中文/拼音/首字母/ASCII/标点/Unicode；512 字边界。
    func testMatchingKeepsExistingRules() {
        let text = ClipItem(kind: .text, text: "剪贴板 Hello WORLD 🐈")
        let file = ClipItem(kind: .file, text: "/Users/demo/设计稿.pdf")
        var image = ClipItem(kind: .image)
        image.ocrText = "会议记录 Project Alpha"
        let cases: [(ClipItem, String, Bool)] = [
            (text, "剪贴", true), (text, "jiantieban", true), (text, "jtb", true),
            (text, "world", true), (text, "🐈", true), (text, "missing", false),
            (text, "jian tie", false), (file, "设计稿.pdf", true), (file, "shejigao", true),
            (image, "image", true), (image, "会议", true), (image, "hyjl", true),
            (image, "project alpha", true), (image, "absent", false),
            (ClipItem(kind: .text, text: "İSTANBUL café"), "i̇stanbul", true),
            (ClipItem(kind: .text, text: nil), "abc", false),
        ]
        for (item, query, expected) in cases {
            XCTAssertEqual(item.matches(query), expected, "query=\(query)")
        }
        let long = ClipItem(kind: .text, text: String(repeating: "x", count: 512) + "剪贴板")
        XCTAssertTrue(long.matches("剪贴板"), "原文匹配不能受拼音 512 字上限影响")
        XCTAssertFalse(long.matches("jiantieban"))
    }

    func testIndexFollowsValueCopiesAndOCRChanges() {
        var original = ClipItem(kind: .image)
        original.ocrText = "苹果"
        XCTAssertTrue(original.matches("pingguo"))
        var updated = original
        updated.ocrText = "香蕉"
        XCTAssertTrue(updated.matches("xiangjiao"))
        XCTAssertFalse(updated.matches("pingguo"))
        XCTAssertTrue(original.matches("pingguo"), "后台旧快照必须仍匹配自己的内容")
        var text = ClipItem(kind: .text, text: "旧记录")
        XCTAssertTrue(text.matches("jiujilu"))
        text.text = "新记录"
        XCTAssertTrue(text.matches("xinjilu"))
        XCTAssertFalse(text.matches("jiujilu"))
    }

    func testOnlyLatestQueryCompletes() {
        let search = ClipSearch()
        let items = [ClipItem(kind: .text, text: "苹果"), ClipItem(kind: .text, text: "香蕉")]
        let stale = expectation(description: "旧查询不应回填")
        stale.isInverted = true
        let latest = expectation(description: "最新查询")
        search.search(items, query: "pingguo") { _ in stale.fulfill() }
        search.search(items, query: "xiangjiao") { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.map(\.id), [items[1].id])
            latest.fulfill()
        }
        wait(for: [latest, stale], timeout: 0.3)
    }

    func testCancelPreventsCompletion() {
        let search = ClipSearch()
        let canceled = expectation(description: "关闭或清空查询后不应回填")
        canceled.isInverted = true
        search.search([ClipItem(kind: .text, text: "剪贴板")], query: "jtb") { _ in canceled.fulfill() }
        search.cancel()
        wait(for: [canceled], timeout: 0.1)
    }

    func testConcurrentWarmupAndSearchPreserveOrder() {
        let items = (0..<1300).map { ClipItem(kind: .text, text: "剪贴板编号\($0)") }
        let warm = expectation(description: "预热")
        DispatchQueue.global().async {
            items.forEach { _ = $0.pinyinIndex }
            warm.fulfill()
        }
        let search = ClipSearch()
        let done = expectation(description: "后台全量搜索")
        search.search(items, query: "jtb") { result in
            XCTAssertEqual(result.map(\.id), items.map(\.id))
            done.fulfill()
        }
        wait(for: [warm, done], timeout: 5)
    }
}
