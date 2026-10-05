import Foundation
import OSLog

/// 统一日志封装，按模块划分子系统分类。
///
/// 除 os_log 外，同时镜像写入 /tmp/winpin_debug.log，
/// 便于在没有 log stream 权限的环境下排查问题（临时调试手段）。
///
/// 用法：`Log.pinning.info("pinned \(wid)")`
final class Log {
    private static let subsystem = "com.winpin.app"

    /// 置顶引擎相关日志。
    static let pinning = Log(category: "pinning")
    /// 窗口枚举相关日志。
    static let enumerator = Log(category: "enumerator")
    /// 权限相关日志。
    static let permission = Log(category: "permission")
    /// 快捷键相关日志。
    static let hotkey = Log(category: "hotkey")
    /// UI 相关日志。
    static let ui = Log(category: "ui")
    /// App 生命周期相关日志。
    static let app = Log(category: "app")

    private let osLogger: Logger
    private let category: String
    private static let lock = NSLock()
    private static let fileURL = URL(fileURLWithPath: "/tmp/winpin_debug.log")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init(category: String) {
        self.category = category
        self.osLogger = Logger(subsystem: Log.subsystem, category: category)
    }

    func info(_ message: @autoclosure () -> String) {
        let msg = message()
        osLogger.info("\(msg, privacy: .public)")
        mirror(level: "INFO", msg)
    }

    func debug(_ message: @autoclosure () -> String) {
        let msg = message()
        osLogger.debug("\(msg, privacy: .public)")
        mirror(level: "DEBUG", msg)
    }

    func error(_ message: @autoclosure () -> String) {
        let msg = message()
        osLogger.error("\(msg, privacy: .public)")
        mirror(level: "ERROR", msg)
    }

    /// 镜像写入本地调试文件（追加）。Release 正式版不写文件。
    private func mirror(level: String, _ msg: String) {
        #if DEBUG
        let line = "\(Log.dateFormatter.string(from: Date())) [\(category)] [\(level)] \(msg)\n"
        Log.lock.lock()
        defer { Log.lock.unlock() }
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            FileManager.default.createFile(atPath: Log.fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: Log.fileURL),
              let data = line.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
        #endif
    }
}
