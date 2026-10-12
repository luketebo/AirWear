import AppKit
import Charts
import SwiftUI
import WidgetKit

/// UI 状态容器。
/// 约定：所有 @Published 都在主线程写；监控回调里已经显式切主线程。
final class AppModel: ObservableObject {

    @Published var snapshot = WearSnapshot()
    @Published var now = Date()
    @Published var todayStat = DailyStat(day: Date())
    @Published var weekStats: [DailyStat] = []
    @Published var todayIntervals: [WearInterval] = []
    @Published var stretchStart: Date?
    @Published var breakWarning = false

    @Published var airPodsOnly: Bool
    @Published var idleCountsAsWorn: Bool
    @Published var notificationsEnabled: Bool
    @Published var breakThresholdMinutes: Int
    @Published var dailyGoalMinutes: Int

    let store: SessionStore
    private let monitor = WearMonitor()
    private var ticker: Timer?
    private var heartbeatTicker: Timer?
    private var tickCount = 0
    private var lastLoggedTitle = ""
    private var lastWidgetPublish = Date.distantPast
    private var lastWidgetFingerprint = ""
    private var lastWidgetReload = Date.distantPast
    /// 已经提醒过的那一次连续佩戴的起点，避免反复弹通知
    private var notifiedStretchStart: Date?

    init(store: SessionStore = .shared, startMonitoring: Bool = true) {
        self.store = store
        let settings = AppSettings.shared
        airPodsOnly = settings.airPodsOnly
        idleCountsAsWorn = settings.idleCountsAsWorn
        notificationsEnabled = settings.notificationsEnabled
        breakThresholdMinutes = settings.breakThresholdMinutes
        dailyGoalMinutes = settings.dailyGoalMinutes

        guard startMonitoring else { return }

        monitor.onSnapshot = { [weak self] snap in
            guard let self = self else { return }
            self.snapshot = snap
            self.refreshStats()
        }
        monitor.onStateCommitted = { [weak self] _, _ in
            self?.refreshStats()
        }
        monitor.start(store: store)

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 每 30s 心跳一次，进程被杀后能按心跳时间收口
        heartbeatTicker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.store.heartbeat()
        }
        refreshStats()
    }

    deinit {
        ticker?.invalidate()
        heartbeatTicker?.invalidate()
    }

    /// 渲染预览/测试用：不启动监控，直接注入样例数据
    static func demo(stretchMinutes: Double = 34) -> AppModel {
        let model = AppModel(store: .shared, startMonitoring: false)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let samples: [(Double, Double, Double)] = [
            (86, 32, 50), (140, 61, 66), (52, 18, 30), (168, 74, 80),
            (95, 40, 48), (120, 55, 50), (stretchMinutes + 22, stretchMinutes, 0),
        ]
        model.weekStats = samples.enumerated().compactMap { index, item in
            guard let day = calendar.date(byAdding: .day, value: index - 6, to: today) else { return nil }
            var stat = DailyStat(day: day)
            stat.active = item.1 * 60
            stat.confirmedIdle = item.2 * 60
            stat.connected = item.0 * 60
            return stat
        }
        model.todayStat = model.weekStats.last ?? DailyStat(day: today)
        // 预览用的样例数据。设备名与地址一律用占位值，
        // 避免把本机真实耳机名/蓝牙地址渲染进 docs/images 里的截图。
        model.snapshot = WearSnapshot(
            state: .active,
            device: AudioDevice(id: 115, uid: "AA-BB-CC-DD-EE-FF:output", name: "AirPods",
                                transport: .bluetooth, isAlive: true, canBeDefaultOutput: true,
                                runningSomewhere: true),
            isDefaultOutput: true,
            battery: AirPodsBattery(name: "AirPods", address: "AA:BB:CC:DD:EE:FF", left: 33,
                                    right: 27, caseLevel: 74, connected: true, at: Date()),
            at: Date())
        model.stretchStart = Date().addingTimeInterval(-stretchMinutes * 60)
        // 真实运行时由每秒 tick 计算，这里手动对齐一次，方便预览久戴横幅
        model.breakWarning = stretchMinutes >= Double(model.breakThresholdMinutes)
        model.todayIntervals = [
            WearInterval(deviceUID: "demo", deviceName: "AirPods", isAirPods: true, state: "active",
                         start: Date().addingTimeInterval(-stretchMinutes * 60), end: nil, wasDefaultOutput: true,
                         batteryStart: AirPodsBattery(name: "AirPods", address: "AA:BB:CC:DD:EE:FF", left: 35, right: 29,
                                                      caseLevel: 74, connected: true, at: Date()),
                         batteryEnd: nil),
            WearInterval(deviceUID: "demo", deviceName: "AirPods", isAirPods: true, state: "active",
                         start: Date().addingTimeInterval(-3 * 3600), end: Date().addingTimeInterval(-2.4 * 3600),
                         wasDefaultOutput: true, batteryStart: nil, batteryEnd: nil, wornConfirmed: true),
            WearInterval(deviceUID: "demo", deviceName: "AirPods", isAirPods: true, state: "idle",
                         start: Date().addingTimeInterval(-5 * 3600), end: Date().addingTimeInterval(-4.5 * 3600),
                         wasDefaultOutput: false, batteryStart: nil, batteryEnd: nil, wornConfirmed: false),
        ]
        return model
    }

    // MARK: - 派生展示值

    var menuBarTitle: String {
        let worn = todayStat.estimatedWorn
        if snapshot.state == .absent && worn < 60 { return "AirWear" }
        return Fmt.menuBarDuration(worn)
    }

    var menuBarSymbol: String {
        if let image = NSImage(systemSymbolName: snapshot.state.symbol, accessibilityDescription: nil), image.isValid {
            return snapshot.state.symbol
        }
        return "headphones"
    }

    var stretchDuration: TimeInterval {
        guard let start = stretchStart else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    var currentInterval: WearInterval? {
        todayIntervals.last { $0.end == nil } ?? store.openInterval()
    }

    var todaySessions: [WearInterval] {
        todayIntervals.filter { $0.duration(now: now) >= 60 }.reversed().map { $0 }
    }

    // MARK: - 刷新

    private func tick() {
        now = Date()
        tickCount += 1
        if tickCount % 5 == 0 { refreshStats() }
        // 菜单栏标题无法用截图验证（需要屏幕录制权限），把每次变化写进日志留痕
        if menuBarTitle != lastLoggedTitle {
            lastLoggedTitle = menuBarTitle
            Log.info("菜单栏标题 → \(menuBarTitle)（状态 \(snapshot.state.rawValue)）")
        }
        evaluateBreakReminder()
    }

    func refreshStats() {
        let reference = Date()
        todayStat = store.stat(for: reference, now: reference)
        weekStats = store.recentStats(days: 7, now: reference)
        todayIntervals = store.intervals(on: reference, now: reference)
        if let stretch = store.continuousStretch(now: reference), stretch.duration >= 60 {
            stretchStart = stretch.start
        } else {
            stretchStart = nil
        }
        publishWidgetSnapshot()
    }

    // MARK: - 小组件数据桥

    /// 把算好的结果写成扁平快照给小组件读（小组件是沙箱进程，不去碰 sessions.json）。
    /// 文件每 5s 重写一次（几百字节，可忽略）；但 `reloadAllTimelines` 有预算，
    /// 只在内容真的变了、且距上次刷新 ≥60s 时才通知系统。
    private func publishWidgetSnapshot() {
        let reference = Date()
        guard reference.timeIntervalSince(lastWidgetPublish) >= 5 else { return }
        lastWidgetPublish = reference

        let payload = makeWidgetSnapshot(at: reference)
        do {
            try payload.write()
        } catch {
            Log.error("写小组件快照失败：\(error.localizedDescription)")
        }

        let fingerprint = "\(payload.state)|\(payload.todayWornMinutes)|\(payload.breakWarning)|\(payload.goalMinutes)"
        if fingerprint != lastWidgetFingerprint, reference.timeIntervalSince(lastWidgetReload) >= 60 {
            lastWidgetFingerprint = fingerprint
            lastWidgetReload = reference
            WidgetCenter.shared.reloadAllTimelines()
            Log.info("已请求刷新小组件时间线（\(fingerprint)）")
        }
    }

    private func makeWidgetSnapshot(at date: Date) -> WidgetSnapshot {
        var payload = WidgetSnapshot()
        payload.generatedAt = date
        payload.state = snapshot.state.rawValue
        payload.deviceName = snapshot.device?.name
        payload.todayWornMinutes = Int((todayStat.estimatedWorn / 60).rounded())
        payload.todayActiveMinutes = Int((todayStat.active / 60).rounded())
        payload.todayConnectedMinutes = Int((todayStat.connected / 60).rounded())
        payload.stretchMinutes = Int((stretchDuration / 60).rounded())
        payload.breakWarning = breakWarning
        payload.goalMinutes = dailyGoalMinutes
        payload.left = snapshot.battery?.left
        payload.right = snapshot.battery?.right
        payload.caseLevel = snapshot.battery?.caseLevel
        payload.week = weekStats.map { stat in
            WidgetSnapshot.Day(label: Fmt.weekday(stat.day),
                               wornMinutes: Int((stat.estimatedWorn / 60).rounded()),
                               activeMinutes: Int((stat.active / 60).rounded()))
        }
        return payload
    }

    private func evaluateBreakReminder() {
        guard breakThresholdMinutes > 0 else { breakWarning = false; return }
        let threshold = TimeInterval(breakThresholdMinutes * 60)
        guard let start = stretchStart, stretchDuration >= threshold else {
            breakWarning = false
            return
        }
        breakWarning = true
        guard notifiedStretchStart != start else { return }
        notifiedStretchStart = start
        guard notificationsEnabled else { return }
        notifyBreak(minutes: Int(stretchDuration / 60))
    }

    private func notifyBreak(minutes: Int) {
        let message = "已连续佩戴 \(minutes) 分钟，摘下休息 5 分钟对耳朵更好"
        Log.info("久戴提醒：\(message)")
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "display notification \"\(message)\" with title \"AirWear\" sound name \"Ping\""]
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// 用户点「稍后再说」：本次连续佩戴不再重复提醒
    func snoozeBreakReminder() {
        notifiedStretchStart = stretchStart
        breakWarning = false
        Log.info("用户选择稍后提醒")
    }

    // MARK: - 设置写入

    func setAirPodsOnly(_ value: Bool) {
        airPodsOnly = value
        AppSettings.shared.airPodsOnly = value
        monitor.refresh(store: store)
    }

    func setIdleCountsAsWorn(_ value: Bool) {
        idleCountsAsWorn = value
        AppSettings.shared.idleCountsAsWorn = value
        refreshStats()
    }

    func setNotifications(_ value: Bool) {
        notificationsEnabled = value
        AppSettings.shared.notificationsEnabled = value
    }

    func setBreakThreshold(_ value: Int) {
        breakThresholdMinutes = max(15, value)
        AppSettings.shared.breakThresholdMinutes = breakThresholdMinutes
    }

    func setDailyGoal(_ value: Int) {
        dailyGoalMinutes = max(30, value)
        AppSettings.shared.dailyGoalMinutes = dailyGoalMinutes
    }

    func refreshNow() { monitor.refresh(store: store) }

    // MARK: - 动作

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "airwear-\(Fmt.monthDay(Date()).replacingOccurrences(of: "/", with: "-")).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV(to: url.path)
            Log.info("已导出 CSV：\(url.path)")
        } catch {
            Log.error("导出失败：\(error.localizedDescription)")
        }
    }

    func revealDataFile() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.filePath)])
    }
}

// MARK: - 弹窗

struct PopoverView: View {
    @ObservedObject var model: AppModel
    /// 预览渲染（ImageRenderer）时把 Button 换成静态文本：离屏栅格化拿不到真实按钮样式
    var isPreview: Bool = false
    @State private var showSettings = false

    private var state: WearState { model.snapshot.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            headline
            if let start = model.stretchStart, model.stretchDuration >= 60 {
                stretchRow(start: start)
            }
            if model.breakWarning { breakBanner }
            chart
            batteryRow
            sessions
            Divider()
            settings
            footer
        }
        .padding(14)
        .frame(width: 344)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: state))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.snapshot.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isPreview {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    model.refreshNow()
                    model.refreshStats()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("立即重新判定")
            }
        }
    }

    private func color(for state: WearState) -> Color {
        switch state {
        case .absent: return .secondary
        case .idle: return .orange
        case .active: return .green
        }
    }

    // MARK: 今日核心数字

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.duration(model.todayStat.estimatedWorn))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("今日佩戴")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("目标 \(Fmt.duration(TimeInterval(model.dailyGoalMinutes * 60)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let ratio = min(1.0, model.todayStat.estimatedWorn / TimeInterval(max(1, model.dailyGoalMinutes * 60)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(ratio >= 1 ? Color.orange : Color.accentColor)
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
            Text("出声 \(Fmt.duration(model.todayStat.active)) · 连接 \(Fmt.duration(model.todayStat.connected))（上限）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func stretchRow(start: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("本次连续 \(Fmt.duration(model.stretchDuration))")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Text("（\(Fmt.time(start)) 起）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var breakBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ear.badge.waveform")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("已连续佩戴 \(Int((model.stretchDuration / 60).rounded())) 分钟")
                    .font(.system(size: 12, weight: .semibold))
                Text("建议摘下休息 5 分钟")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if isPreview {
                    Text("知道了")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button("知道了") { model.snoozeBreakReminder() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 7 天图

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近 7 天")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(model.weekStats) { stat in
                    BarMark(
                        x: .value("日", Fmt.weekday(stat.day)),
                        y: .value("分钟", stat.active / 60)
                    )
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(3)

                    BarMark(
                        x: .value("日", Fmt.weekday(stat.day)),
                        y: .value("分钟", max(0, stat.estimatedWorn - stat.active) / 60)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.28))
                    .cornerRadius(3)
                }
                RuleMark(y: .value("目标", Double(model.dailyGoalMinutes)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            let hours = minutes / 60
                            Text(hours == hours.rounded()
                                 ? "\(Int(hours))h"
                                 : String(format: "%.1fh", hours))
                        }
                    }
                    .font(.system(size: 9))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .frame(height: 104)
            Text("深色=出声时长  浅色=有电量证据的静默佩戴")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 电量

    private var batteryRow: some View {
        HStack(spacing: 10) {
            if let battery = model.snapshot.battery {
                batteryChip("左", battery.left)
                batteryChip("右", battery.right)
                batteryChip("盒", battery.caseLevel)
                if let interval = model.currentInterval, let delta = interval.batteryDeltaDescription() {
                    Text(delta)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("电量读取中…（每 60s 更新一次）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func batteryChip(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "–")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }

    // MARK: 今日明细

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("今日区间")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if model.todaySessions.isEmpty {
                Text("还没有记录，戴上耳机开始播放就会自动记上")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.todaySessions.prefix(4)) { interval in
                    HStack(spacing: 6) {
                        Image(systemName: interval.isActive ? "waveform" : "pause.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(interval.isActive ? Color.accentColor : Color.secondary)
                        Text("\(Fmt.time(interval.start)) – \(interval.end.map { Fmt.time($0) } ?? "进行中")")
                            .font(.system(size: 11))
                            .monospacedDigit()
                        Text(Fmt.duration(interval.duration(now: model.now)))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                        if interval.wornConfirmed {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                                .help("电量下降，确认戴在耳朵上")
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: 设置

    private var settings: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("只统计 AirPods（忽略其它蓝牙耳机）", isOn: Binding(
                    get: { model.airPodsOnly },
                    set: { model.setAirPodsOnly($0) }
                ))
                Toggle("把「连接但没出声」也算成佩戴", isOn: Binding(
                    get: { model.idleCountsAsWorn },
                    set: { model.setIdleCountsAsWorn($0) }
                ))
                Toggle("久戴时发系统通知", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotifications($0) }
                ))
                HStack {
                    Text("久戴提醒阈值")
                    Spacer()
                    Stepper("\(model.breakThresholdMinutes) 分钟",
                            value: Binding(get: { model.breakThresholdMinutes },
                                           set: { model.setBreakThreshold($0) }),
                            in: 15...240, step: 15)
                }
                HStack {
                    Text("每日目标")
                    Spacer()
                    Stepper("\(model.dailyGoalMinutes / 60) 小时",
                            value: Binding(get: { model.dailyGoalMinutes },
                                           set: { model.setDailyGoal($0) }),
                            in: 30...720, step: 30)
                }
            }
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.top, 6)
        } label: {
            Text("设置")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            footerItem("导出 CSV") { model.exportCSV() }
            footerItem("数据文件") { model.revealDataFile() }
            Spacer()
            footerItem("退出") { NSApplication.shared.terminate(nil) }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func footerItem(_ title: String, action: @escaping () -> Void) -> some View {
        if isPreview {
            Text(title).foregroundStyle(Color.accentColor)
        } else {
            Button(title, action: action).buttonStyle(.link)
        }
    }
}
