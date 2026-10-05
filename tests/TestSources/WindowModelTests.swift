import CoreGraphics
import XCTest

final class WindowModelTests: XCTestCase {

    // MARK: - 1. displayTitle：标题非空时原样展示

    func testDisplayTitleUsesTitleWhenNonEmpty() {
        let w = makeWindowModel(2001, title: "文稿 — Pages")
        XCTAssertEqual(w.displayTitle, "文稿 — Pages")
    }

    // MARK: - 2. displayTitle：标题为空时以「App 名 窗口」兜底（无权限场景）

    func testDisplayTitleFallsBackToOwnerName() {
        let w = makeWindowModel(2002, title: "")
        XCTAssertEqual(w.displayTitle, "TestApp 窗口")
    }

    // MARK: - 3. 相等性：仅按 windowID 判等，标题/bounds/isPinned 不参与

    func testEqualityByIDOnly() {
        var a = makeWindowModel(2003, title: "A")
        let b = makeWindowModel(2003, title: "完全不同的标题")
        a.isPinned = true
        XCTAssertEqual(a, b)
    }

    // MARK: - 4. 哈希：同 ID 去重，异 ID 共存

    func testHashByIDOnly() {
        var set: Set<WindowModel> = []
        set.insert(makeWindowModel(2004, title: "x"))
        set.insert(makeWindowModel(2004, title: "y")) // 同 ID，应去重
        set.insert(makeWindowModel(2005, title: "x"))
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - 5. isPinned：默认 false，可变但不影响 Identifiable 语义

    func testIsPinnedDefaultsFalseAndMutable() {
        var w = makeWindowModel(2006)
        XCTAssertFalse(w.isPinned)
        XCTAssertEqual(w.id, 2006)

        w.isPinned = true
        XCTAssertTrue(w.isPinned)
        XCTAssertEqual(w, makeWindowModel(2006), "isPinned 变化不影响按 ID 判等")
    }
}
