import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 全局快捷键管理器（Carbon RegisterEventHotKey，零三方依赖，计划 §7 备注）。
///
/// 默认快捷键：
/// - `⌃⌥P`   切换前台窗口置顶
/// - `⌃⌥⇧P` 取消所有置顶
/// 快捷键可在设置页自定义；注册失败（被占用）时回调错误供 UI 提示。
final class HotKeyManager {
    /// 一组快捷键定义（Carbon 虚拟键码 + Carbon 修饰键位）。
    struct HotKey: Codable, Equatable {
        /// Carbon 虚拟键码（如 kVK_ANSI_P = 0x23）。
        var keyCode: UInt32
        /// Carbon 修饰键组合（cmdKey/optionKey/controlKey/shiftKey）。
        var carbonModifiers: UInt32
        /// 展示用字符串（如 "⌃⌥P"），随定义一并持久化，避免反解键码。
        var display: String

        /// 默认「切换前台窗口置顶」：⌃⌥P。
        static let defaultToggle = HotKey(
            keyCode: UInt32(kVK_ANSI_P),
            carbonModifiers: UInt32(controlKey | optionKey),
            display: "⌃⌥P"
        )
        /// 默认「取消所有置顶」：⌃⌥⇧P。
        static let defaultUnpinAll = HotKey(
            keyCode: UInt32(kVK_ANSI_P),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey),
            display: "⌃⌥⇧P"
        )
    }

    /// 快捷键动作标识（同时作为 EventHotKeyID.id）。
    enum Action: UInt32 {
        case toggleFront = 1
        case unpinAll = 2
    }

    // MARK: - 回调

    /// 「切换前台窗口置顶」触发回调（主线程）。
    var onToggleFront: () -> Void = {}
    /// 「取消所有置顶」触发回调（主线程）。
    var onUnpinAll: () -> Void = {}
    /// 注册失败回调（快捷键冲突等）。
    var onRegisterFailed: (Action, HotKey) -> Void = { _, _ in }

    // MARK: - 私有状态

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var currentKeys: [Action: HotKey] = [:]
    private var eventHandlerRef: EventHandlerRef?

    deinit {
        unregisterAll()
        // F4: 事件处理器经 passUnretained 持有 self，必须一并移除，否则实例销毁后悬垂。
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    // MARK: - 注册

    /// 安装事件处理器并按给定快捷键完成初始注册。
    func start(toggle: HotKey, unpinAll: HotKey) {
        installEventHandlerIfNeeded()
        update(.toggleFront, to: toggle)
        update(.unpinAll, to: unpinAll)
    }

    /// 更新某个动作的快捷键（先注销旧的，注册失败会回调 onRegisterFailed）。
    func update(_ action: Action, to hotKey: HotKey) {
        unregister(action)
        // F5: 注册成功后才写 currentKeys，避免展示未注册成功的键。
        currentKeys.removeValue(forKey: action)

        let hotKeyID = EventHotKeyID(signature: OSType(0x7770_696E), // 'wpin'
                                     id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[action] = ref
            currentKeys[action] = hotKey
            Log.hotkey.info("registered \(hotKey.display) for action \(action.rawValue)")
        } else {
            Log.hotkey.error("RegisterEventHotKey failed (\(status)) for \(hotKey.display)")
            onRegisterFailed(action, hotKey)
        }
    }

    /// 注销全部快捷键。
    func unregisterAll() {
        // F10: 先快照 keys 再遍历删除，不依赖 COW 行为。
        for action in Array(hotKeyRefs.keys) {
            unregister(action)
        }
        currentKeys.removeAll()
    }

    /// 当前已注册的快捷键（供设置页展示）。
    func hotKey(for action: Action) -> HotKey? {
        currentKeys[action]
    }

    // MARK: - 私有

    private func unregister(_ action: Action) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            HotKeyManager.eventHandlerUPP,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    /// Carbon 事件处理回调（C 约定，经 userData 找回实例）。
    private static let eventHandlerUPP: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return OSStatus(eventNotHandledErr) }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        guard let action = Action(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }
        // Carbon 回调已在主线程，直接派发。
        DispatchQueue.main.async {
            switch action {
            case .toggleFront: manager.onToggleFront()
            case .unpinAll: manager.onUnpinAll()
            }
        }
        return noErr
    }
}
