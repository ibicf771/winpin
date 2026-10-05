import SwiftUI

/// 首启权限引导向导（计划 §4 首启引导策略）。
///
/// 屏幕录制为硬性权限（无它无法读标题/缩略图/跨进程置顶）；
/// 辅助功能为可选。授权完成或用户选择「稍后」后回调关闭。
struct OnboardingView: View {
    @EnvironmentObject private var permissions: PermissionManager

    /// 引导完成回调（关闭窗口）。
    var onFinish: () -> Void = {}

    @State private var showResetConfirm: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("欢迎使用 winpin")
                        .font(.title2).bold()
                    Text("任意窗口，一键置顶")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("winpin 需要以下权限才能正常工作：")
                .font(.callout)

            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "屏幕录制（必需）",
                detail: "用于读取窗口标题、生成缩略图，以及执行跨窗口置顶操作。",
                granted: permissions.screenCaptureGranted
            ) {
                permissions.requestScreenCapture()
                permissions.startPolling()
            }

            permissionRow(
                icon: "hand.raised",
                title: "辅助功能（可选）",
                detail: "用于快捷键置顶时准确定位前台 App 的聚焦窗口。",
                granted: permissions.accessibilityGranted
            ) {
                permissions.requestAccessibility()
                permissions.startPolling()
            }

            // v1.4.2：更新 App/系统后旧授权失效的自助修复入口，
            // 替代终端 tccutil 命令。
            if !permissions.screenCaptureGranted || !permissions.accessibilityGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Button("之前已授权过？一键重置权限并重启") {
                        showResetConfirm = true
                    }
                    .controlSize(.small)
                    Text("更新 App 或系统后旧授权会失效（系统设置里开关开着但实际无效）。重置并重启后，按系统弹窗重新授权即可。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack {
                Button("稍后再说") { onFinish() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("完成") { onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.screenCaptureGranted)
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
        .onAppear { permissions.startPolling() }
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

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).bold()
                    if granted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    Button("去授权", action: action)
                        .controlSize(.small)
                }
            }
        }
    }
}
