import SwiftUI

/// 「已置顶」分组（计划 §3.2：面板分"已置顶/全部窗口"两组）。
///
/// 无置顶窗口时整个分组不渲染，保持面板紧凑。
struct PinnedSectionView: View {
    /// 已置顶的窗口（由父视图从全量列表过滤传入）。
    let windows: [WindowModel]

    var body: some View {
        if !windows.isEmpty {
            Text("已置顶")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(windows) { window in
                WindowRowView(window: window)
                    .background(Color.accentColor.opacity(0.06))
            }

            Divider()
                .padding(.top, 4)
        }
    }
}
