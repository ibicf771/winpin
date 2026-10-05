import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 路线 B：镜像置顶引擎（macOS 26.3 起真置顶被系统中性化后的默认方案）。
///
/// 原理（参照 Topit）：对目标窗口建立 ScreenCaptureKit 实时流，
/// 在一个自有高层级浮窗（NSPanel, `.floating`）中渲染捕获画面。
/// 浮窗 `collectionBehavior` 含 `.canJoinAllSpaces`，因此可以跨 Space 可见——
/// 这是镜像方案相对真置顶的体验优势。
///
/// 协议语义映射：
/// - `setWindowLevel(id, floating)` → 为该窗口创建镜像浮窗（幂等）。
/// - `setWindowLevel(id, normal)`   → 销毁该窗口的镜像浮窗（幂等）。
/// - `windowLevel(for:)`            → 有镜像返回 floating，否则返回 normal。
///   （协调器的"设级后读回验证"逻辑因此无需改动即可通过。）
///
/// 线程模型：引擎本体非 actor 隔离（协议要求），内部用锁保护会话表；
/// UI/捕获对象 `MirrorSession` 为 @MainActor，创建与操作均跳到主线程。
final class MirrorPinningEngine: NSObject, WindowPinningEngine {
    let engineName = "Mirror"
    /// 镜像引擎基于 ScreenCaptureKit（macOS 14+ 部署目标保证可用）。
    var isAvailable: Bool { true }

    // MARK: - 回调（由 AppState 接线到 PinningCoordinator）

    /// 用户点击镜像浮窗关闭按钮时请求取消置顶（接到 coordinator.unpin）。
    var onRequestUnpin: ((CGWindowID) -> Void)?
    /// 镜像建立失败/捕获中断（窗口消失、无权限等），用于清状态并提示用户。
    var onMirrorFailed: ((CGWindowID, String) -> Void)?

    /// 「取消置顶时把源窗口移动到镜像浮窗最后位置」开关（v1.3，由 AppState 从持久化同步）。
    var moveSourceOnUnpin: Bool = false

    // MARK: - 状态

    /// 会话表锁（引擎方法可能从非主线程被调用）。
    private let lock = NSLock()
    /// 已标记为"镜像中"的窗口集合（同步维护，保证设级后立即读回 floating）。
    private var mirroredIDs: Set<CGWindowID> = []
    /// 活跃镜像会话：windowID → session（异步建立，建立前可能暂无条目）。
    private var sessions: [CGWindowID: MirrorSession] = [:]
    /// 源窗口存活/几何巡检定时器（主线程）。
    private var watchdog: Timer?

    override init() {
        super.init()
        Log.pinning.info("MirrorPinningEngine ready")
    }

    // MARK: - WindowPinningEngine

    func windowLevel(for windowID: CGWindowID) -> Int32? {
        lock.lock()
        let mirrored = mirroredIDs.contains(windowID)
        lock.unlock()
        return mirrored ? PinningLevel.floating : PinningLevel.normal
    }

    @discardableResult
    func setWindowLevel(_ windowID: CGWindowID, to level: Int32) -> Bool {
        if level == PinningLevel.floating {
            // F2: 预检窗口存在性——窗口已销毁时直接失败（协调器读回验证自然回滚），
            // 避免"假成功"后靠巡检自愈，且 mirroredIDs 不会被污染。
            guard Self.windowBounds(for: windowID) != nil else {
                Log.pinning.error("setWindowLevel(\(windowID), floating) failed: window no longer exists")
                return false
            }
            lock.lock()
            let already = mirroredIDs.contains(windowID)
            if !already { mirroredIDs.insert(windowID) }
            lock.unlock()
            guard !already else { return true }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let session = MirrorSession(windowID: windowID)
                session.onRequestClose = { [weak self] id in
                    guard let self else { return }
                    if let handler = self.onRequestUnpin {
                        handler(id) // 走 coordinator.unpin，统一清状态并销毁镜像
                    } else {
                        _ = self.setWindowLevel(id, to: PinningLevel.normal)
                    }
                }
                session.onFailure = { [weak self] id, message in
                    guard let self else { return }
                    self.lock.lock()
                    self.mirroredIDs.remove(id)
                    self.sessions.removeValue(forKey: id)
                    self.lock.unlock()
                    self.onMirrorFailed?(id, message)
                }
                // 镜像销毁后：若开启设置且浮窗被用户拖动过，把源窗口移到浮窗最后位置。
                session.onDidStop = { [weak self] id, pid, draggedFrame in
                    guard let self, self.moveSourceOnUnpin, let frame = draggedFrame else { return }
                    let topLeft = Self.axTopLeft(fromCocoaFrame: frame)
                    Log.pinning.info("unpin: moving source window \(id) to \(topLeft)")
                    AXHelper.moveWindow(id: id, of: pid, toTopLeft: topLeft)
                }
                // F1: NSLock 在 Swift 6 语言模式下禁止从异步上下文直接调用（noasync），
                // 锁操作抽取到同步方法 registerSessionIfStillWanted 中完成。
                // 若期间已被取消（unpin 先于异步建立完成），直接丢弃会话，不启动捕获。
                let stillWanted = self.registerSessionIfStillWanted(session, for: windowID)
                guard stillWanted else { return }
                await session.start()
            }
            return true
        } else {
            lock.lock()
            mirroredIDs.remove(windowID)
            let session = sessions.removeValue(forKey: windowID)
            lock.unlock()
            if let session {
                Task { @MainActor in await session.stop() }
            }
            return true
        }
    }

    /// 登记镜像会话（同步区，供异步建立流程回调）。
    ///
    /// 若登记时该窗口已被 unpin（mirroredIDs 中已移除），返回 false，
    /// 调用方应丢弃会话且不启动捕获。
    private func registerSessionIfStillWanted(_ session: MirrorSession, for windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mirroredIDs.contains(windowID) else { return false }
        sessions[windowID] = session
        return true
    }

    // MARK: - 巡检（源窗口跟随与销毁清理）

    /// 启动巡检定时器（幂等，须在主线程调用；AppState.start() 中调用）。
    ///
    /// 职责：
    /// 1. 源窗口被关闭时销毁对应镜像（协调器的 prune 负责清 pinned 状态）。
    /// 2. 源窗口移动/缩放时同步浮窗位置与捕获分辨率。
    func startWatchdog() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startWatchdog() }
            return
        }
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollSessions()
        }
        Log.pinning.debug("mirror watchdog started")
    }

    private func pollSessions() {
        lock.lock()
        let ids = Array(mirroredIDs)
        let snapshot = sessions
        lock.unlock()

        for id in ids {
            guard let bounds = Self.windowBounds(for: id) else {
                Log.pinning.info("source window \(id) gone, destroying mirror")
                _ = setWindowLevel(id, to: PinningLevel.normal)
                continue
            }
            if let session = snapshot[id] {
                Task { @MainActor in session.updateBounds(bounds) }
            }
        }
    }

    // MARK: - 窗口几何工具

    /// 读取窗口在 CGWindowList 坐标系（主屏左上角原点、y 向下）中的 bounds。
    static func windowBounds(for windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let dict = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    /// CGWindowList（左上原点）→ AppKit（左下原点）坐标转换。
    static func cocoaFrame(forTopLeftBounds bounds: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.maxY
        return CGRect(x: bounds.minX,
                      y: primaryHeight - bounds.maxY,
                      width: bounds.width,
                      height: bounds.height)
    }

    /// AppKit 窗口 frame（左下原点）→ AX 坐标系左上角点（主屏左上原点、y 向下）。
    static func axTopLeft(fromCocoaFrame frame: CGRect) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
    }

    /// 窗口所在屏幕的 backingScaleFactor（用于捕获分辨率）。
    static func scaleFactor(forTopLeftBounds bounds: CGRect) -> CGFloat {
        let cocoa = cocoaFrame(forTopLeftBounds: bounds)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoa) }) ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2.0
    }
}

// MARK: - 单路镜像会话

/// 一路镜像 = 一个 SCStream（捕获源窗口）+ 一个 NSPanel（渲染画面）。
///
/// 生命周期由 MirrorPinningEngine 管理：start() 建立捕获与浮窗，
/// stop() 停止流并销毁浮窗。捕获失败/中断通过 onFailure 上报。
@MainActor
final class MirrorSession: NSObject {
    /// 帧格式转换上下文（CIContext 线程安全，全 session 共享一个实例）。
    private nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    let windowID: CGWindowID

    /// 点击浮窗关闭按钮（引擎接到 coordinator.unpin）。
    var onRequestClose: ((CGWindowID) -> Void)?
    /// 建立失败或捕获中断（引擎负责清状态并提示）。
    var onFailure: ((CGWindowID, String) -> Void)?
    /// 会话完全停止后回调：第三参为"被用户拖动后的浮窗 frame"（AppKit 坐标）；
    /// 浮窗位置与源窗口一致（未拖动）时为 nil。
    var onDidStop: ((CGWindowID, pid_t, CGRect?) -> Void)?

    private var stream: SCStream?
    private var panel: NSPanel?
    private weak var contentLayer: CALayer?
    private var pid: pid_t = 0
    private var lastBounds: CGRect = .zero
    private var stopped = false
    /// 镜像缩放倍率（v1.4，浮窗右键菜单调节，会话内有效，默认 100%）。
    private(set) var scale: CGFloat = 1.0
    /// 可选缩放档位。
    static let scaleOptions: [CGFloat] = [0.5, 0.75, 1.0, 1.5, 2.0]
    /// 镜像不透明度（v1.4.2，右键菜单滑杆调节，范围 50%~100%，默认 100%）。
    private(set) var opacity: CGFloat = 1.0
    /// 不透明度下限（低于 50% 基本看不清，且容易"找不到窗口"）。
    static let minOpacity: CGFloat = 0.5
    /// 采样回调队列（SCStreamOutput 在此串行队列上回调）。
    private let captureQueue = DispatchQueue(label: "com.winpin.mirror.capture", qos: .userInitiated)

    init(windowID: CGWindowID) {
        self.windowID = windowID
        super.init()
    }

    // MARK: - 建立 / 销毁

    /// 建立捕获流与镜像浮窗；失败时自行清理并通过 onFailure 上报。
    func start() async {
        do {
            guard CGPreflightScreenCaptureAccess() else {
                throw MirrorError.noScreenCapturePermission
            }
            let content = try await SCShareableContent.current
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                throw MirrorError.windowUnavailable
            }
            pid = scWindow.owningApplication?.processID ?? 0

            createPanel(initialBounds: scWindow.frame)

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = Self.makeConfiguration(forTopLeftBounds: scWindow.frame)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            self.stream = stream
            Log.pinning.info("mirror started for window \(windowID), pid=\(pid), bounds=\(scWindow.frame)")
        } catch {
            Log.pinning.error("mirror start failed for \(windowID): \(error.localizedDescription)")
            await stop()
            onFailure?(windowID, "镜像置顶失败：\(error.localizedDescription)")
        }
    }

    /// 停止捕获并销毁浮窗（幂等）。
    func stop() async {
        guard !stopped else { return }
        stopped = true
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        // 判定浮窗是否被用户拖动过：当前 frame 与"贴合源窗口的应有位置"不一致即视为拖动过。
        // （watchdog 仅在源窗口几何变化时才回写 frame，用户拖动的位置不会被覆盖。）
        var draggedFrame: CGRect?
        if let panel {
            let expected = fittedFrame()
            if panel.frame != expected {
                draggedFrame = panel.frame
            }
        }
        panel?.close()
        panel = nil
        Log.pinning.info("mirror stopped for window \(windowID)")
        onDidStop?(windowID, pid, draggedFrame)
    }

    // MARK: - 几何跟随

    /// 按当前缩放倍率计算"贴合源窗口"的浮窗 frame（AppKit 坐标，锚定源窗口左上角）。
    private func fittedFrame() -> CGRect {
        let cocoa = MirrorPinningEngine.cocoaFrame(forTopLeftBounds: lastBounds)
        return CGRect(x: cocoa.minX,
                      y: cocoa.maxY - cocoa.height * scale,
                      width: cocoa.width * scale,
                      height: cocoa.height * scale)
    }

    /// 调整缩放倍率（v1.4 右键菜单）：以浮窗当前左上角为锚点重设尺寸，位置不跳。
    func setScale(_ newScale: CGFloat) {
        guard !stopped, Self.scaleOptions.contains(newScale), newScale != scale else { return }
        scale = newScale
        guard let panel else { return }
        let cocoa = MirrorPinningEngine.cocoaFrame(forTopLeftBounds: lastBounds)
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX,
                              y: top - cocoa.height * scale,
                              width: cocoa.width * scale,
                              height: cocoa.height * scale),
                       display: true)
        Log.pinning.info("mirror \(windowID) scale -> \(Int((scale * 100).rounded()))%")
    }

    /// 调整不透明度（v1.4.2 右键菜单滑杆）：实时作用于浮窗，拖动滑杆即时预览。
    func setOpacity(_ value: CGFloat) {
        guard !stopped else { return }
        let clamped = min(max(value, Self.minOpacity), 1.0)
        opacity = clamped
        panel?.alphaValue = clamped
    }

    /// 源窗口移动/缩放时同步浮窗位置与捕获分辨率（巡检定时器驱动）。
    func updateBounds(_ bounds: CGRect) {
        guard !stopped, bounds != lastBounds else { return }
        lastBounds = bounds
        panel?.setFrame(fittedFrame(), display: true)
        guard let stream else { return }
        let config = Self.makeConfiguration(forTopLeftBounds: bounds)
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                Log.pinning.debug("mirror updateConfiguration failed for \(self.windowID): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 浮窗

    private func createPanel(initialBounds: CGRect) {
        lastBounds = initialBounds
        let frame = MirrorPinningEngine.cocoaFrame(forTopLeftBounds: initialBounds)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        // 跨 Space 可见 + 全屏 App 之上可悬浮（镜像方案超越真置顶的关键）。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "winpin 镜像"

        let contentView = MirrorContentView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.onClick = { [weak self] in self?.activateSource() }
        contentView.onDoubleClick = { [weak self] in
            guard let self else { return }
            Log.pinning.info("mirror double-clicked, unpinning window \(self.windowID)")
            self.onRequestClose?(self.windowID)
        }
        // 右键菜单（v1.4 缩放档位 / v1.4.2 透明度滑杆 / 取消置顶）。
        contentView.scaleOptions = MirrorSession.scaleOptions
        contentView.currentScale = { [weak self] in self?.scale ?? 1.0 }
        contentView.onSelectScale = { [weak self] value in self?.setScale(value) }
        contentView.currentOpacity = { [weak self] in self?.opacity ?? 1.0 }
        contentView.onChangeOpacity = { [weak self] value in self?.setOpacity(value) }
        contentView.onRequestUnpin = { [weak self] in
            guard let self else { return }
            self.onRequestClose?(self.windowID)
        }
        contentView.toolTip = "按住拖动移动 · 单击跳回原窗口 · 双击取消置顶 · 右键菜单（缩放/透明度）"
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.cornerRadius = 4
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor.systemGray.withAlphaComponent(0.6).cgColor
        contentView.layer = layer
        contentView.wantsLayer = true
        panel.contentView = contentView
        contentLayer = layer

        // 关闭（取消置顶）按钮：右上角小圆钮。
        if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "取消置顶") {
            let button = NSButton(frame: NSRect(x: frame.width - 26, y: frame.height - 26, width: 20, height: 20))
            button.image = image
            button.isBordered = false
            button.contentTintColor = .white
            button.toolTip = "取消置顶"
            button.autoresizingMask = [.minXMargin, .minYMargin]
            button.target = self
            button.action = #selector(closeTapped(_:))
            contentView.addSubview(button)
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    @objc private func closeTapped(_ sender: NSButton) {
        Log.pinning.info("mirror close button tapped for \(windowID)")
        onRequestClose?(windowID)
    }

    /// 点击镜像画面：激活源 App 并尝试 raise 源窗口（AX 无权限时静默降级为仅激活 App）。
    private func activateSource() {
        guard pid != 0 else { return }
        AXHelper.activateApp(of: pid)
        AXHelper.raiseWindow(id: windowID, of: pid)
        Log.pinning.info("mirror clicked, activating pid=\(pid) window=\(windowID)")
    }

    // MARK: - 捕获配置

    private static func makeConfiguration(forTopLeftBounds bounds: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = MirrorPinningEngine.scaleFactor(forTopLeftBounds: bounds)
        config.width = max(Int(bounds.width * scale), 1)
        config.height = max(Int(bounds.height * scale), 1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20) // 20 fps，兼顾流畅与开销
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        return config
    }
}

// MARK: - SCStream 回调

extension MirrorSession: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // BGRA pixelBuffer → CGImage（CIContext 硬件加速，开销可忽略）。
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = MirrorSession.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.contentLayer?.contents = cgImage
        }
    }
}

extension MirrorSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.pinning.error("mirror stream stopped with error: \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            await self.stop()
            self.onFailure?(self.windowID, "镜像捕获中断：\(error.localizedDescription)")
        }
    }
}

// MARK: - 浮窗内容视图

/// 镜像浮窗的内容视图。
///
/// 手势分工（对齐 macOS 画中画的习惯）：
/// - 按住拖动（位移 ≥ 4pt）→ 移动浮窗（无边框浮窗没有标题栏，由本视图接管拖动）；
/// - 单击（几乎无位移）→ 激活并跳回源窗口；
/// - 双击 → 取消置顶；
/// - 右键 → 上下文菜单（缩放档位 + 取消置顶，v1.4）。
final class MirrorContentView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// 右键菜单数据源（由 MirrorSession 接线）。
    var scaleOptions: [CGFloat] = []
    var currentScale: (() -> CGFloat)?
    var onSelectScale: ((CGFloat) -> Void)?
    var currentOpacity: (() -> CGFloat)?
    var onChangeOpacity: ((CGFloat) -> Void)?
    var onRequestUnpin: (() -> Void)?

    /// 区分"单击"与"拖动"的位移阈值。
    private let clickSlop: CGFloat = 4
    /// mouseDown 时相对窗口的位置（拖动期间以此为基准）。
    private var dragStartInWindow: NSPoint?
    private var didDrag = false
    /// 右键菜单中透明度滑杆旁的百分比标签（拖动滑杆时实时刷新）。
    private weak var opacityPctLabel: NSTextField?

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push() // 悬停手掌光标，提示可拖动
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartInWindow = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStartInWindow else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        if !didDrag {
            guard hypot(dx, dy) >= clickSlop else { return }
            didDrag = true
        }
        NSCursor.closedHand.set()
        // locationInWindow 以窗口为参照，窗口随手移动，因此每帧把窗口原点平移一个增量即可。
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx,
                                      y: window.frame.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = didDrag
        dragStartInWindow = nil
        didDrag = false
        if wasDrag {
            NSCursor.openHand.set()
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    // MARK: - 右键上下文菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let scaleItem = NSMenuItem(title: "镜像缩放", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for option in scaleOptions {
            let pct = Int((option * 100).rounded())
            let item = NSMenuItem(title: "\(pct)%",
                                  action: #selector(scaleItemTapped(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(option))
            item.state = (currentScale?() == option) ? .on : .off
            sub.addItem(item)
        }
        menu.setSubmenu(sub, for: scaleItem)
        menu.addItem(scaleItem)

        // 透明度滑杆（自定义视图菜单项，拖动实时生效，范围 50%~100%）。
        menu.addItem(makeOpacityItem())

        menu.addItem(.separator())

        let unpinItem = NSMenuItem(title: "取消置顶",
                                   action: #selector(unpinItemTapped(_:)),
                                   keyEquivalent: "")
        unpinItem.target = self
        menu.addItem(unpinItem)

        return menu
    }

    /// 构造"镜像透明度"滑杆菜单项（标签 + 滑杆 + 百分比）。
    private func makeOpacityItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 44))

        let titleLabel = NSTextField(labelWithString: "镜像透明度")
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.frame = NSRect(x: 18, y: 22, width: 120, height: 16)
        container.addSubview(titleLabel)

        let initial = Double(currentOpacity?() ?? 1.0)
        let slider = NSSlider(value: initial, minValue: 0.5, maxValue: 1.0,
                              target: self, action: #selector(opacitySliderChanged(_:)))
        slider.isContinuous = true // 拖动过程实时预览
        slider.frame = NSRect(x: 18, y: 2, width: 152, height: 20)
        container.addSubview(slider)

        let pctLabel = NSTextField(labelWithString: "\(Int((initial * 100).rounded()))%")
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pctLabel.alignment = .right
        pctLabel.frame = NSRect(x: 176, y: 4, width: 40, height: 16)
        container.addSubview(pctLabel)
        opacityPctLabel = pctLabel

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue)
        opacityPctLabel?.stringValue = "\(Int((value * 100).rounded()))%"
        onChangeOpacity?(value)
    }

    @objc private func scaleItemTapped(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onSelectScale?(CGFloat(number.doubleValue))
    }

    @objc private func unpinItemTapped(_ sender: NSMenuItem) {
        onRequestUnpin?()
    }
}

// MARK: - 错误

/// 镜像建立阶段的错误（文案直接面向用户）。
private enum MirrorError: LocalizedError {
    case noScreenCapturePermission
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .noScreenCapturePermission:
            return "缺少屏幕录制权限，请在「系统设置 → 隐私与安全性 → 屏幕录制」中授权 winpin 后重试。"
        case .windowUnavailable:
            return "目标窗口已不可用（可能已关闭或最小化异常）。"
        }
    }
}
