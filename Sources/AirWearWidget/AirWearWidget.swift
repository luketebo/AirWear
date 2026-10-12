import SwiftUI
import WidgetKit

// 这个文件被编译两次：
//   · 小组件扩展：-D AIRWEAR_WIDGET_EXTENSION，@main 入口就是 WidgetBundle
//   · 主 App：不带该宏，于是 @main 被排除，只借用视图代码做「离屏渲染预览」
//     （本机没有屏幕录制权限，截不了桌面，预览图是唯一能自查小组件长相的手段）

// MARK: - 运行痕迹

/// 扩展进程被系统加载时留一行痕迹。
///
/// 为什么需要它：小组件跑在 chronod 里，宿主 App 拿不到它的 stdout；
/// 本机又没有屏幕录制权限（截不了桌面）、`pluginkit -m` 与统一日志也被系统拒绝，
/// 于是「扩展到底有没有被执行」只能靠它自己落盘来证明。
/// 你每打开一次小组件画廊、或系统刷新一次时间线，这里就会多一行。
enum WidgetTrace {

    static var logURL: URL {
        WidgetSnapshot.fileURL.deletingLastPathComponent().appendingPathComponent("widget-ran.log")
    }

    static func record(_ event: String, loaded: Bool? = nil, isPreview: Bool? = nil) {
        var parts = [ISO8601DateFormatter().string(from: Date()), event, "pid=\(getpid())"]
        if let loaded = loaded { parts.append("loaded=\(loaded)") }
        if let isPreview = isPreview { parts.append("preview=\(isPreview)") }
        parts.append("home=\(WidgetSnapshot.realHome)")
        let line = parts.joined(separator: " ") + "\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 时间线

struct AirWearEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct AirWearProvider: TimelineProvider {

    func placeholder(in context: Context) -> AirWearEntry {
        WidgetTrace.record("placeholder")
        return AirWearEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AirWearEntry) -> Void) {
        let loaded = WidgetSnapshot.load()
        WidgetTrace.record("getSnapshot", loaded: loaded != nil, isPreview: context.isPreview)
        // 画廊里显示样例数据（好看且能说明用途），真挂到桌面上才用真实数据
        let snapshot: WidgetSnapshot = context.isPreview ? .placeholder : (loaded ?? .unavailable)
        completion(AirWearEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AirWearEntry>) -> Void) {
        // 数据由主 App 在变化时主动 reloadAllTimelines 推过来；
        // 这里只做兜底轮询，频率给得很保守（小组件的刷新预算很紧，别浪费）。
        let loaded = WidgetSnapshot.load()
        WidgetTrace.record("getTimeline", loaded: loaded != nil, isPreview: context.isPreview)
        let snapshot: WidgetSnapshot = context.isPreview ? .placeholder : (loaded ?? .unavailable)
        completion(Timeline(entries: [AirWearEntry(date: Date(), snapshot: snapshot)],
                            policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

// MARK: - 配色

private enum Palette {
    static let worn = Color(red: 0.24, green: 0.56, blue: 0.98)
    static let idle = Color(red: 0.98, green: 0.62, blue: 0.20)
    static let track = Color.secondary.opacity(0.18)

    static func stateColor(_ state: String) -> Color {
        switch state {
        case "active": return worn
        case "idle": return idle
        default: return .secondary
        }
    }
}

// MARK: - 小组件视图

struct AirWearWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily

    let entry: AirWearEntry
    /// 预览时强制指定尺寸（正常运行时为 nil，走环境值）
    var forcedFamily: WidgetFamily?
    /// 预览时自己画背景（widget 容器外没有 containerBackground）
    var drawsOwnBackground: Bool = false

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var family: WidgetFamily { forcedFamily ?? environmentFamily }

    var body: some View {
        content
            .modifier(WidgetBackground(enabled: !drawsOwnBackground))
    }

    @ViewBuilder
    private var content: some View {
        if !snapshot.hasData {
            unavailable
        } else {
            switch family {
            case .systemMedium: medium
            default: small
            }
        }
    }

    /// 扩展跑起来了，但读不到主 App 的快照（沙箱没放行 / App 从没运行过）
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "airpods")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("暂无数据")
                .font(.system(size: 15, weight: .semibold))
            Text("先启动一次 AirWear，它每 5s 会把统计写进快照")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 小尺寸：只要「今天多久 + 现在什么状态」

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Palette.stateColor(snapshot.state))
                    .frame(width: 7, height: 7)
                Text(snapshot.stateLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            Text(snapshot.wornText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text("今日佩戴")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            GoalBar(progress: snapshot.goalProgress, overGoal: snapshot.overGoal)

            Spacer(minLength: 0)

            MiniWeek(days: snapshot.week, showLabels: false)
        }
    }

    // MARK: 中尺寸：状态 + 数字 + 7 天柱 + 电量

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Palette.stateColor(snapshot.state))
                        .frame(width: 7, height: 7)
                    Text(snapshot.stateLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                Text(snapshot.deviceName ?? "AirPods")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(snapshot.wornText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text("出声 \(WidgetSnapshot.compact(snapshot.todayActiveMinutes)) · 连接 \(WidgetSnapshot.compact(snapshot.todayConnectedMinutes))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                GoalBar(progress: snapshot.goalProgress, overGoal: snapshot.overGoal)

                if snapshot.breakWarning {
                    HStack(spacing: 3) {
                        Image(systemName: "ear.badge.waveform")
                        Text("连续 \(snapshot.stretchText)，该歇了")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.idle)
                    .lineLimit(1)
                } else {
                    Text("本次连续 \(snapshot.stretchText)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                MiniWeek(days: snapshot.week, showLabels: true)
                HStack(spacing: 6) {
                    BatteryDot(label: "L", value: snapshot.left)
                    BatteryDot(label: "R", value: snapshot.right)
                    BatteryDot(label: "C", value: snapshot.caseLevel)
                }
                .font(.system(size: 9))
            }
        }
    }
}

/// 小组件必须声明 containerBackground（macOS 14+），预览时则自己铺背景
private struct WidgetBackground: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
        } else {
            content
        }
    }
}

// MARK: - 子组件

private struct GoalBar: View {
    let progress: Double
    let overGoal: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(overGoal ? Palette.idle : Palette.worn)
                    .frame(width: max(3, geo.size.width * min(1, progress)))
            }
        }
        .frame(height: 5)
    }
}

private struct MiniWeek: View {
    let days: [WidgetSnapshot.Day]
    let showLabels: Bool

    var body: some View {
        let peak = max(days.map(\.wornMinutes).max() ?? 0, 30)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Palette.track)
                        Capsule()
                            .fill(Palette.worn)
                            .frame(height: max(2, CGFloat(day.wornMinutes) / CGFloat(peak) * 30))
                    }
                    .frame(width: 7, height: 30)

                    if showLabels {
                        Text(day.label)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct BatteryDot: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "–")
                .monospacedDigit()
                .fontWeight(.medium)
        }
    }
}

// MARK: - 扩展入口（只在扩展目标里编译）

#if AIRWEAR_WIDGET_EXTENSION
struct AirWearWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AirWearWidget", provider: AirWearProvider()) { entry in
            AirWearWidgetView(entry: entry)
        }
        .configurationDisplayName("AirPods 佩戴时间")
        .description("今日佩戴时长、当前状态与最近 7 天趋势")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AirWearWidgetBundle: WidgetBundle {
    var body: some Widget {
        AirWearWidget()
    }
}
#endif
