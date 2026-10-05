import AppKit
import CoreGraphics
import XCTest

/// 镜像置顶引擎测试。
///
/// 注意：F2 起 setWindowLevel(floating) 会预检窗口存在性，正向路径测试
/// 必须使用真实窗口（TestWindowFactory），伪造 ID 用于验证失败路径。
@MainActor
final class MirrorPinningEngineTests: XCTestCase {
    private var engine: MirrorPinningEngine!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        engine = MirrorPinningEngine()
    }

    override func tearDown() {
        for window in windows { window.close() }
        windows.removeAll()
        engine = nil
        super.tearDown()
    }

    /// 创建一个真实测试窗口并纳入 tearDown 管理。
    private func makeTestWindow() -> (window: NSWindow, id: CGWindowID) {
        let (window, id) = TestWindowFactory.makeWindow()
        windows.append(window)
        return (window, id)
    }

    // MARK: - 1. 引擎标识与可用性

    func testEngineIdentity() {
        XCTAssertEqual(engine.engineName, "Mirror")
        XCTAssertTrue(engine.isAvailable)
    }

    // MARK: - 2. 未镜像窗口读回 normal（而非 nil，协调器读回验证依赖此语义）

    func testWindowLevelForUnknownWindowIsNormal() {
        XCTAssertEqual(engine.windowLevel(for: 4_000_000_001), PinningLevel.normal)
    }

    // MARK: - 3. 设级 floating 后立即读回（同步状态维护）

    func testSetFloatingThenReadback() {
        let (_, id) = makeTestWindow()
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.floating))
        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.floating)
    }

    // MARK: - 4. 重复设 floating 幂等

    func testSetFloatingIsIdempotent() {
        let (_, id) = makeTestWindow()
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.floating))
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.floating))
        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.floating)
    }

    // MARK: - 5. floating → normal 读回恢复

    func testSetNormalAfterFloatingReadback() {
        let (_, id) = makeTestWindow()
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.floating))
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.normal))
        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.normal)
    }

    // MARK: - 6. 对未镜像窗口设 normal：幂等成功、状态保持 normal

    func testSetNormalOnNonMirroredIsIdempotent() {
        XCTAssertTrue(engine.setWindowLevel(4_000_000_002, to: PinningLevel.normal))
        XCTAssertEqual(engine.windowLevel(for: 4_000_000_002), PinningLevel.normal)
    }

    // MARK: - 7. unpin 先于异步建立完成（竞态）：会话被丢弃、不启动捕获、不上报失败（F1 语义）

    func testUnpinBeforeAsyncSetupDiscardsSession() async {
        let (_, id) = makeTestWindow()
        var failureReported = false
        engine.onMirrorFailed = { _, _ in failureReported = true }

        // 同步连续调用：排队的 Task @MainActor 不可能在两者之间执行，
        // 因此登记会话时该窗口必然已被 unpin。
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.floating))
        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.normal))

        await pumpMainActor(seconds: 1.0)

        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.normal)
        XCTAssertFalse(failureReported, "会话已丢弃、从未启动捕获，不应触发失败上报")
    }

    // MARK: - 8. 镜像建立失败（无屏幕录制权限）：异步清理状态回 normal

    func testMirrorFailureCleansStateAsynchronously() async throws {
        try XCTSkipIf(CGPreflightScreenCaptureAccess(),
                      "测试进程已持有屏幕录制权限，无法触发失败路径")
        let (_, id) = makeTestWindow()
        var reportedID: CGWindowID?
        engine.onMirrorFailed = { wid, _ in reportedID = wid }

        XCTAssertTrue(engine.setWindowLevel(id, to: PinningLevel.floating))
        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.floating)

        // MirrorSession.start() 因无权限失败 → onFailure → 引擎异步清状态。
        let deadline = Date().addingTimeInterval(20)
        var cleaned = false
        while Date() < deadline {
            if engine.windowLevel(for: id) == PinningLevel.normal { cleaned = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(cleaned, "镜像建立失败后 mirroredIDs 应被异步清理")
        XCTAssertEqual(reportedID, id, "失败应通过 onMirrorFailed 上报")
    }

    // MARK: - 9. 协调器联动：PinningCoordinator + 镜像引擎走通 pin/unpin

    func testCoordinatorWithMirrorEnginePinUnpin() async {
        let coordinator = PinningCoordinator(engine: engine)
        let (_, id) = makeTestWindow()
        let w = makeWindowModel(id)

        XCTAssertTrue(coordinator.pin(w), "真实窗口应能通过预检并读回验证")
        XCTAssertTrue(coordinator.isPinned(id))
        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.floating)

        coordinator.unpin(id)
        XCTAssertFalse(coordinator.isPinned(id))
        XCTAssertEqual(engine.windowLevel(for: id), PinningLevel.normal)
        await pumpMainActor(seconds: 0.5) // 让异步建立流程收尾，避免泄漏到后续测试
    }

    // MARK: - 10. 坐标翻转：CGWindowList（左上原点）→ AppKit（左下原点）

    func testCocoaFrameFlipsYAroundPrimaryScreen() {
        let bounds = CGRect(x: 100, y: 200, width: 300, height: 400)
        let cocoa = MirrorPinningEngine.cocoaFrame(forTopLeftBounds: bounds)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.maxY

        XCTAssertEqual(cocoa.minX, bounds.minX)
        XCTAssertEqual(cocoa.width, bounds.width)
        XCTAssertEqual(cocoa.height, bounds.height)
        XCTAssertEqual(cocoa.minY, primaryHeight - bounds.maxY, accuracy: 0.001)
    }

    // MARK: - 11. axTopLeft 与 cocoaFrame 互为逆变换

    func testAxTopLeftIsInverseOfCocoaFrame() {
        let bounds = CGRect(x: 150, y: 250, width: 320, height: 240)
        let cocoa = MirrorPinningEngine.cocoaFrame(forTopLeftBounds: bounds)
        let topLeft = MirrorPinningEngine.axTopLeft(fromCocoaFrame: cocoa)

        XCTAssertEqual(topLeft.x, bounds.minX, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, bounds.minY, accuracy: 0.001)
    }

    // MARK: - 12. scaleFactor：主屏 bounds 返回合理缩放（≥1，Retina 为 2）

    func testScaleFactorAtLeastOne() {
        let bounds = CGRect(x: 10, y: 10, width: 200, height: 200)
        let scale = MirrorPinningEngine.scaleFactor(forTopLeftBounds: bounds)
        XCTAssertGreaterThanOrEqual(scale, 1.0)
        XCTAssertLessThanOrEqual(scale, 4.0)
    }

    // MARK: - 13. F2: 已销毁窗口设 floating 直接失败，不污染状态

    func testSetFloatingOnDestroyedWindowFailsAndDoesNotPolluteState() {
        let deadID: CGWindowID = 4_000_000_003
        XCTAssertNil(MirrorPinningEngine.windowBounds(for: deadID), "前置条件：该 ID 必须不存在")

        XCTAssertFalse(engine.setWindowLevel(deadID, to: PinningLevel.floating),
                       "F2: 窗口不存在时预检必须失败")
        XCTAssertEqual(engine.windowLevel(for: deadID), PinningLevel.normal,
                       "F2: 失败路径不得污染 mirroredIDs")
        // 重复调用仍失败且状态不变（无副作用累积）
        XCTAssertFalse(engine.setWindowLevel(deadID, to: PinningLevel.floating))
        XCTAssertEqual(engine.windowLevel(for: deadID), PinningLevel.normal)
    }

    // MARK: - 14. F2: 协调器对已销毁窗口 pin 优雅失败（系统调用失败文案，无状态残留）

    func testCoordinatorPinOnDestroyedWindowFailsGracefully() {
        let coordinator = PinningCoordinator(engine: engine)
        let deadID: CGWindowID = 4_000_000_004
        let w = makeWindowModel(deadID, title: "幽灵窗口")

        XCTAssertFalse(coordinator.pin(w))
        XCTAssertFalse(coordinator.isPinned(deadID))
        XCTAssertTrue(coordinator.pinned.isEmpty)
        XCTAssertEqual(coordinator.lastError, "无法置顶「幽灵窗口」：系统调用失败。")
        XCTAssertEqual(engine.windowLevel(for: deadID), PinningLevel.normal,
                       "F2: 引擎状态不得被失败 pin 污染")
    }
}
