import CoreGraphics
import Foundation

/// 置顶状态协调器：置顶/取消的状态管理、读回验证、窗口销毁清理、退出恢复。
///
/// 状态：`pinned[windowID] = 原始层级`（计划 §2.3-4）。置顶前记录原 level，
/// 取消时写回；窗口消失（App 退出/窗口关闭）时自动清理条目。
@MainActor
final class PinningCoordinator: ObservableObject {
    /// 已置顶窗口：windowID → 置顶前的原始层级。
    @Published private(set) var pinned: [CGWindowID: Int32] = [:]
    /// 最近一次操作失败的提示（读回验证失败等），UI 展示后由用户消除。
    @Published var lastError: String?

    private let engine: WindowPinningEngine?

    init(engine: WindowPinningEngine?) {
        self.engine = engine
    }

    /// 引擎不可用时的固定提示（F11: 通用表述，不再绑定 SkyLight 措辞）。
    var engineUnavailableMessage: String? {
        engine == nil ? "置顶引擎不可用，请重启 winpin 后重试。" : nil
    }

    func isPinned(_ windowID: CGWindowID) -> Bool {
        pinned[windowID] != nil
    }

    // MARK: - 置顶 / 取消

    /// 切换窗口置顶状态。
    func toggle(_ window: WindowModel) {
        if isPinned(window.id) {
            unpin(window.id)
        } else {
            pin(window)
        }
    }

    /// 置顶指定窗口。
    ///
    /// 流程：读原 level → 设为浮动层级 → 读回验证（计划 §8 风险 1 的线上自检）。
    /// 读回未生效时判定系统拒绝（多为无屏幕录制权限），恢复并提示。
    @discardableResult
    func pin(_ window: WindowModel) -> Bool {
        guard let engine else {
            lastError = engineUnavailableMessage
            return false
        }
        guard !isPinned(window.id) else { return true }

        let original = engine.windowLevel(for: window.id) ?? PinningLevel.normal
        let target = PinningLevel.floating
        guard engine.setWindowLevel(window.id, to: target) else {
            lastError = "无法置顶「\(window.displayTitle)」：系统调用失败。"
            return false
        }

        // 读回验证：macOS 可能在无权限时静默忽略跨进程 level 设置。
        if let readback = engine.windowLevel(for: window.id), readback == target {
            pinned[window.id] = original
            Log.pinning.info("pinned \(window.id) (\(window.ownerName)), \(original) -> \(target)")
            return true
        } else {
            _ = engine.setWindowLevel(window.id, to: original)
            lastError = """
            置顶「\(window.displayTitle)」未生效。请确认已在\
            「系统设置 → 隐私与安全性 → 屏幕录制」中授权 winpin，然后重试。
            """
            Log.pinning.error("pin readback failed for \(window.id)")
            return false
        }
    }

    /// 取消置顶，恢复原始层级。
    ///
    /// F7: 写回原 level 失败时保留 pinned 条目（窗口可能仍滞留 floating），
    /// 设置 lastError 提示用户重试，避免清状态后失去 UI 恢复途径。
    func unpin(_ windowID: CGWindowID) {
        guard let original = pinned[windowID] else { return }
        if let engine {
            guard engine.setWindowLevel(windowID, to: original) else {
                lastError = "取消置顶失败：无法恢复窗口的原始层级，请重试。"
                Log.pinning.error("unpin \(windowID) failed to restore level \(original), entry kept")
                return
            }
        }
        pinned[windowID] = nil
        Log.pinning.info("unpinned \(windowID), restored to \(original)")
    }

    /// 取消所有置顶（快捷键 ⌃⌥⇧P 与面板按钮共用）。
    func unpinAll() {
        for (windowID, original) in pinned {
            if let engine {
                _ = engine.setWindowLevel(windowID, to: original)
            }
        }
        pinned.removeAll()
        Log.pinning.info("unpinAll done")
    }

    /// 退出前恢复所有置顶（不修改 pinned 语义，仅尽力写回）。
    func restoreAll() {
        unpinAll()
    }

    // MARK: - 窗口销毁清理

    /// 与最新窗口列表 diff，清理已消失窗口的置顶条目（计划 §2.3-4）。
    /// 窗口已销毁时无需写回 level，直接清状态。
    func pruneDisappearedWindows(aliveIDs: Set<CGWindowID>) {
        let dead = pinned.keys.filter { !aliveIDs.contains($0) }
        for windowID in dead {
            pinned[windowID] = nil
            Log.pinning.info("pruned destroyed window \(windowID)")
        }
    }
}
