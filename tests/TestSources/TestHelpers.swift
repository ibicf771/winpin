import AppKit
import XCTest

/// 测试辅助：真实窗口工厂 + WindowModel 工厂 + 主 Actor 泵。
///
/// 镜像引擎的 F2 预检依赖 CGWindowList，因此正向路径测试需要一个
/// 真实存在于 WindowServer 的窗口：在测试进程内创建一个 NSWindow
/// 并 orderFrontRegardless（无需激活策略，非 UI 进程亦可入窗列表）。
@MainActor
enum TestWindowFactory {
    private static var didConfigureApp = false

    /// 创建一个真实窗口并等待其进入 CGWindowList，返回窗口与其 CGWindowID。
    static func makeWindow(file: StaticString = #filePath, line: UInt = #line) -> (window: NSWindow, id: CGWindowID) {
        if !didConfigureApp {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            didConfigureApp = true
        }
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "winpin-test-\(UUID().uuidString.prefix(6))"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let id = CGWindowID(window.windowNumber)
        XCTAssertTrue(waitUntilListed(id), "测试窗口 \(id) 未进入 CGWindowList", file: file, line: line)
        return (window, id)
    }

    /// 轮询直到窗口出现在 CGWindowList（WindowServer 注册有少量延迟）。
    @discardableResult
    static func waitUntilListed(_ id: CGWindowID, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if MirrorPinningEngine.windowBounds(for: id) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return MirrorPinningEngine.windowBounds(for: id) != nil
    }
}

/// 构造测试用 WindowModel（appIcon 不参与逻辑，传 nil）。
func makeWindowModel(_ id: CGWindowID, title: String = "测试窗口") -> WindowModel {
    WindowModel(
        id: id,
        ownerPID: 1234,
        ownerName: "TestApp",
        title: title,
        bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
        appIcon: nil)
}

/// 让主 Actor 上排队的 Task 有机会执行一段时间（异步建立镜像会话等）。
@MainActor
func pumpMainActor(seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
