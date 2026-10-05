import AppKit
import SwiftUI

/// 菜单栏弹出面板：主入口（计划 §3.2 方案①）。
///
/// 分组展示「已置顶」与「全部窗口」，每行含 App 图标、标题、缩略图与
/// 置顶/取消按钮；底部提供刷新、取消全部、设置与退出。
struct MenuBarPanelView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var coordinator: PinningCoordinator

    /// 搜索关键词（v1.4）：按 App 名 / 窗口标题过滤列表。
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            Divider()
            statusBanners
            windowList
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            state.refreshWindows()
            permissions.refreshStatus()
        }
    }

    /// 按搜索词过滤后的窗口列表（空搜索词返回全量）。
    private var filteredWindows: [WindowModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return state.windows }
        return state.windows.filter {
            $0.ownerName.localizedCaseInsensitiveContains(query) ||
            $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Label("winpin", systemImage: "pin.fill")
                .font(.headline)
            Spacer()
            Button {
                state.forceRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新窗口列表与缩略图")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用或窗口标题", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 状态提示条

    @ViewBuilder
    private var statusBanners: some View {
        if let message = coordinator.engineUnavailableMessage {
            banner(text: message, icon: "exclamationmark.triangle.fill", color: .red)
        } else if !permissions.screenCaptureGranted {
            banner(text: "缺少屏幕录制权限，无法置顶窗口。点我前往授权。",
                   icon: "exclamationmark.triangle.fill", color: .orange)
                .contentShape(Rectangle())
                .onTapGesture {
                    permissions.requestScreenCapture()
                    permissions.startPolling()
                }
        }
        if let error = coordinator.lastError {
            banner(text: error, icon: "xmark.octagon.fill", color: .red)
                .contentShape(Rectangle())
                .onTapGesture { coordinator.lastError = nil }
        }
        if let hotKeyError = state.hotKeyError {
            banner(text: hotKeyError, icon: "keyboard", color: .orange)
                .contentShape(Rectangle())
                .onTapGesture { state.hotKeyError = nil }
        }
    }

    private func banner(text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
    }

    // MARK: - 窗口列表

    private var windowList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PinnedSectionView(windows: filteredWindows.filter(\.isPinned))

                sectionHeader("全部窗口")
                if filteredWindows.isEmpty {
                    Text(searchText.isEmpty ? "未检测到其他应用的窗口" : "没有匹配「\(searchText)」的窗口")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                } else {
                    ForEach(filteredWindows) { window in
                        WindowRowView(window: window)
                    }
                }
            }
        }
        .frame(minHeight: 200, maxHeight: 480)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    // MARK: - 底部操作栏

    private var footer: some View {
        HStack(spacing: 12) {
            Button("取消全部置顶") {
                coordinator.unpinAll()
                state.refreshWindows()
            }
            .disabled(coordinator.pinned.isEmpty)

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
