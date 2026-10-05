import SwiftUI
import AppKit

/// winpin 应用入口。
///
/// 形态：纯菜单栏 App（LSUIElement=true）。菜单栏图标与弹出面板由
/// AppDelegate 以经典 NSStatusItem + NSPopover 实现（MenuBarExtra 在
/// macOS 26.3 上不渲染图标，已移除）；设置保留 SwiftUI `Settings` 场景；
/// 首启权限引导由 AppDelegate 以 NSHostingController 窗口方式弹出。
@main
struct WinpinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.permissions)
                .environmentObject(state.coordinator)
        }
    }
}
