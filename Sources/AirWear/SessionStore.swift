import Darwin
import Foundation

/// 一段佩戴/连接区间
struct WearInterval: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var deviceUID: String
    var deviceName: String
    var isAirPods: Bool
    /// "active"（正在出声）| "idle"（连着但没出声）
    var state: String
    var start: Date
    var end: Date?
    var wasDefaultOutput: Bool
    var batteryStart: AirPodsBattery?
    var batteryEnd: AirPodsBattery?
    /// 电量下降证据 ⇒ 这段 idle 确实戴在耳朵上
    var wornConfirmed: Bool = false

    var isActive: Bool { state == "active" }

    func duration(now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    func batteryDeltaDescription() -> String? {
        guard let s = batteryStart, let e = batteryEnd else { return nil }
        var parts: [String] = []
        if let a = s.left, let b = e.left { parts.append("左 \(a)%→\(b)%") }
        if let a = s.right, let b = e.right { parts.append("右 \(a)%→\(b)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

struct DailyStat: Identifiable {
    let day: Date
    var connected: TimeInterval = 0
    var active: TimeInterval = 0
    /// idle 但被电量证据确认戴着的时长
    var confirmedIdle: TimeInterval = 0
    var id: Date { day }

    /// 最佳估计佩戴时长：出声时长 + 有电量证据的静默佩戴时长
    var estimatedWorn: TimeInterval { active + confirmedIdle }
}

/// 会话存储。
///
/// 存储策略：**单文件 + 原子重写**（`sessions.json`），而不是无限追加的 JSONL。
/// 理由：区间数量是「状态变化次数」级别（每天几十到几百条），文件只有几百 KB，
/// 每 30s 原子重写一次的成本可忽略，却换来「永远不存在半截记录」的崩溃安全性。
/// 未闭合的区间把 `end` 留空 + 文件级 `heartbeat` 时间戳，进程被杀后按 heartbeat 收口。
///
/// 并发：监控队列写、电量队列补标记、主线程读，因此所有公开方法都过 `lock`。
final class SessionStore {

    static let shared = SessionStore()

    private struct StoreFile: Codable {
        var version: Int = 1
        var heartbeat: Date = Date()
        var intervals: [WearInterval] = []
    }

    private let lock = NSRecursiveLock()
    private var file = StoreFile()
    private var lockFD: Int32 = -1
    private var fileURL: URL

    /// 没有抢到跨进程锁时为 false：此时只读不写（避免 App 与 CLI 同时写坏数据）
    private(set) var isWritable = false
    /// 只读时的人类可读原因（区分「已有实例」和「目录不可写」，排查时很关键）
    private(set) var writableStatus = "可写"
    let dataDirectory: URL

    /// 同一状态、间隔 ≤ 这个秒数的两段区间视为「同一次佩戴」（吞掉连上/断开抖动）
    private let mergeGap: TimeInterval = 60

    init(directory: URL? = nil) {
        // 沙箱下必须用真实 home 拼绝对路径（FileManager 的 applicationSupportDirectory
        // 会返回容器内路径，导致小组件读不到主 App 写的数据）——见 AppPaths
        let dir = directory ?? AppPaths.dataDirectory
        dataDirectory = dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            writableStatus = "数据目录不可用：\(dir.path)（\(error.localizedDescription)）"
        }
        fileURL = dir.appendingPathComponent("sessions.json")
        if acquireLock() {
            isWritable = true
            writableStatus = "可写"
        }
        load()
        recoverOpenInterval()
    }

    var filePath: String { fileURL.path }

    // MARK: - 跨进程锁（flock：进程退出自动释放，无需 PID 陈旧判断）

    private func acquireLock() -> Bool {
        let path = dataDirectory.appendingPathComponent("store.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            if writableStatus == "可写" {
                writableStatus = "无法创建锁文件 \(path)（errno \(errno)）"
            }
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(fd)   // 本类有同名方法 close(at:battery:)，必须显式限定
            writableStatus = "已有 AirWear 实例在运行，本进程只读"
            return false
        }
        lockFD = fd
        return true
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(StoreFile.self, from: data) {
            file = decoded
        } else {
            Log.error("sessions.json 解析失败，已备份为 sessions.json.bak 并重新开始")
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        guard isWritable else { return }
        file.version = 1
        file.heartbeat = Date()
        normalize()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 进程被杀后收口：未闭合区间按 heartbeat 结束
    private func recoverOpenInterval() {
        lock.lock(); defer { lock.unlock() }
        // 只读实例（已有 App 在跑）绝不能去"收口"别人正在写的区间
        guard isWritable else { return }
        var changed = false
        for index in file.intervals.indices where file.intervals[index].end == nil {
            let openStart = file.intervals[index].start
            let closeAt = max(file.heartbeat, openStart)
            file.intervals[index].end = closeAt
            changed = true
            Log.info("发现未闭合区间（\(openStart) → \(closeAt)），已按心跳时间收口")
        }
        if changed { save() }
    }

    // MARK: - 合并 / 清洗

    /// 合并同设备同状态且间隔很小的相邻区间；丢弃 < 3s 的采样毛刺。
    private func normalize() {
        guard !file.intervals.isEmpty else { return }
        let closed = file.intervals.filter { $0.end != nil }.sorted { $0.start < $1.start }
        var merged: [WearInterval] = []

        for item in closed {
            guard var last = merged.last else { merged.append(item); continue }
            let gap = item.start.timeIntervalSince(last.end ?? last.start)
            let sameKind = last.deviceUID == item.deviceUID && last.state == item.state
            if sameKind && gap >= -1 && gap <= mergeGap {
                if let end = item.end, let lastEnd = last.end, end > lastEnd { last.end = end }
                last.batteryEnd = item.batteryEnd ?? last.batteryEnd
                last.wornConfirmed = last.wornConfirmed || item.wornConfirmed
                last.wasDefaultOutput = last.wasDefaultOutput || item.wasDefaultOutput
                merged[merged.count - 1] = last
                continue
            }
            merged.append(item)
        }

        let cleaned = merged.filter { $0.duration() >= 3 }
        let open = file.intervals.filter { $0.end == nil }
        file.intervals = cleaned + open
        // 只保留最近 400 天
        let cutoff = Date().addingTimeInterval(-400 * 86_400)
        file.intervals.removeAll { ($0.end ?? $0.start) < cutoff }
    }

    // MARK: - 记录

    /// 开一段新区间（会自动闭合上一段）。同一状态连续重复调用无副作用。
    @discardableResult
    func begin(deviceUID: String, deviceName: String, isAirPods: Bool, state: String,
               isDefaultOutput: Bool, battery: AirPodsBattery?, at date: Date = Date()) -> WearInterval? {
        lock.lock(); defer { lock.unlock() }
        guard isWritable else { return nil }
        if let open = file.intervals.last(where: { $0.end == nil }) {
            if open.deviceUID == deviceUID && open.state == state { return open }
            close(at: date, battery: battery)
        }
        let interval = WearInterval(deviceUID: deviceUID, deviceName: deviceName, isAirPods: isAirPods,
                                   state: state, start: date, end: nil, wasDefaultOutput: isDefaultOutput,
                                   batteryStart: battery, batteryEnd: nil)
        file.intervals.append(interval)
        Log.info("▶︎ 开始记录\(state == "active" ? "出声佩戴" : "连接静默")：\(deviceName) @ \(Fmt.time(date))")
        save()
        return interval
    }

    /// 闭合当前区间，并用最新电量判定「是否真有佩戴证据」。
    func close(at date: Date = Date(), battery: AirPodsBattery? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard isWritable, let index = file.intervals.lastIndex(where: { $0.end == nil }) else { return }
        file.intervals[index].end = max(date, file.intervals[index].start)
        if let battery = battery { file.intervals[index].batteryEnd = battery }
        if file.intervals[index].batteryEnd == nil { file.intervals[index].batteryEnd = file.intervals[index].batteryStart }
        let drained = file.intervals[index].batteryEnd?.drainEvidence(comparedTo: file.intervals[index].batteryStart) ?? false
        file.intervals[index].wornConfirmed = drained
        Log.info("⏹ 结束区间 \(Fmt.duration(file.intervals[index].duration()))\(drained ? "（电量下降，确认佩戴）" : "")")
        save()
    }

    /// 电量下降 ⇒ 给当前未闭合区间补上「确认佩戴」标记
    func markWornConfirmed(battery: AirPodsBattery?) {
        lock.lock(); defer { lock.unlock() }
        guard isWritable, let index = file.intervals.lastIndex(where: { $0.end == nil }) else { return }
        guard !file.intervals[index].wornConfirmed else { return }
        file.intervals[index].wornConfirmed = true
        if let battery = battery { file.intervals[index].batteryEnd = battery }
        Log.info("电量下降 ⇒ 给当前区间补「确认佩戴」标记")
        save()
    }

    /// 心跳：更新文件时间戳，供进程被杀后收口
    func heartbeat() {
        lock.lock(); defer { lock.unlock() }
        guard isWritable else { return }
        file.heartbeat = Date()
        guard file.intervals.contains(where: { $0.end == nil }) else { return }
        save()
    }

    func openInterval() -> WearInterval? {
        lock.lock(); defer { lock.unlock() }
        return file.intervals.last { $0.end == nil }
    }

    var allIntervals: [WearInterval] {
        lock.lock(); defer { lock.unlock() }
        return file.intervals.sorted { $0.start < $1.start }
    }

    // MARK: - 统计

    func intervals(on day: Date, now: Date = Date()) -> [WearInterval] {
        lock.lock(); defer { lock.unlock() }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return file.intervals
            .filter { $0.start < end && ($0.end ?? now) > start }
            .sorted { $0.start < $1.start }
    }

    private func overlap(_ interval: WearInterval, dayStart: Date, dayEnd: Date, now: Date) -> TimeInterval {
        let s = max(interval.start, dayStart)
        let e = min(interval.end ?? now, dayEnd)
        return max(0, e.timeIntervalSince(s))
    }

    func stat(for day: Date, now: Date = Date()) -> DailyStat {
        lock.lock(); defer { lock.unlock() }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var stat = DailyStat(day: dayStart)
        for interval in file.intervals {
            let span = overlap(interval, dayStart: dayStart, dayEnd: dayEnd, now: now)
            guard span > 0 else { continue }
            if interval.isActive {
                stat.active += span
                stat.connected += span
            } else {
                stat.connected += span
                if interval.wornConfirmed || AppSettings.shared.idleCountsAsWorn {
                    stat.confirmedIdle += span
                }
            }
        }
        return stat
    }

    /// 最近 n 天（含今天），从早到晚
    func recentStats(days: Int, now: Date = Date()) -> [DailyStat] {
        let calendar = Calendar.current
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            return stat(for: day, now: now)
        }
    }

    /// 从当前往回流式累加，得到「这一次连续佩戴」的起点与时长 —— 用于久戴提醒。
    /// 区间之间的空档 > mergeGap 视为「摘下过」，连续计时归零。
    func continuousStretch(now: Date = Date()) -> (start: Date, duration: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        let sorted = file.intervals.sorted { $0.start < $1.start }
        guard let last = sorted.last else { return nil }
        // 关键：已经摘下超过一个空档窗口，就不存在「本次连续」了。
        // 漏了这一步的话，摘下之后计时会一直涨下去，久戴提醒也会拿过期数据一直响。
        if let end = last.end, now.timeIntervalSince(end) > mergeGap { return nil }
        var start = last.start
        var previousStart = last.start
        for interval in sorted.dropLast().reversed() {
            let gap = previousStart.timeIntervalSince(interval.end ?? interval.start)
            if gap > mergeGap { break }
            start = interval.start
            previousStart = interval.start
        }
        return (start, max(0, now.timeIntervalSince(start)))
    }

    // MARK: - 导出

    func exportCSV(to path: String) throws {
        let intervals = allIntervals
        var lines = ["start,end,minutes,state,device,airpods,default_output,battery_start,battery_end,worn_confirmed"]
        let iso = ISO8601DateFormatter()
        for interval in intervals {
            let fields = [
                iso.string(from: interval.start),
                interval.end.map { iso.string(from: $0) } ?? "",
                String(format: "%.1f", interval.duration() / 60),
                interval.state,
                interval.deviceName.replacingOccurrences(of: ",", with: " "),
                interval.isAirPods ? "yes" : "no",
                interval.wasDefaultOutput ? "yes" : "no",
                interval.batteryStart?.describe.replacingOccurrences(of: ",", with: " ") ?? "",
                interval.batteryEnd?.describe.replacingOccurrences(of: ",", with: " ") ?? "",
                interval.wornConfirmed ? "yes" : "no",
            ]
            lines.append(fields.joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
