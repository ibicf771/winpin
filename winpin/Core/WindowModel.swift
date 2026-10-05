import AppKit
import CoreGraphics

/// 窗口数据模型：枚举层与 UI 层之间的统一表示。
///
/// 以 `CGWindowID` 为唯一标识；`NSImage` 不参与 Hashable（按 id 判等/哈希）。
struct WindowModel: Identifiable, Hashable {
    /// 窗口号（WindowServer 分配，进程内全局唯一）。
    let id: CGWindowID
    /// 所属进程 PID。
    let ownerPID: pid_t
    /// 所属 App 名（如「访达」）。
    let ownerName: String
    /// 窗口标题；无屏幕录制权限或 App 隐藏标题时为空串，UI 层用兜底文案。
    let title: String
    /// 窗口在屏幕坐标系中的 bounds。
    let bounds: CGRect
    /// 所属 App 图标（可能为 nil，UI 用占位图）。
    let appIcon: NSImage?
    /// 当前是否已置顶（由协调器状态投影而来，不持久化）。
    var isPinned: Bool = false

    /// 展示用标题：标题为空时以「App 名 窗口」兜底（开发计划 §8-风险 8）。
    var displayTitle: String {
        title.isEmpty ? "\(ownerName) 窗口" : title
    }

    static func == (lhs: WindowModel, rhs: WindowModel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
