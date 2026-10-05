import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility API 辅助（可选路径，计划 §5.2）。
///
/// 用途：快捷键置顶前台窗口时，优先取该 App 的 AX 聚焦窗口（比"层 0 第一个
/// 窗口"更准）。无辅助功能权限时全部返回 nil，调用方回退到启发式方案。
///
/// `_AXUIElementGetWindow` 为 HIServices 私有导出符号（dlsym 获取，缺失则优雅降级）。
enum AXHelper {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// 惰性解析 `_AXUIElementGetWindow`。
    private static let getWindow: GetWindowFn? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sym = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    /// 是否有辅助功能权限（静默检查）。
    static var isTrusted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 获取指定进程当前聚焦窗口的 CGWindowID；无权限/无聚焦窗口时返回 nil。
    static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        guard isTrusted, let getWindow else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)
        guard err == .success, let focusedValue else { return nil }

        // F8: 异常 App 可能返回非 AXUIElement 类型，强转即崩；先校验 CFTypeID 再转换。
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let windowElement = focusedValue as! AXUIElement
        var windowID: CGWindowID = 0
        guard getWindow(windowElement, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    /// 置顶后尝试激活目标窗口所在 App（可选增强，无权限时静默失败）。
    static func activateApp(of pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// raise 指定 CGWindowID 的窗口并将其设为聚焦窗口（镜像浮窗点击联动）。
    /// 无辅助功能权限或找不到对应 AX 窗口时静默失败。
    static func raiseWindow(id windowID: CGWindowID, of pid: pid_t) {
        guard isTrusted, let getWindow else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }

        for element in windows {
            var wid: CGWindowID = 0
            guard getWindow(element, &wid) == .success, wid == windowID else { continue }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, element)
            return
        }
    }

    /// 将指定窗口移动到目标位置（仅改位置、不改尺寸）。
    ///
    /// 用于「取消置顶时把源窗口移动到镜像浮窗最后停留的位置」（v1.3 可选设置）。
    /// `topLeft` 为 AX 坐标系：主屏左上角原点、y 向下。
    /// 无辅助功能权限或找不到对应 AX 窗口时静默失败。
    static func moveWindow(id windowID: CGWindowID, of pid: pid_t, toTopLeft position: CGPoint) {
        guard isTrusted, let getWindow else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }

        for element in windows {
            var wid: CGWindowID = 0
            guard getWindow(element, &wid) == .success, wid == windowID else { continue }
            var pos = position
            guard let value = AXValueCreate(.cgPoint, &pos) else { return }
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
            return
        }
    }
}
