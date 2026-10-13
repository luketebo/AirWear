import SwiftUI
import Charts

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = 0

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
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { model.syncMainWindowAppearance() }
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
            HStack(spacing: 14) {
                metric("今日佩戴", value: Fmt.duration(model.todayStat.estimatedWorn), symbol: "headphones")
                metric("正在出声", value: Fmt.duration(model.todayStat.active), symbol: "waveform")
                metric("每日目标", value: "\(model.dailyGoalMinutes / 60) 小时", symbol: "target")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("最近 7 天").font(.headline)
                Chart(model.weekStats) { stat in
                    BarMark(x: .value("日期", Fmt.weekday(stat.day)), y: .value("出声", stat.active / 60))
                        .foregroundStyle(Color.accentColor)
                    BarMark(x: .value("日期", Fmt.weekday(stat.day)), y: .value("佩戴", stat.confirmedIdle / 60))
                        .foregroundStyle(Color.accentColor.opacity(0.32))
                }
                .frame(height: 220)
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
                Button("导出 CSV") { model.exportCSV() }
            }
            List(model.store.allIntervals.reversed()) { interval in
                HStack(spacing: 12) {
                    Image(systemName: interval.isActive ? "waveform" : "pause.circle")
                        .foregroundStyle(interval.isActive ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(interval.deviceName).font(.headline)
                        Text("\(interval.start.formatted(date: .abbreviated, time: .shortened)) – \(interval.end?.formatted(date: .omitted, time: .shortened) ?? "进行中")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.duration(interval.duration(now: model.now))).monospacedDigit()
                    if interval.wornConfirmed { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
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
