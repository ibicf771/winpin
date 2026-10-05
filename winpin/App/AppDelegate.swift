import AppKit
import SwiftUI

/// 应用生命周期委托：
/// - 创建菜单栏 NSStatusItem（替代 MenuBarExtra，后者在 macOS 26.3 上不渲染图标）；
/// - 启动时完成权限静默检查，缺屏幕录制权限则弹首启引导窗口；
/// - 注册全局快捷键；
/// - 退出前恢复所有被置顶窗口的原始层级，避免层级残留。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 首启引导窗口（仅在有权限缺失时创建）。
    private var onboardingWindow: NSWindow?
    /// 菜单栏状态项（经典 NSStatusItem 实现）。
    private var statusItem: NSStatusItem?
    /// 点击状态项弹出的主面板。
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()

        let state = AppState.shared
        Log.app.info("winpin launched, engine available: \(state.engine != nil)")
        Log.app.info("permissions at launch: screen=\(state.permissions.screenCaptureGranted), ax=\(state.permissions.accessibilityGranted)")

        state.start()

        if !state.permissions.screenCaptureGranted {
            showOnboarding()
        }
    }

    // MARK: - 菜单栏状态项

    /// 创建 NSStatusItem：pin.fill 模板图标 + 点击弹出 NSPopover 主面板。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // v1.4.3：固定身份标识。系统据此持久化图标位置，也让 Bartender 等菜单栏
        // 管理工具在 App 重启后能认出"它还是它"，避免被当作新项目重置显示规则。
        item.autosaveName = "com.winpin.app.statusitem"
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "winpin") {
                image.isTemplate = true // 适配深浅色菜单栏
                button.image = image
            } else {
                button.title = "winpin" // 图标不可用时的兜底
            }
            button.toolTip = "winpin 窗口置顶"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
        Log.ui.info("status item created, hasImage=\(item.button?.image != nil)")
    }

    /// 点击菜单栏图标：弹出/关闭主面板 Popover（.transient，点击外部自动关闭）。
    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        let state = AppState.shared
        let hosting = NSHostingController(rootView: MenuBarPanelView()
            .environmentObject(state)
            .environmentObject(state.permissions)
            .environmentObject(state.coordinator))
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 560)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        Log.ui.debug("menu bar popover shown")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出钩子：统一恢复所有置顶，防止崩溃/退出后层级残留。
        AppState.shared.coordinator.restoreAll()
        Log.app.info("winpin terminating, all pins restored")
    }

    // MARK: - 首启引导

    private func showOnboarding() {
        guard onboardingWindow == nil else { return }
        let state = AppState.shared
        let view = OnboardingView { [weak self] in
            // 用户完成引导（权限已授予或选择稍后）
            self?.onboardingWindow?.close()
        }
        .environmentObject(state)
        .environmentObject(state.permissions)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "欢迎使用 winpin"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == onboardingWindow {
            onboardingWindow = nil
            // 关闭引导后仍无屏幕录制权限时，面板会提示功能受限，不再反复弹窗。
            AppState.shared.persistence.onboardingShown = true
        }
    }
}
