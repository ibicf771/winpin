import AppKit
import SwiftUI

/// 单行窗口项：App 图标 + 标题/App 名 + 缩略图 + 置顶/取消按钮（计划 §3.2）。
struct WindowRowView: View {
    let window: WindowModel

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var coordinator: PinningCoordinator

    /// 懒加载缩略图（无权限时为 nil，显示占位符）。
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            appIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(window.ownerName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            thumbnailView
                .frame(width: 72, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            pinButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: window.id) {
            thumbnail = await state.enumerator.thumbnail(for: window.id)
        }
    }

    // MARK: - 子视图

    private var appIcon: some View {
        Group {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var pinButton: some View {
        Button {
            coordinator.toggle(window)
            state.refreshWindows()
        } label: {
            Image(systemName: window.isPinned ? "pin.fill" : "pin")
                .foregroundStyle(window.isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(window.isPinned ? "取消置顶" : "置顶此窗口")
    }
}
