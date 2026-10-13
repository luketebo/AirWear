import Darwin
import Foundation

/// 主 App → 小组件 的单向数据桥。
///
/// 为什么不让小组件直接查会话数据库：
/// 1. 小组件进程是**沙箱**的（App Group 或临时豁免才能读外部文件），能少碰就少碰；
/// 2. 统计口径（L1/L2/L3 怎么折算成「佩戴」）必须只有一处实现，否则两边数字会飘；
/// 3. 小组件每次刷新有时间预算，读一个几百字节的扁平快照比遍历区间便宜得多。
///
/// 所以：主 App 把算好的结果写成 `widget.json`，小组件只负责画。
struct WidgetSnapshot: Codable, Equatable {

    struct Day: Codable, Equatable {
        var label: String
        var wornMinutes: Int
        var activeMinutes: Int
    }

    var generatedAt: Date = Date()
    /// absent | idle | active
    var state: String = "absent"
    /// 是否有真实数据。false = 主 App 还没写过快照，小组件要显示「暂无数据」而不是假装有值
    var hasData: Bool = true
    var deviceName: String?
    var todayWornMinutes: Int = 0
    var todayActiveMinutes: Int = 0
    var todayConnectedMinutes: Int = 0
    var stretchMinutes: Int = 0
    var breakWarning: Bool = false
    var goalMinutes: Int = 180
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// 最近 7 天，从早到晚
    var week: [Day] = []

    // MARK: - 路径

    /// 真实用户主目录（沙箱下不能用 FileManager 的 applicationSupportDirectory，见 AppPaths）
    static var realHome: String { AppPaths.realHome }

    static var fileURL: URL { AppPaths.snapshotFile }

    // MARK: - 读写

    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = WidgetSnapshot.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 展示辅助

    var stateLabel: String {
        switch state {
        case "active": return "佩戴中 · 正在出声"
        case "idle": return "已连接 · 未出声"
        default: return "未连接"
        }
    }

    var wornText: String { Self.compact(todayWornMinutes) }
    var stretchText: String { Self.compact(stretchMinutes) }

    /// 0…1（超过目标也只回报 1，条形图自己画满）
    var goalProgress: Double {
        guard goalMinutes > 0 else { return 0 }
        return Double(todayWornMinutes) / Double(goalMinutes)
    }

    var overGoal: Bool { goalMinutes > 0 && todayWornMinutes >= goalMinutes }

    static func compact(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }

    /// 主 App 还没写出第一份快照时，小组件画廊里显示的样子
    static let placeholder = WidgetSnapshot(
        generatedAt: Date(),
        state: "active",
        hasData: true,
        deviceName: "AirPods",
        todayWornMinutes: 134,
        todayActiveMinutes: 96,
        todayConnectedMinutes: 220,
        stretchMinutes: 46,
        breakWarning: false,
        goalMinutes: 180,
        left: 62,
        right: 58,
        caseLevel: 74,
        week: [
            Day(label: "一", wornMinutes: 86, activeMinutes: 52),
            Day(label: "二", wornMinutes: 140, activeMinutes: 101),
            Day(label: "三", wornMinutes: 52, activeMinutes: 28),
            Day(label: "四", wornMinutes: 168, activeMinutes: 114),
            Day(label: "五", wornMinutes: 95, activeMinutes: 60),
            Day(label: "六", wornMinutes: 120, activeMinutes: 75),
            Day(label: "日", wornMinutes: 134, activeMinutes: 96),
        ]
    )

    /// 读不到主 App 的快照时用它，好让「扩展跑了但读不到数据」一眼可见
    static let unavailable = WidgetSnapshot(
        generatedAt: Date(),
        state: "absent",
        hasData: false,
        deviceName: nil,
        todayWornMinutes: 0,
        todayActiveMinutes: 0,
        todayConnectedMinutes: 0,
        stretchMinutes: 0,
        breakWarning: false,
        goalMinutes: 180,
        left: nil, right: nil, caseLevel: nil,
        week: []
    )
}
