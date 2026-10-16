import XCTest
@testable import Pasta

final class PendingQuickPasteTests: XCTestCase {
    // 回车：首屏/非首项/刷新后位置变化；⌘数字：首槽/第九槽；空结果/越界；格式标记。
    func testReturnUsesSelectionRestoredAfterAsyncSearch() {
        let items = (0..<3).map { ClipItem(kind: .text, text: "匹配记录\($0)") }
        let selectedID = items[2].id
        let pending = PendingQuickPaste.selection(plain: false)
        let search = ClipSearch()
        let done = expectation(description: "刷新完成后粘贴原选中记录")

        // 模拟后台刷新前插入一条新记录，原选中项从第三条变成第四条。
        let refreshed = [ClipItem(kind: .text, text: "匹配新记录")] + items
        search.search(refreshed, query: "匹配") { result in
            let restoredIndex = result.firstIndex { $0.id == selectedID }!
            let target = pending.resolve(selectedIndex: restoredIndex, resultCount: result.count)
            XCTAssertEqual(target?.index, 3)
            XCTAssertEqual(target.map { result[$0.index].id }, selectedID)
            XCTAssertEqual(target?.plain, false)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    func testReturnUsesFirstResultWhenSelectionResetsForNewQuery() {
        let target = PendingQuickPaste.selection(plain: true)
            .resolve(selectedIndex: 0, resultCount: 3)
        XCTAssertEqual(target?.index, 0)
        XCTAssertEqual(target?.plain, true)
    }

    func testCommandDigitKeepsRequestedSlotRegardlessOfRestoredSelection() {
        for index in [0, 8] {
            for plain in [false, true] {
                let target = PendingQuickPaste.index(index, plain: plain)
                    .resolve(selectedIndex: 3, resultCount: 9)
                XCTAssertEqual(target?.index, index)
                XCTAssertEqual(target?.plain, plain)
            }
        }
    }

    func testMissingTargetDoesNotFallBackToFirstResult() {
        XCTAssertNil(PendingQuickPaste.selection(plain: false)
            .resolve(selectedIndex: 0, resultCount: 0))
        XCTAssertNil(PendingQuickPaste.selection(plain: false)
            .resolve(selectedIndex: 3, resultCount: 3))
        XCTAssertNil(PendingQuickPaste.index(8, plain: true)
            .resolve(selectedIndex: 0, resultCount: 8))
    }
}
