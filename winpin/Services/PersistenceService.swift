import Foundation

/// 持久化服务：UserDefaults 封装。
///
/// v1.0 保存：自定义快捷键、首启引导标记、开机自启动意愿。
/// 按用户决策 **不做**「重启恢复置顶」，故不持久化置顶列表。
final class PersistenceService {
    private let defaults: UserDefaults

    private enum Key: String {
        case toggleHotKey = "hotkey.toggleFront"
        case unpinAllHotKey = "hotkey.unpinAll"
        case onboardingShown = "onboarding.shown"
        case moveSourceOnUnpin = "behavior.moveSourceOnUnpin"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 快捷键

    /// 「切换前台窗口置顶」快捷键，默认 ⌃⌥P。
    var toggleHotKey: HotKeyManager.HotKey {
        get { loadHotKey(.toggleHotKey) ?? .defaultToggle }
        set { saveHotKey(newValue, .toggleHotKey) }
    }

    /// 「取消所有置顶」快捷键，默认 ⌃⌥⇧P。
    var unpinAllHotKey: HotKeyManager.HotKey {
        get { loadHotKey(.unpinAllHotKey) ?? .defaultUnpinAll }
        set { saveHotKey(newValue, .unpinAllHotKey) }
    }

    // MARK: - 首启引导

    /// 首启引导是否已展示过。
    var onboardingShown: Bool {
        get { defaults.bool(forKey: Key.onboardingShown.rawValue) }
        set { defaults.set(newValue, forKey: Key.onboardingShown.rawValue) }
    }

    // MARK: - 行为

    /// 取消置顶时，是否把源窗口移动到镜像浮窗最后停留的位置（v1.3，默认关闭）。
    var moveSourceOnUnpin: Bool {
        get { defaults.bool(forKey: Key.moveSourceOnUnpin.rawValue) }
        set { defaults.set(newValue, forKey: Key.moveSourceOnUnpin.rawValue) }
    }

    // MARK: - 私有

    private func loadHotKey(_ key: Key) -> HotKeyManager.HotKey? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(HotKeyManager.HotKey.self, from: data)
    }

    private func saveHotKey(_ hotKey: HotKeyManager.HotKey, _ key: Key) {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: key.rawValue)
        }
    }
}
