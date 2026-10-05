import CoreGraphics
import Foundation

/// 路线 A：SkyLight 私有 API 真置顶引擎。
///
/// 通过 `dlopen`/`dlsym` 桥接以下符号（macOS 26.3 已验证存在）：
/// - `SLSMainConnectionID`  — 获取当前进程的 WindowServer 连接
/// - `SLSGetWindowLevel`    — 读窗口层级
/// - `SLSSetWindowLevel`    — 写窗口层级
///
/// 采用 dlsym 而非 @_silgen_name：符号缺失时 init 返回 nil，优雅失败（计划 §2.3-2）。
///
/// 注意（macOS 26.3 实测）：无屏幕录制权限时，跨进程 `SLSSetWindowLevel`
/// 返回成功但不生效（WindowServer TCC 门控）。协调器负责读回验证并向用户暴露。
final class SkyLightPinningEngine: WindowPinningEngine {
    // MARK: - 私有符号类型

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias GetWindowLevelFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias SetWindowLevelFn = @convention(c) (Int32, CGWindowID, Int32) -> Int32

    // MARK: - 属性

    let engineName = "SkyLight"

    private let mainConnectionID: MainConnectionIDFn
    private let getWindowLevel: GetWindowLevelFn
    private let setWindowLevelFn: SetWindowLevelFn

    /// 惰性获取连接 ID，避免 init 时 WindowServer 连接尚未建立。
    private lazy var connectionID: Int32 = mainConnectionID()

    var isAvailable: Bool { true } // init? 成功即可用

    // MARK: - 初始化

    /// 解析私有符号；任一缺失则返回 nil。
    init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            // F3: dlerror() 可能返回 nil，强解包会崩，map 后兜底。
            Log.pinning.error("dlopen SkyLight failed: \(dlerror().map { String(cString: $0) } ?? "unknown dlerror")")
            return nil
        }
        guard let pMain = dlsym(handle, "SLSMainConnectionID"),
              let pGet = dlsym(handle, "SLSGetWindowLevel"),
              let pSet = dlsym(handle, "SLSSetWindowLevel") else {
            Log.pinning.error("SkyLight symbols missing (SLSMainConnectionID/SLSGetWindowLevel/SLSSetWindowLevel)")
            return nil
        }
        self.mainConnectionID = unsafeBitCast(pMain, to: MainConnectionIDFn.self)
        self.getWindowLevel = unsafeBitCast(pGet, to: GetWindowLevelFn.self)
        self.setWindowLevelFn = unsafeBitCast(pSet, to: SetWindowLevelFn.self)
        Log.pinning.info("SkyLightPinningEngine ready")
    }

    // MARK: - WindowPinningEngine

    func windowLevel(for windowID: CGWindowID) -> Int32? {
        var level: Int32 = 0
        let err = getWindowLevel(connectionID, windowID, &level)
        guard err == 0 else {
            Log.pinning.debug("SLSGetWindowLevel(\(windowID)) err=\(err)")
            return nil
        }
        return level
    }

    @discardableResult
    func setWindowLevel(_ windowID: CGWindowID, to level: Int32) -> Bool {
        let err = setWindowLevelFn(connectionID, windowID, level)
        if err != 0 {
            Log.pinning.error("SLSSetWindowLevel(\(windowID), \(level)) err=\(err)")
        }
        return err == 0
    }
}
