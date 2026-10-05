import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置页：快捷键自定义、开机自启动、权限状态（计划 §3.2 / §4 / §8-9）。
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var permissions: PermissionManager

    @State private var toggleHotKey: HotKeyManager.HotKey = .defaultToggle
    @State private var unpinAllHotKey: HotKeyManager.HotKey = .defaultUnpinAll
    @State private var launchAtLogin: Bool = false
    @State private var launchAtLoginError: String?
    @State private var moveSourceOnUnpin: Bool = false
    @State private var showResetConfirm: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            hotKeyTab
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            permissionTab
                .tabItem { Label("权限", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            toggleHotKey = state.persistence.toggleHotKey
            unpinAllHotKey = state.persistence.unpinAllHotKey
            launchAtLogin = SMAppService.mainApp.status == .enabled
            moveSourceOnUnpin = state.persistence.moveSourceOnUnpin
            permissions.refreshStatus()
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Toggle("开机自动启动 winpin", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in setLaunchAtLogin(newValue) }
            ))
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle("取消置顶时，将窗口移到镜像最后的位置", isOn: Binding(
                get: { moveSourceOnUnpin },
                set: { newValue in
                    moveSourceOnUnpin = newValue
                    state.setMoveSourceOnUnpin(newValue)
                }
            ))
            Text("拖动镜像浮窗后取消置顶，源窗口会移动到浮窗所在位置（需辅助功能权限）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("登录项由系统「设置 → 通用 → 登录项」统一管理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - 快捷键

    private var hotKeyTab: some View {
        Form {
            LabeledContent("切换前台窗口置顶") {
                HotKeyRecorderView(hotKey: $toggleHotKey) { newKey in
                    state.updateHotKey(action: .toggleFront, hotKey: newKey)
                }
            }
            LabeledContent("取消所有置顶") {
                HotKeyRecorderView(hotKey: $unpinAllHotKey) { newKey in
                    state.updateHotKey(action: .unpinAll, hotKey: newKey)
                }
            }
            if let error = state.hotKeyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("恢复默认快捷键") {
                toggleHotKey = .defaultToggle
                unpinAllHotKey = .defaultUnpinAll
                state.updateHotKey(action: .toggleFront, hotKey: .defaultToggle)
                state.updateHotKey(action: .unpinAll, hotKey: .defaultUnpinAll)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 权限

    private var permissionTab: some View {
        Form {
            LabeledContent("屏幕录制（必需）") {
                permissionBadge(granted: permissions.screenCaptureGranted) {
                    permissions.requestScreenCapture()
                    permissions.startPolling()
                }
            }
            LabeledContent("辅助功能（可选）") {
                permissionBadge(granted: permissions.accessibilityGranted) {
                    permissions.requestAccessibility()
                    permissions.startPolling()
                }
            }
            Text("辅助功能用于更准确地定位前台 App 的聚焦窗口，缺失不影响基本置顶。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("权限异常修复") {
                Button("重置权限并重启 winpin…") {
                    showResetConfirm = true
                }
                Text("更新 App 或系统后，若系统设置里开关已开启但这里仍显示「未授权」，点上方按钮清除旧授权记录并自动重启，重启后按系统弹窗重新授权即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("重置权限并重启？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("重置并重启", role: .destructive) {
                permissions.resetPermissions()
                permissions.relaunchApp()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除 winpin 的屏幕录制与辅助功能授权记录，随后自动重启。重启后系统会重新弹窗请求授权，点「允许」即可。")
        }
    }

    private func permissionBadge(granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(granted ? "已授权" : "未授权")
                .foregroundStyle(.secondary)
            if !granted {
                Button("去授权", action: action)
            }
        }
    }

    // MARK: - 开机自启动

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - 快捷键录制控件

/// 点击后进入录制态，按下组合键即捕获为新的快捷键定义。
struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var hotKey: HotKeyManager.HotKey
    var onCommit: (HotKeyManager.HotKey) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = { captured in
            hotKey = captured
            onCommit(captured)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.displayText = hotKey.display
        nsView.needsDisplay = true
    }
}

/// 底层录制 NSView：聚焦状态下监听 keyDown，转换为 Carbon 键码+修饰键。
final class KeyCaptureNSView: NSView {
    var displayText: String = "" { didSet { needsDisplay = true } }
    var onCapture: (HotKeyManager.HotKey) -> Void = { _ in }

    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 24)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        // 纯修饰键按下不产生 keyDown 组合，忽略 Esc 之外的单独键；
        // Esc 取消录制。
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        // 至少需要一个修饰键，避免与正常输入冲突。
        guard carbon != 0 else { return }

        let keyChar = (event.charactersIgnoringModifiers ?? "").uppercased()
        let hotKey = HotKeyManager.HotKey(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            display: symbols + keyChar
        )
        recording = false
        onCapture(hotKey)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                   : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = recording ? "按下快捷键…" : displayText
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attrs)
    }
}
