import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 窗口枚举器：负责枚举当前可见窗口并生成缩略图。
///
/// - 枚举：`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`，
///   仅保留 layer 0 的普通 App 窗口，过滤自身进程与过小/异常窗口。
/// - 缩略图：ScreenCaptureKit `SCScreenshotManager`（macOS 14+），
///   结果缓存在内存中，面板刷新时按 windowID 复用。
final class WindowEnumerator {
    /// 缩略图内存缓存（key 为 windowID）。F9: 设 countLimit 防止无界增长。
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    /// 枚举当前所有可见的普通窗口，按前后台 Z 序返回（列表序即 Z 序，前到后）。
    func enumerateWindows() -> [WindowModel] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            Log.enumerator.error("CGWindowListCopyWindowInfo returned nil")
            return []
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowModel] = []
        result.reserveCapacity(rawList.count)

        for entry in rawList {
            guard let windowNumber = entry[kCGWindowNumber as String] as? UInt32,
                  windowNumber != 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID > 0, ownerPID != myPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 50, bounds.height >= 50
            else { continue }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "未知应用"
            // 排除已知系统 UI 进程，避免列出无法置顶的窗口。
            if WindowEnumerator.excludedOwnerNames.contains(ownerName) { continue }

            let title = entry[kCGWindowName as String] as? String ?? ""
            let icon = NSRunningApplication(processIdentifier: ownerPID)?.icon

            result.append(WindowModel(
                id: windowNumber,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title,
                bounds: bounds,
                appIcon: icon
            ))
        }
        return result
    }

    /// 生成指定窗口的缩略图；无权限或窗口已消失时返回 nil。
    /// 结果写入缓存，重复调用命中缓存。
    func thumbnail(for windowID: CGWindowID, maxSize: CGSize = CGSize(width: 160, height: 100)) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: NSNumber(value: windowID)) {
            return cached
        }
        guard CGPreflightScreenCaptureAccess() else { return nil }

        do {
            let content = try await SCShareableContent.current
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = min(maxSize.width / scWindow.frame.width,
                            maxSize.height / scWindow.frame.height, 1.0)
            config.width = max(Int(scWindow.frame.width * scale), 1)
            config.height = max(Int(scWindow.frame.height * scale), 1)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: config.width, height: config.height))
            thumbnailCache.setObject(image, forKey: NSNumber(value: windowID))
            return image
        } catch {
            Log.enumerator.debug("thumbnail failed for \(windowID): \(error.localizedDescription)")
            return nil
        }
    }

    /// 清空缩略图缓存（用户手动刷新时调用）。
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    /// 不应出现在列表中的系统进程名。
    private static let excludedOwnerNames: Set<String> = [
        "Dock", "WindowManager", "Control Center", "控制中心",
        "Notification Center", "Spotlight", "winpin",
    ]
}
