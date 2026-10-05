import CoreGraphics

/// 置顶引擎抽象（开发计划 §2.2 双模式架构）。
///
/// - 路线 A：`SkyLightPinningEngine`，真置顶（私有 API 提升窗口 level）。
///   macOS 26.3 起被系统中性化（设级成功但合成器忽略），代码保留但不再默认启用。
/// - 路线 B：`MirrorPinningEngine`，镜像置顶（ScreenCaptureKit 捕获 + 自有浮窗渲染），
///   v1.1 起为默认引擎。
protocol WindowPinningEngine: AnyObject {
    /// 引擎是否可用（私有符号解析失败时为 false）。
    var isAvailable: Bool { get }
    /// 引擎标识，用于日志与 UI 提示。
    var engineName: String { get }

    /// 读取窗口当前层级；窗口不存在或调用失败时返回 nil。
    func windowLevel(for windowID: CGWindowID) -> Int32?

    /// 设置窗口层级。
    /// - Returns: 系统调用是否返回成功（注意：macOS 可能在无屏幕录制权限时
    ///   返回成功但不生效，调用方需配合 `windowLevel(for:)` 读回验证）。
    @discardableResult
    func setWindowLevel(_ windowID: CGWindowID, to level: Int32) -> Bool
}

/// 置顶时使用的目标层级。
enum PinningLevel {
    /// 浮动窗口层级（kCGFloatingWindowLevelKey，运行时取值，不硬编码）。
    static var floating: Int32 {
        Int32(CGWindowLevelForKey(.floatingWindow))
    }
    /// 正常窗口层级（kCGNormalWindowLevelKey）。
    static var normal: Int32 {
        Int32(CGWindowLevelForKey(.normalWindow))
    }
}
