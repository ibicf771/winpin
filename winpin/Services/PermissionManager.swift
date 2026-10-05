import AppKit
import ApplicationServices
import CoreGraphics

/// 权限管理器：屏幕录制（硬性）与辅助功能（可选）两项权限的检查、申请与引导。
///
/// 对应开发计划 §4：启动时静默 preflight，不主动弹窗；申请动作由用户在
/// 引导页/设置页点击触发；提供轮询以便授权完成后自动刷新 UI。
@MainActor
final class PermissionManager: ObservableObject {
    /// 屏幕录制权限：读取窗口标题、SCK 缩略图、跨进程 SkyLight 操作均依赖它。
    @Published private(set) var screenCaptureGranted: Bool = false
    /// 辅助功能权限：备用路径（AX 聚焦窗口、置顶后激活窗口）。
    @Published private(set) var accessibilityGranted: Bool = false

    /// 权限轮询定时器。
    private var pollTimer: Timer?
    /// 轮询截止时间（最多 30s，计划 §4-3）。
    private var pollDeadline: Date?

    init() {
        refreshStatus()
    }

    /// 静默刷新两项权限状态（不触发系统弹窗）。
    func refreshStatus() {
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    /// 发起屏幕录制权限申请（首次会触发系统弹窗，之后跳系统设置）。
    func requestScreenCapture() {
        // CGRequestScreenCaptureAccess 在已拒绝的情况下返回 false 且不弹窗，
        // 此时引导用户去系统设置手动开启。
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            openScreenCaptureSettings()
        }
        refreshStatus()
    }

    /// 发起辅助功能权限申请（带系统弹窗）。
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshStatus()
    }

    /// 打开「系统设置 → 隐私与安全性 → 屏幕录制」。
    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 权限重置（v1.4.2，替代终端 tccutil 三条命令）

    /// 重置 winpin 的屏幕录制/辅助功能授权记录。
    ///
    /// 等价于终端执行 `tccutil reset ScreenCapture/Accessibility com.winpin.app`。
    /// 适用场景：更新 App（ad-hoc 签名指纹变化）或升级系统后，系统设置里开关
    /// 虽然开着但授权实际已失效（绑定的是旧二进制）。重置后需重启 App 重新授权。
    ///
    /// - Returns: 两条 tccutil 命令是否都执行成功。
    @discardableResult
    func resetPermissions() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.winpin.app"
        var allSucceeded = true
        for service in ["ScreenCapture", "Accessibility"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    allSucceeded = false
                    Log.permission.error("tccutil reset \(service) exited with \(process.terminationStatus)")
                }
            } catch {
                allSucceeded = false
                Log.permission.error("tccutil reset \(service) failed to launch: \(error.localizedDescription)")
            }
        }
        Log.permission.info("permissions reset via tccutil, success=\(allSucceeded)")
        refreshStatus()
        return allSucceeded
    }

    /// 重启 App（重置权限后调用）：延迟 1s 由 open 拉起新实例，同时退出当前进程。
    func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(bundlePath)\""]
        do {
            try process.run()
            Log.permission.info("relaunching app: \(bundlePath)")
            NSApp.terminate(nil)
        } catch {
            Log.permission.error("relaunch failed: \(error.localizedDescription)")
        }
    }

    /// 启动权限轮询：每 1s 检查一次，最多 30s，全部授予后提前停止。
    func startPolling() {
        stopPolling()
        pollDeadline = Date().addingTimeInterval(30)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStatus()
                // F6: 辅助功能为可选项，屏幕录制授予即停止轮询（辅助功能状态照常刷新展示）。
                let done = self.screenCaptureGranted
                let expired = Date() >= (self.pollDeadline ?? Date.distantPast)
                if done || expired {
                    self.stopPolling()
                    Log.permission.info("polling stopped, screen: \(self.screenCaptureGranted), ax: \(self.accessibilityGranted)")
                }
            }
        }
    }

    /// 停止轮询。
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollDeadline = nil
    }
}
