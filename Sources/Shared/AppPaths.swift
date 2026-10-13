import Darwin
import Foundation

/// 全局路径。
///
/// ⚠️ 这里**绝不能**用 `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`：
/// 主 App 与小组件扩展都在沙箱里跑，那个 API 会返回各自容器内的路径
/// （`~/Library/Containers/<bundle-id>/Data/Library/Application Support`），
/// 于是两边各写各的、永远读不到对方的数据。
///
/// 统一用 passwd 里的真实 HOME 拼绝对路径，再配合 entitlements 里的定向文件豁免，
/// 两个进程才会指向同一个文件。
enum AppPaths {

    /// 真实用户主目录（沙箱下也拿得到；环境变量优先，方便测试隔离）
    static var realHome: String {
        if let override = ProcessInfo.processInfo.environment["AIRWEAR_HOME"], !override.isEmpty {
            return override
        }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// `~/Library/Application Support/AirWear/`
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRWEAR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/AirWear", isDirectory: true)
    }

    /// `~/Library/Logs/AirWear/`
    static var logDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRWEAR_LOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Logs/AirWear", isDirectory: true)
    }

    static var sessionsFile: URL { dataDirectory.appendingPathComponent("sessions.sqlite3") }
    static var snapshotFile: URL { dataDirectory.appendingPathComponent("widget.json") }
    static var widgetTraceFile: URL { dataDirectory.appendingPathComponent("widget-ran.log") }
    static var logFile: URL { logDirectory.appendingPathComponent("AirWear.log") }
}
