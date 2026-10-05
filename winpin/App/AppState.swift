import AppKit
import CoreGraphics
import Foundation

/// 全局应用状态：聚合权限、置顶协调、窗口列表、快捷键等核心对象，
/// 作为 UI 层的单一数据源（计划 §5.2 AppState）。
@MainActor
final class AppState: ObservableObject {
    /// 全局单例（AppDelegate 与 SwiftUI 共享）。
    static let shared = AppState()

    // MARK: - 子系统

    let permissions = PermissionManager()
    let persistence = PersistenceService()
    let enumerator = WindowEnumerator()
    /// 置顶引擎：macOS 26.3 起真置顶被系统中性化，默认使用镜像引擎（路线 B）。
    /// SkyLight 引擎代码保留（Core/SkyLightPinningEngine.swift）但不再默认启用。
    let engine: WindowPinningEngine?
    let coordinator: PinningCoordinator
    let hotKeys = HotKeyManager()

    // MARK: - UI 状态

    /// 当前可见窗口列表（含置顶标记投影）。
    @Published private(set) var windows: [WindowModel] = []
    /// 快捷键注册失败提示（冲突时展示）。
    @Published var hotKeyError: String?

    /// 窗口列表轮询定时器（2s，兼顾窗口销毁 diff 清理，计划 §2.3-4）。
    private var refreshTimer: Timer?
    /// 是否已启动（幂等保护）。
    private var started = false

    private init() {
        let engine = MirrorPinningEngine()
        engine.moveSourceOnUnpin = persistence.moveSourceOnUnpin
        let coordinator = PinningCoordinator(engine: engine)
        self.engine = engine
        self.coordinator = coordinator

        // 镜像浮窗关闭按钮 → 走 coordinator.unpin 统一清状态并销毁镜像。
        engine.onRequestUnpin = { [coordinator] windowID in
            coordinator.unpin(windowID)
        }
        // 镜像建立失败/捕获中断 → 清置顶状态并给出用户可读提示。
        engine.onMirrorFailed = { [coordinator] windowID, message in
            coordinator.unpin(windowID)
            coordinator.lastError = message
        }
    }

    /// 启动各子系统（AppDelegate 在 didFinishLaunching 调用）。
    func start() {
        guard !started else { return }
        started = true

        // 全局快捷键
        hotKeys.onToggleFront = { [weak self] in
            Task { @MainActor in self?.toggleFrontWindowPin() }
        }
        hotKeys.onUnpinAll = { [weak self] in
            Task { @MainActor in self?.coordinator.unpinAll() }
        }
        hotKeys.onRegisterFailed = { [weak self] _, hotKey in
            Task { @MainActor in
                self?.hotKeyError = "快捷键 \(hotKey.display) 注册失败，可能已被其他应用占用，请在设置中更换。"
            }
        }
        hotKeys.start(toggle: persistence.toggleHotKey,
                      unpinAll: persistence.unpinAllHotKey)

        // 镜像引擎巡检：跟随源窗口几何变化、清理已销毁窗口的镜像。
        (engine as? MirrorPinningEngine)?.startWatchdog()

        // 窗口列表轮询 + 置顶条目清理
        refreshWindows()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWindows()
            }
        }

        // App 退出即清理其窗口的置顶条目（闭包式监听，避免 @objc/actor 限制）
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWindows()
            }
        }
    }

    // MARK: - 窗口列表

    /// 重新枚举窗口并投影置顶状态；同时清理已销毁窗口的置顶条目。
    func refreshWindows() {
        var list = enumerator.enumerateWindows()
        coordinator.pruneDisappearedWindows(aliveIDs: Set(list.map(\.id)))
        for index in list.indices {
            list[index].isPinned = coordinator.isPinned(list[index].id)
        }
        windows = list
    }

    /// 清空缩略图缓存并刷新（面板「刷新」按钮）。
    func forceRefresh() {
        enumerator.clearThumbnailCache()
        refreshWindows()
    }

    // MARK: - 快捷键动作

    /// ⌃⌥P：切换「前台 App 的当前窗口」置顶状态。
    ///
    /// 目标窗口选择：优先 AX 聚焦窗口（需辅助功能权限），
    /// 否则回退为该 App 在窗口列表中的第一个（Z 序最前）普通窗口。
    func toggleFrontWindowPin() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        refreshWindows()
        var target: WindowModel?
        if let focusedID = AXHelper.focusedWindowID(of: pid) {
            target = windows.first(where: { $0.id == focusedID })
        }
        if target == nil {
            target = windows.first(where: { $0.ownerPID == pid })
        }
        guard let window = target else {
            Log.hotkey.info("no window found for front app pid=\(pid)")
            return
        }
        coordinator.toggle(window)
        refreshWindows()
    }

    // MARK: - 快捷键配置

    /// 更新快捷键定义并持久化。
    func updateHotKey(action: HotKeyManager.Action, hotKey: HotKeyManager.HotKey) {
        hotKeyError = nil
        switch action {
        case .toggleFront:
            persistence.toggleHotKey = hotKey
        case .unpinAll:
            persistence.unpinAllHotKey = hotKey
        }
        hotKeys.update(action, to: hotKey)
    }

    // MARK: - 行为设置

    /// 更新「取消置顶时把源窗口移到镜像最后位置」开关并持久化。
    func setMoveSourceOnUnpin(_ enabled: Bool) {
        persistence.moveSourceOnUnpin = enabled
        (engine as? MirrorPinningEngine)?.moveSourceOnUnpin = enabled
    }
}
