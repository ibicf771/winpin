import CoreGraphics
import XCTest

/// 可控的假置顶引擎：内存中维护 level 表，可注入「系统调用失败」与
/// 「调用成功但读回未生效」（macOS 无屏幕录制权限时的静默忽略）两种故障。
final class MockEngine: WindowPinningEngine {
    var isAvailable = true
    let engineName = "Mock"

    /// windowID → 当前 level（缺省视为 normal）。
    var levels: [CGWindowID: Int32] = [:]
    /// setWindowLevel 调用记录（按序）。
    private(set) var setCalls: [(windowID: CGWindowID, level: Int32)] = []
    /// 为 true 时 setWindowLevel 返回 false（系统调用失败）。
    var failOnSet = false
    /// 为 true 时 setWindowLevel 返回 true 但不写 levels（静默忽略）。
    var readbackMismatch = false

    func windowLevel(for windowID: CGWindowID) -> Int32? {
        levels[windowID] ?? PinningLevel.normal
    }

    @discardableResult
    func setWindowLevel(_ windowID: CGWindowID, to level: Int32) -> Bool {
        setCalls.append((windowID, level))
        if failOnSet { return false }
        if !readbackMismatch { levels[windowID] = level }
        return true
    }
}

@MainActor
final class PinningCoordinatorTests: XCTestCase {
    private var engine: MockEngine!
    private var coordinator: PinningCoordinator!

    override func setUp() {
        super.setUp()
        engine = MockEngine()
        coordinator = PinningCoordinator(engine: engine)
    }

    override func tearDown() {
        coordinator = nil
        engine = nil
        super.tearDown()
    }

    // MARK: - 1. pin 成功：记录原始层级并设为 floating

    func testPinSuccessRecordsOriginalLevel() {
        let w = makeWindowModel(1001)
        engine.levels[1001] = 7 // 模拟一个非标准原始层级

        XCTAssertTrue(coordinator.pin(w))
        XCTAssertTrue(coordinator.isPinned(1001))
        XCTAssertEqual(coordinator.pinned[1001], 7)
        XCTAssertEqual(engine.levels[1001], PinningLevel.floating)
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - 2. pin 幂等：已置顶窗口再次 pin 不重复调用引擎

    func testPinIsIdempotent() {
        let w = makeWindowModel(1002)
        XCTAssertTrue(coordinator.pin(w))
        XCTAssertTrue(coordinator.pin(w))
        XCTAssertEqual(engine.setCalls.count, 1, "重复 pin 不应再次调用引擎")
        XCTAssertTrue(coordinator.isPinned(1002))
    }

    // MARK: - 3. 引擎 setWindowLevel 失败：不记录、报错

    func testPinFailsWhenEngineSetFails() {
        engine.failOnSet = true
        let w = makeWindowModel(1003)

        XCTAssertFalse(coordinator.pin(w))
        XCTAssertFalse(coordinator.isPinned(1003))
        XCTAssertTrue(coordinator.pinned.isEmpty)
        XCTAssertEqual(coordinator.lastError, "无法置顶「\(w.displayTitle)」：系统调用失败。")
    }

    // MARK: - 4. 读回未生效（静默忽略）：回滚到原始层级并报错

    func testPinReadbackMismatchRollsBack() {
        engine.readbackMismatch = true
        let w = makeWindowModel(1004)

        XCTAssertFalse(coordinator.pin(w))
        XCTAssertFalse(coordinator.isPinned(1004))
        // 一次设 floating + 一次回滚到原 level（normal）
        XCTAssertEqual(engine.setCalls.count, 2)
        XCTAssertEqual(engine.setCalls[0].level, PinningLevel.floating)
        XCTAssertEqual(engine.setCalls[1].level, PinningLevel.normal)
        XCTAssertTrue(coordinator.lastError?.contains("未生效") ?? false)
    }

    // MARK: - 5. 引擎为 nil：报通用不可用文案（F11）

    func testPinWithNilEngineReportsUnavailable() {
        let nilCoordinator = PinningCoordinator(engine: nil)
        XCTAssertEqual(nilCoordinator.engineUnavailableMessage, "置顶引擎不可用，请重启 winpin 后重试。")

        XCTAssertFalse(nilCoordinator.pin(makeWindowModel(1005)))
        XCTAssertEqual(nilCoordinator.lastError, "置顶引擎不可用，请重启 winpin 后重试。")
        XCTAssertFalse(nilCoordinator.isPinned(1005))
    }

    // MARK: - 6. unpin 成功：写回原始层级并移除条目

    func testUnpinRestoresOriginalLevelAndRemovesEntry() {
        let w = makeWindowModel(1006)
        engine.levels[1006] = 3
        XCTAssertTrue(coordinator.pin(w))

        coordinator.unpin(1006)
        XCTAssertFalse(coordinator.isPinned(1006))
        XCTAssertEqual(engine.levels[1006], 3, "应写回置顶前记录的原始层级")
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - 7. unpin 未置顶窗口：no-op，不调用引擎

    func testUnpinNonPinnedIsNoOp() {
        coordinator.unpin(9999)
        XCTAssertTrue(engine.setCalls.isEmpty)
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - 8. toggle：置顶 → 取消 往返

    func testTogglePinsThenUnpins() {
        let w = makeWindowModel(1007)
        coordinator.toggle(w)
        XCTAssertTrue(coordinator.isPinned(1007))
        XCTAssertEqual(engine.levels[1007], PinningLevel.floating)

        coordinator.toggle(w)
        XCTAssertFalse(coordinator.isPinned(1007))
        XCTAssertEqual(engine.levels[1007], PinningLevel.normal)
    }

    // MARK: - 9. unpinAll：全部写回并清空

    func testUnpinAllRestoresAllAndClears() {
        XCTAssertTrue(coordinator.pin(makeWindowModel(1101)))
        XCTAssertTrue(coordinator.pin(makeWindowModel(1102)))
        XCTAssertEqual(coordinator.pinned.count, 2)

        coordinator.unpinAll()
        XCTAssertTrue(coordinator.pinned.isEmpty)
        XCTAssertEqual(engine.levels[1101], PinningLevel.normal)
        XCTAssertEqual(engine.levels[1102], PinningLevel.normal)
    }

    // MARK: - 10. prune：清理已销毁窗口的条目（不调用引擎写回）

    func testPruneDisappearedWindowsRemovesDeadEntries() {
        XCTAssertTrue(coordinator.pin(makeWindowModel(1201)))
        XCTAssertTrue(coordinator.pin(makeWindowModel(1202)))
        let callsBefore = engine.setCalls.count

        coordinator.pruneDisappearedWindows(aliveIDs: [1201])
        XCTAssertTrue(coordinator.isPinned(1201))
        XCTAssertFalse(coordinator.isPinned(1202))
        XCTAssertEqual(engine.setCalls.count, callsBefore, "已销毁窗口无需写回 level")
    }

    // MARK: - 11. restoreAll：退出前恢复所有置顶

    func testRestoreAllRestoresEverything() {
        engine.levels[1301] = 5
        XCTAssertTrue(coordinator.pin(makeWindowModel(1301)))
        XCTAssertTrue(coordinator.pin(makeWindowModel(1302)))

        coordinator.restoreAll()
        XCTAssertTrue(coordinator.pinned.isEmpty)
        XCTAssertEqual(engine.levels[1301], 5)
        XCTAssertEqual(engine.levels[1302], PinningLevel.normal)
    }

    // MARK: - 12. F7: unpin 写回失败 → 保留条目 + 记录 lastError

    func testUnpinKeepsEntryWhenWritebackFails() {
        let w = makeWindowModel(1401)
        engine.levels[1401] = 4
        XCTAssertTrue(coordinator.pin(w))

        engine.failOnSet = true // 写回阶段注入失败
        coordinator.unpin(1401)

        XCTAssertTrue(coordinator.isPinned(1401), "写回失败时条目必须保留，避免失去 UI 恢复途径")
        XCTAssertEqual(coordinator.pinned[1401], 4, "保留的原始层级记录不得被污染")
        XCTAssertEqual(coordinator.lastError, "取消置顶失败：无法恢复窗口的原始层级，请重试。")
    }

    // MARK: - 13. F7: 写回失败后重试成功 → 条目移除、层级恢复

    func testUnpinRetryAfterWritebackFailureSucceeds() {
        let w = makeWindowModel(1402)
        engine.levels[1402] = 9
        XCTAssertTrue(coordinator.pin(w))

        engine.failOnSet = true
        coordinator.unpin(1402)
        XCTAssertTrue(coordinator.isPinned(1402))

        engine.failOnSet = false // 故障恢复后重试
        coordinator.lastError = nil
        coordinator.unpin(1402)

        XCTAssertFalse(coordinator.isPinned(1402))
        XCTAssertEqual(engine.levels[1402], 9, "重试成功应恢复原始层级")
        XCTAssertEqual(engine.setCalls.last?.level, 9)
        XCTAssertNil(coordinator.lastError)
    }
}
