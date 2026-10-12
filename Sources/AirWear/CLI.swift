import AppKit
import CoreAudio
import Foundation
import SwiftUI
import WidgetKit

/// 命令行模式：不依赖 GUI 就能验证判定逻辑与数据落盘（M1/M2 验证用）。
enum CLI {

    /// 返回 true 表示本次进程是 CLI 调用，已处理完毕、可以退出。
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        setvbuf(stdout, nil, _IONBF, 0)
        switch args[1] {
        case "--dump", "-d":
            dump()
        case "--once":
            once()
        case "--watch", "-w":
            let seconds = args.count > 2 ? (Double(args[2]) ?? 30) : 30
            watch(seconds: seconds)
        case "--today", "-t":
            today()
        case "--week":
            week()
        case "--export":
            export(Array(args.dropFirst(2)))
        case "--render":
            // CLI 全程跑在主线程，ImageRenderer 是 @MainActor，这里直接复用当前主线程隔离
            MainActor.assumeIsolated { render(Array(args.dropFirst(2))) }
        case "--render-widget":
            MainActor.assumeIsolated { renderWidget(Array(args.dropFirst(2))) }
        case "--widget-status":
            widgetStatus()
        case "--publish-widget":
            MainActor.assumeIsolated { publishWidget() }
        case "--help", "-h":
            help()
        default:
            print("未知参数：\(args[1])\n")
            help()
        }
        return true
    }

    private static func help() {
        print("""
        AirWear — AirPods 佩戴时间记录（菜单栏 App）

        用法：
          AirWear                    启动菜单栏 App（默认）
          AirWear --dump             打印音频设备 / AirPods 电量 / 当前判定
          AirWear --once             打印一次当前佩戴判定（单次采样）
          AirWear --watch [秒]       前台监听并在状态变化时打印（默认 30s，会写库）
          AirWear --today            打印今日统计与区间明细
          AirWear --week             打印最近 7 天统计
          AirWear --export <路径>    导出 CSV
          AirWear --render <png> [--demo]  把弹窗界面渲染成 PNG（--demo 用样例数据）
          AirWear --render-widget <前缀> [--demo] [--long]
                                        把小组件（小/中两种尺寸）渲染成 <前缀>-small.png / -medium.png
          AirWear --widget-status     查看小组件快照文件与系统注册情况
          AirWear --publish-widget    立刻重算并写出小组件快照（不启动 App）
          AirWear --help             显示本帮助

        数据文件：\(SessionStore.shared.filePath)
        小组件快照：\(WidgetSnapshot.fileURL.path)
        日志文件：\(Log.logPath)
        """)
    }

    // MARK: - 采集与展示

    private static func describe(_ device: AudioDevice?) -> String {
        guard let d = device else { return "无" }
        return "\(d.name)（\(d.transport.label)\(d.isAirPods ? " · AirPods" : "")，出声=\(d.runningSomewhere ? "是" : "否")）"
    }

    private static func currentDevice() -> AudioDevice? {
        var candidates = CoreAudioClient.bluetoothOutputCandidates()
        if AppSettings.shared.airPodsOnly {
            candidates = candidates.filter { $0.isAirPods }
        }
        return candidates.first
    }

    private static func dump() {
        let devices = CoreAudioClient.lightSnapshot()
        let defaultUID = CoreAudioClient.defaultOutputUID()
        print("=== 音频设备（共 \(devices.count) 个） ===")
        for d in devices.sorted(by: { $0.name < $1.name }) {
            var flags: [String] = []
            flags.append("存活=\(d.isAlive ? "是" : "否")")
            flags.append("出声=\(d.runningSomewhere ? "是" : "否")")
            flags.append("可作默认输出=\(d.canBeDefaultOutput.map { $0 ? "是" : "否" } ?? "未知")")
            if d.isBluetoothOutput { flags.append("★蓝牙输出") }
            if d.uid == defaultUID { flags.append("◆当前默认输出") }
            print("  id=\(d.id)\t\(d.name) | \(d.transport.label) | \(flags.joined(separator: " "))")
            print("      uid=\(d.uid)")
        }

        print("\n=== 佩戴判定 ===")
        let device = currentDevice()
        print("跟踪设备：\(describe(device))")
        print("默认输出：\(defaultUID ?? "未知")")
        if let d = device {
            print("状态：\(d.runningSomewhere ? "佩戴中 · 正在出声（L2）" : "已连接 · 未出声（L1）")")
        } else {
            print("状态：未连接")
        }

        print("\n=== AirPods 电量（L3 佐证） ===")
        let batteries = BatteryProbe.read()
        if batteries.isEmpty {
            print("  未读到 AirPods 电量")
        } else {
            for b in batteries {
                print("  \(b.name)  \(b.describe)  已连接=\(b.connected ? "是" : "否")")
            }
        }

        print("\n=== 存储 ===")
        let store = SessionStore.shared
        print("  数据文件：\(store.filePath)")
        print("  写入状态：\(store.writableStatus)")
        print("  已记录区间：\(store.allIntervals.count) 段")
    }

    private static func once() {
        let device = currentDevice()
        print("跟踪设备：\(describe(device))")
        if let d = device {
            print("状态：\(d.runningSomewhere ? "active（正在出声）" : "idle（连着未出声）")")
        } else {
            print("状态：absent（未连接）")
        }
        if let b = BatteryProbe.read().first(where: { $0.connected }) {
            print("电量：\(b.describe)")
        }
    }

    private static func watch(seconds: Double) {
        let store = SessionStore.shared
        print("前台监听 \(Int(seconds))s…  数据文件：\(store.filePath)（\(store.writableStatus)）")
        let monitor = WearMonitor()
        monitor.onSnapshot = { snap in
            let device = snap.device.map { "\($0.name)" } ?? "—"
            print("[\(Fmt.time(snap.at))] \(snap.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(device)  电量=\(snap.battery?.describe ?? "–")")
        }
        monitor.onStateCommitted = { state, snap in
            print("  ⚑ 改判 → \(state.label)")
        }
        monitor.start(store: store)

        // 让它至少跑完一个轮询周期再退出，保证落盘一次
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        monitor.stop(store: store)
        print("\n=== 本次写入后的今日统计 ===")
        printToday(store: store)
    }

    private static func today() {
        printToday(store: SessionStore.shared)
    }

    private static func printToday(store: SessionStore) {
        let now = Date()
        let stat = store.stat(for: now, now: now)
        print("今日佩戴（估算）：\(Fmt.duration(stat.estimatedWorn))")
        print("  ├ 出声时长：\(Fmt.duration(stat.active))")
        print("  ├ 静默但已确认佩戴：\(Fmt.duration(stat.confirmedIdle))")
        print("  └ 连接时长（上限）：\(Fmt.duration(stat.connected))")
        print("目标：\(Fmt.duration(TimeInterval(AppSettings.shared.dailyGoalMinutes * 60)))")

        let intervals = store.intervals(on: now, now: now)
        if intervals.isEmpty {
            print("\n今日无区间记录。")
            return
        }
        print("\n今日区间（\(intervals.count) 段）：")
        for interval in intervals {
            let range = "\(Fmt.time(interval.start))–\(interval.end.map { Fmt.time($0) } ?? "进行中")"
            let kind = interval.isActive ? "出声" : "静默"
            let confirm = interval.wornConfirmed ? " ✅电量佐证" : ""
            let delta = interval.batteryDeltaDescription().map { "  \($0)" } ?? ""
            print("  \(range)  \(kind)  \(Fmt.duration(interval.duration(now: now)))\(confirm)\(delta)")
        }
        if let stretch = store.continuousStretch(now: now), stretch.duration >= 60 {
            print("\n当前连续佩戴：\(Fmt.duration(stretch.duration))（\(Fmt.time(stretch.start)) 起）")
        }
    }

    private static func week() {
        let store = SessionStore.shared
        let stats = store.recentStats(days: 7)
        print("=== 最近 7 天 ===")
        print("日期      出声      静默确认   估算佩戴   连接(上限)")
        for stat in stats {
            let day = "\(Fmt.monthDay(stat.day)) \(Fmt.weekday(stat.day))"
            print(String(format: "%-9@ %-9@ %-10@ %-10@ %@",
                         day as NSString,
                         Fmt.duration(stat.active) as NSString,
                         Fmt.duration(stat.confirmedIdle) as NSString,
                         Fmt.duration(stat.estimatedWorn) as NSString,
                         Fmt.duration(stat.connected) as NSString))
        }
        let totalActive = stats.reduce(0) { $0 + $1.active }
        let totalWorn = stats.reduce(0) { $0 + $1.estimatedWorn }
        print(String(format: "\n合计：出声 %@，估算佩戴 %@，日均 %@",
                     Fmt.duration(totalActive) as NSString,
                     Fmt.duration(totalWorn) as NSString,
                     Fmt.duration(totalWorn / 7) as NSString))
    }

    private static func export(_ args: [String]) {
        let path = args.first ?? "./airwear-export.csv"
        let store = SessionStore.shared
        do {
            try store.exportCSV(to: path)
            print("✅ 已导出 \(store.allIntervals.count) 段区间 → \(path)")
        } catch {
            print("❌ 导出失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 界面预览渲染

    /// 用 ImageRenderer 把弹窗界面离屏渲染成 PNG，方便在无 GUI / 无法截屏时验证视觉。
    @MainActor
    private static func render(_ args: [String]) {
        let path = args.first(where: { !$0.hasPrefix("--") }) ?? "./preview.png"
        let demo = args.contains("--demo")
        let long = args.contains("--long")

        _ = NSApplication.shared
        let model = demo ? AppModel.demo(stretchMinutes: long ? 100 : 34)
                         : AppModel(store: .shared, startMonitoring: false)
        if !demo {
            model.refreshStats()
            // 非 demo 时补一次真实采样，否则预览里的状态/电量是空的
            if let device = currentDevice() {
                model.snapshot.device = device
                model.snapshot.state = device.runningSomewhere ? .active : .idle
                model.snapshot.isDefaultOutput = device.uid == CoreAudioClient.defaultOutputUID()
            } else {
                model.snapshot.state = .absent
            }
            model.snapshot.battery = BatteryProbe.read().first(where: { $0.connected })
            model.snapshot.at = Date()
        }

        let view = PopoverView(model: model, isPreview: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("❌ 渲染失败")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("✅ 界面预览已渲染 → \(path)（\(Int(image.size.width))×\(Int(image.size.height)) pt）")
        } catch {
            print("❌ 写文件失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 小组件预览渲染

    /// 把小组件的两种尺寸离屏渲染成 PNG。
    /// 小组件运行在系统进程里、桌面截图又需要屏幕录制权限，所以这是唯一能自查长相的办法。
    @MainActor
    private static func renderWidget(_ args: [String]) {
        let prefix = args.first(where: { !$0.hasPrefix("--") }) ?? "./preview-widget"
        let demo = args.contains("--demo")
        let long = args.contains("--long")

        _ = NSApplication.shared

        var snapshot: WidgetSnapshot
        if demo {
            snapshot = .placeholder
            if long {
                snapshot.breakWarning = true
                snapshot.stretchMinutes = 108
                snapshot.todayWornMinutes = 212
                snapshot.goalMinutes = 180
            }
        } else {
            snapshot = WidgetSnapshot.load() ?? .placeholder
        }

        let entry = AirWearEntry(date: Date(), snapshot: snapshot)
        let sizes: [(WidgetFamily, String, CGSize)] = [
            (.systemSmall, "small", CGSize(width: 170, height: 170)),
            (.systemMedium, "medium", CGSize(width: 364, height: 170)),
        ]

        for (family, name, size) in sizes {
            let view = AirWearWidgetView(entry: entry, forcedFamily: family, drawsOwnBackground: true)
                .frame(width: size.width, height: size.height)
                .padding(14)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("❌ 渲染失败（\(name)）")
                continue
            }
            let path = "\(prefix)-\(name).png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("✅ 小组件 \(name) → \(path)（\(Int(size.width))×\(Int(size.height)) pt）")
            } catch {
                print("❌ 写文件失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 小组件数据 / 注册诊断

    private static func widgetStatus() {
        let url = WidgetSnapshot.fileURL
        print("快照文件：\(url.path)")
        guard let snapshot = WidgetSnapshot.load() else {
            print("  还没有快照（App 启动后每 5s 写一次；也可用 --publish-widget 立刻生成）")
            return
        }
        let age = Int(Date().timeIntervalSince(snapshot.generatedAt))
        print("  生成时间：\(snapshot.generatedAt)（\(age)s 前）")
        print("  状态：\(snapshot.stateLabel)  设备：\(snapshot.deviceName ?? "—")")
        print("  今日佩戴：\(snapshot.wornText)  出声 \(snapshot.todayActiveMinutes)m  连接 \(snapshot.todayConnectedMinutes)m")
        print("  本次连续：\(snapshot.stretchText)  久戴提醒：\(snapshot.breakWarning ? "是" : "否")  目标：\(snapshot.goalMinutes)m")
        let percent = { (value: Int?) in value.map { "\($0)%" } ?? "–" }
        print("  电量：左 \(percent(snapshot.left))  右 \(percent(snapshot.right))  盒 \(percent(snapshot.caseLevel))")
        print("  7 天：\(snapshot.week.map { "\($0.label)\($0.wornMinutes)m" }.joined(separator: " "))")

        // 只有宿主 App 能问 WidgetKit：系统这边到底认不认这个扩展？
        // 成功但 0 个 = 扩展有效、只是还没被挂到桌面上；失败 = 扩展没被加载，问题在 appex。
        print("\n=== WidgetKit 视角 ===")
        let semaphore = DispatchSemaphore(value: 0)
        WidgetCenter.shared.getCurrentConfigurations { result in
            switch result {
            case .success(let configurations):
                print("  已挂到桌面的 AirWear 小组件：\(configurations.count) 个")
                for configuration in configurations {
                    print("    · \(configuration.kind) family=\(configuration.family)")
                }
                if configurations.isEmpty {
                    print("    （0 个是正常的：说明扩展有效，只是你还没把它添加到桌面）")
                }
            case .failure(let error):
                print("  ❌ 查询失败：\(error.localizedDescription)")
                print("     这通常意味着扩展没能被系统加载（appex 结构 / 签名 / Info.plist 问题）")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// 不启动 App，直接把当前统计写一份快照出来（并请求系统刷新小组件）
    @MainActor
    private static func publishWidget() {
        let store = SessionStore.shared
        let now = Date()
        let stat = store.stat(for: now, now: now)

        var payload = WidgetSnapshot()
        payload.generatedAt = now
        if let device = currentDevice() {
            payload.state = device.runningSomewhere ? "active" : "idle"
            payload.deviceName = device.name
        }
        if let battery = BatteryProbe.read().first(where: { $0.connected }) {
            payload.left = battery.left
            payload.right = battery.right
            payload.caseLevel = battery.caseLevel
        }
        payload.todayWornMinutes = Int((stat.estimatedWorn / 60).rounded())
        payload.todayActiveMinutes = Int((stat.active / 60).rounded())
        payload.todayConnectedMinutes = Int((stat.connected / 60).rounded())
        if let stretch = store.continuousStretch(now: now) {
            payload.stretchMinutes = Int((stretch.duration / 60).rounded())
        }
        payload.goalMinutes = AppSettings.shared.dailyGoalMinutes
        payload.breakWarning = payload.stretchMinutes >= AppSettings.shared.breakThresholdMinutes
        payload.week = store.recentStats(days: 7, now: now).map { dayStat in
            WidgetSnapshot.Day(label: Fmt.weekday(dayStat.day),
                               wornMinutes: Int((dayStat.estimatedWorn / 60).rounded()),
                               activeMinutes: Int((dayStat.active / 60).rounded()))
        }

        do {
            try payload.write()
            WidgetCenter.shared.reloadAllTimelines()
            print("✅ 已写出小组件快照 → \(WidgetSnapshot.fileURL.path)")
            print("   状态 \(payload.stateLabel) · 今日 \(payload.wornText) · 连续 \(payload.stretchText)")
        } catch {
            print("❌ 写快照失败：\(error.localizedDescription)")
        }
    }
}
