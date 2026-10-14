import SwiftUI
import Charts

private enum ReportPeriod: String, CaseIterable, Identifiable {
    case week = "周"
    case month = "月"
    case year = "年"

    var id: String { rawValue }
    var component: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

private struct TrendPoint: Identifiable {
    let date: Date
    let active: TimeInterval
    let confirmedIdle: TimeInterval
    var id: Date { date }
}

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = 0
    @State private var period: ReportPeriod = .week
    @State private var anchorDate = Date()
    @State private var periodDays: [DailyStat] = []
    @State private var periodIntervals: [WearInterval] = []

    private var calendar: Calendar { .current }
    private var periodRange: DateInterval {
        calendar.dateInterval(of: period.component, for: anchorDate)
            ?? DateInterval(start: calendar.startOfDay(for: anchorDate), duration: 86_400)
    }
    private var canMoveForward: Bool {
        guard let current = calendar.dateInterval(of: period.component, for: model.now) else { return false }
        return periodRange.start < current.start
    }

    private var periodTitle: String {
        let start = periodRange.start
        let lastDay = calendar.date(byAdding: .day, value: -1, to: periodRange.end) ?? start
        switch period {
        case .week:
            return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(lastDay.formatted(date: .abbreviated, time: .omitted))"
        case .month:
            return "\(calendar.component(.year, from: start)) 年 \(calendar.component(.month, from: start)) 月"
        case .year:
            return "\(calendar.component(.year, from: start)) 年"
        }
    }

    private var totalWorn: TimeInterval { periodDays.reduce(0) { $0 + $1.estimatedWorn } }
    private var totalActive: TimeInterval { periodDays.reduce(0) { $0 + $1.active } }
    private var dayCount: Int {
        max(1, periodDays.filter { $0.day <= calendar.startOfDay(for: model.now) }.count)
    }

    private var trendPoints: [TrendPoint] {
        if period != .year {
            return periodDays.map { TrendPoint(date: $0.day, active: $0.active, confirmedIdle: $0.confirmedIdle) }
        }
        let grouped = Dictionary(grouping: periodDays) { day in
            calendar.dateInterval(of: .month, for: day.day)?.start ?? day.day
        }
        return (0..<12).compactMap { month in
            guard let date = calendar.date(byAdding: .month, value: month, to: periodRange.start) else { return nil }
            let stats = grouped[date] ?? []
            return TrendPoint(date: date,
                              active: stats.reduce(0) { $0 + $1.active },
                              confirmedIdle: stats.reduce(0) { $0 + $1.confirmedIdle })
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            overview
                .tabItem { Label("概览", systemImage: "chart.bar") }
                .tag(0)
            history
                .tabItem { Label("历史", systemImage: "clock") }
                .tag(1)
            settings
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .background(PeriodSwipeHandler(enabled: selectedTab != 2) { offset in
            guard offset < 0 || canMoveForward else { return }
            movePeriod(offset)
        })
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear {
            model.syncMainWindowAppearance()
            refreshPeriod()
        }
        .onChange(of: period) { _ in refreshPeriod() }
        .onChange(of: anchorDate) { _ in refreshPeriod() }
        .onReceive(model.$todayStat) { _ in refreshPeriod() }
    }

    private func refreshPeriod() {
        let range = periodRange
        periodDays = model.store.dailyStats(from: range.start, to: range.end, now: model.now)
        periodIntervals = model.store.intervals(from: range.start, to: range.end, now: model.now)
    }

    private func movePeriod(_ offset: Int) {
        guard let date = calendar.date(byAdding: period.component, value: offset, to: anchorDate) else { return }
        anchorDate = date
    }

    private func displayedSpan(for interval: WearInterval) -> (start: Date, end: Date) {
        let range = periodRange
        return (max(interval.start, range.start), min(interval.end ?? model.now, range.end))
    }

    private var periodControl: some View {
        HStack(spacing: 10) {
            Picker("显示范围", selection: $period) {
                ForEach(ReportPeriod.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            Spacer()
            Button { movePeriod(-1) } label: { Image(systemName: "chevron.left") }
                .help("上一个时段")
            Text(periodTitle)
                .help("双指左右滑动可切换时段")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 160)
            Button { movePeriod(1) } label: { Image(systemName: "chevron.right") }
                .help("下一个时段")
                .disabled(!canMoveForward)
            Button("当前") { anchorDate = Date() }
                .help("回到当前时段")
                .disabled(!canMoveForward)
        }
        .buttonStyle(.borderless)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AirWear").font(.largeTitle.bold())
                    Label(model.snapshot.state.label, systemImage: model.snapshot.state.symbol)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { model.refreshNow(); model.refreshStats() }
            }
            periodControl
            HStack(spacing: 14) {
                metric("累计佩戴", value: Fmt.duration(totalWorn), symbol: "headphones")
                metric("出声时间", value: Fmt.duration(totalActive), symbol: "waveform")
                metric("日均佩戴", value: Fmt.duration(totalWorn / Double(dayCount)), symbol: "calendar")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("佩戴趋势").font(.headline)
                    Spacer()
                    Text(period == .year ? "每月" : "每日")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if periodIntervals.isEmpty {
                    Text("这个时段还没有佩戴记录")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                } else {
                    Chart(trendPoints) { point in
                        BarMark(x: .value("日期", point.date, unit: period == .year ? .month : .day),
                                y: .value("出声小时", point.active / 3600))
                            .foregroundStyle(Color.accentColor)
                        BarMark(x: .value("日期", point.date, unit: period == .year ? .month : .day),
                                y: .value("静默佩戴小时", point.confirmedIdle / 3600))
                            .foregroundStyle(Color.accentColor.opacity(0.32))
                    }
                    .chartYAxisLabel("小时")
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : period == .month ? 6 : 12))
                    }
                    .frame(height: 220)
                }
                Text("深色为出声，浅色为电量确认的静默佩戴")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("佩戴历史").font(.title2.bold())
                Spacer()
                Button("导出全部 CSV") { model.exportCSV() }
            }
            periodControl
            if periodIntervals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("这个时段还没有记录")
                        .font(.headline)
                    Text("选择其它时段，或戴上 AirPods 开始使用。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(periodIntervals) { interval in
                    let span = displayedSpan(for: interval)
                    HStack(spacing: 12) {
                        Image(systemName: interval.isActive ? "waveform" : "pause.circle")
                            .foregroundStyle(interval.isActive ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(interval.deviceName).font(.headline)
                            Text("\(span.start.formatted(date: .abbreviated, time: .shortened)) – \(interval.end == nil && periodRange.contains(model.now) ? "进行中" : span.end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.duration(max(0, span.end.timeIntervalSince(span.start)))).monospacedDigit()
                        if interval.wornConfirmed { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(12)
    }

    private var settings: some View {
        Form {
            Section("外观") {
                Picker("外观模式", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                }
                .pickerStyle(.segmented)
            }
            Section("佩戴统计") {
                SettingsControls(model: model)
            }
            Section("数据") {
                LabeledContent("存储方式", value: "SQLite")
                LabeledContent("数据库位置", value: model.store.filePath)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("在 Finder 中显示") { model.revealDataFile() }
                Button("导出全部记录为 CSV") { model.exportCSV() }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

struct SettingsControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle("只统计 AirPods（忽略其它蓝牙耳机）", isOn: Binding(get: { model.airPodsOnly }, set: { model.setAirPodsOnly($0) }))
        Toggle("把连接但没出声也算成佩戴", isOn: Binding(get: { model.idleCountsAsWorn }, set: { model.setIdleCountsAsWorn($0) }))
        Toggle("久戴时发系统通知", isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) }))
        Stepper("久戴提醒阈值：\(model.breakThresholdMinutes) 分钟", value: Binding(get: { model.breakThresholdMinutes }, set: { model.setBreakThreshold($0) }), in: 15...240, step: 15)
        Stepper("每日目标：\(model.dailyGoalMinutes / 60) 小时", value: Binding(get: { model.dailyGoalMinutes }, set: { model.setDailyGoal($0) }), in: 30...720, step: 30)
    }
}
