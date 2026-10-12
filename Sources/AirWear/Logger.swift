import Foundation

/// 简易日志：同时输出到 stdout 与 ~/Library/Logs/AirWear/AirWear.log。
enum Log {
    private static let queue = DispatchQueue(label: "com.airwear.log")

    private static let fileURL: URL = {
        // 默认 ~/Library/Logs/AirWear/；沙箱下必须用真实 home 拼绝对路径（见 AppPaths）
        let dir = AppPaths.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppPaths.logFile
    }()

    static var logPath: String { fileURL.path }

    /// 日志文件超过 2MB 就截断，避免长期常驻无限增长
    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > 2_000_000 else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func info(_ message: @autoclosure () -> String) { emit("INFO", message()) }
    static func error(_ message: @autoclosure () -> String) { emit("ERROR", message()) }

    private static func emit(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [\(level)] \(message)"
        print(line)
        // 同步写盘：日志量很小，且异步写在 CLI 路径下会被随后的 exit(0) 掐死
        queue.sync {
            rotateIfNeeded()
            if let fh = try? FileHandle(forWritingTo: fileURL) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: Data((line + "\n").utf8))
            } else {
                try? (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
