import AppKit
import CoreAudio
import Foundation

enum WearState: String, Codable {
    /// 设备不在（未连接 / 不在候选范围内）
    case absent
    /// 连着但没出声：可能在盒里、也可能戴着没播
    case idle
    /// 正在出声：几乎可以断定戴在耳朵上（L2 信号）
    case active

    var label: String {
        switch self {
        case .absent: return "未连接"
        case .idle: return "已连接 · 未出声"
        case .active: return "佩戴中 · 正在出声"
        }
    }

    var symbol: String {
        switch self {
        case .absent: return "airpods"
        case .idle: return "airpods"
        case .active: return "airpods.gen3"
        }
    }
}

struct WearSnapshot {
    var state: WearState = .absent
    var device: AudioDevice?
    var isDefaultOutput: Bool = false
    var battery: AirPodsBattery?
    var at: Date = Date()

    var deviceName: String { device?.name ?? "—" }
}

/// 佩戴状态机。
///
/// 信号分层（这是整个项目最核心的设计）：
///   L1 连接：CoreAudio 里出现该蓝牙输出设备（零权限，但是「佩戴时长」的上限）
///   L2 出声：`kAudioDevicePropertyDeviceIsRunningSomewhere` == 1（零权限，几乎等价于戴在耳朵上）
///   L3 佐证：左右耳电量下降（轮询 system_profiler，用来给 idle 段补「确实戴着」的证据）
///
/// 去抖策略：`absent → 有设备` 立即生效（漏记比多记糟），`idle ↔ active` 需要持续 15s 才改判；
/// 断开只需 4s 确认，且存储层的 mergeGap 会把「连上→断开→重连」的抖动合成一段。
final class WearMonitor {

    var onSnapshot: ((WearSnapshot) -> Void)?
    /// 状态被正式改判（写库时机）
    var onStateCommitted: ((WearState, WearSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.airwear.monitor")
    private let batteryQueue = DispatchQueue(label: "com.airwear.battery")

    private var pollTimer: DispatchSourceTimer?
    private var batteryTimer: DispatchSourceTimer?
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var sleepTokens: [NSObjectProtocol] = []

    private var committed: WearState = .absent
    private var pendingState: WearState?
    private var pendingSince = Date()
    private var snapshot = WearSnapshot()
    private var lastBattery: AirPodsBattery?
    private var batteryBusy = false
    private var started = false

    private let pollInterval: TimeInterval = 5
    private let batteryInterval: TimeInterval = 60
    private let flapDelay: TimeInterval = 15
    private let disconnectDelay: TimeInterval = 4

    // MARK: - 生命周期

    func start(store: SessionStore) {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true

            var devicesAddr = CoreAudioClient.address(kAudioHardwarePropertyDevices)
            let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.poll(store: store, reason: "设备列表变化")
            }
            self.devicesBlock = devicesBlock
            AudioObjectAddPropertyListenerBlock(CoreAudioClient.systemObject, &devicesAddr, self.queue, devicesBlock)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: self.pollInterval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.poll(store: store, reason: "轮询") }
            timer.resume()
            self.pollTimer = timer

            let btimer = DispatchSource.makeTimerSource(queue: self.batteryQueue)
            btimer.schedule(deadline: .now() + 2, repeating: self.batteryInterval, leeway: .seconds(5))
            btimer.setEventHandler { [weak self] in self?.refreshBattery(store: store) }
            btimer.resume()
            self.batteryTimer = btimer

            self.observeSleep(store: store)
            Log.info("佩戴监控已启动（轮询 \(Int(self.pollInterval))s / 电量 \(Int(self.batteryInterval))s）")
        }
    }

    func stop(store: SessionStore) {
        queue.sync {
            guard started else { return }
            started = false
            pollTimer?.cancel(); pollTimer = nil
            batteryTimer?.cancel(); batteryTimer = nil
            if let b = devicesBlock {
                var addr = CoreAudioClient.address(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(CoreAudioClient.systemObject, &addr, queue, b)
                devicesBlock = nil
            }
            for token in sleepTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            sleepTokens.removeAll()
            store.close(at: Date(), battery: lastBattery)
            Log.info("佩戴监控已停止")
        }
    }

    /// 立刻取一次快照（UI 首帧用）
    func refresh(store: SessionStore) {
        queue.async { [weak self] in self?.poll(store: store, reason: "手动刷新") }
    }

    private func observeSleep(store: SessionStore) {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                // 睡眠期间不该继续累计：直接收口并把状态归零
                Log.info("系统即将睡眠，收口当前区间")
                store.close(at: Date(), battery: self.lastBattery)
                self.committed = .absent
                self.pendingState = nil
                self.snapshot.state = .absent
                self.publish()
            }
        }
        let wake = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                Log.info("系统已唤醒，重新判定佩戴状态")
                self.poll(store: store, reason: "唤醒")
            }
        }
        sleepTokens = [sleep, wake]
    }

    // MARK: - 判定

    /// 挑出当前要跟踪的设备：优先名字带 AirPods 的蓝牙输出设备
    private func pickDevice(from devices: [AudioDevice]) -> AudioDevice? {
        var candidates = devices.filter { $0.isBluetoothOutput }
        if let pinned = AppSettings.shared.pinnedDeviceUID {
            if let exact = candidates.first(where: { $0.uid == pinned }) { return exact }
        }
        if AppSettings.shared.airPodsOnly {
            candidates = candidates.filter { $0.isAirPods }
        }
        return CoreAudioClient.bluetoothOutputCandidates(from: candidates).first
    }

    private func poll(store: SessionStore, reason: String) {
        let devices = CoreAudioClient.lightSnapshot()
        let device = pickDevice(from: devices)
        let defaultUID = CoreAudioClient.defaultOutputUID()

        let raw: WearState
        if let device = device {
            raw = device.runningSomewhere ? .active : .idle
        } else {
            raw = .absent
        }

        snapshot.device = device
        snapshot.state = raw
        snapshot.isDefaultOutput = (device != nil && device?.uid == defaultUID)
        snapshot.battery = lastBattery
        snapshot.at = Date()

        // 去抖：新状态要持续一段时间才认账
        if raw == committed {
            pendingState = nil
        } else if pendingState != raw {
            pendingState = raw
            pendingSince = Date()
            Log.info("状态候选 → \(raw.label)（\(reason)，等待 \(commitDelay(for: raw))s 确认）")
        } else if Date().timeIntervalSince(pendingSince) >= commitDelay(for: raw) {
            commit(raw, store: store)
        }

        // 首次连上立刻补一次电量基线
        if raw != .absent && lastBattery == nil {
            batteryQueue.async { [weak self] in self?.refreshBattery(store: store) }
        }
        publish()
    }

    private func commitDelay(for state: WearState) -> TimeInterval {
        state == .absent ? disconnectDelay : flapDelay
    }

    private func commit(_ state: WearState, store: SessionStore) {
        let previous = committed
        committed = state
        pendingState = nil
        snapshot.state = state
        Log.info("状态改判：\(previous.label) → \(state.label)")

        switch state {
        case .absent:
            store.close(at: Date(), battery: lastBattery)
        case .idle, .active:
            if let device = snapshot.device {
                store.begin(deviceUID: device.uid,
                            deviceName: device.name,
                            isAirPods: device.isAirPods,
                            state: state.rawValue,
                            isDefaultOutput: snapshot.isDefaultOutput,
                            battery: lastBattery)
            }
        }
        onStateCommitted?(state, snapshot)
    }

    // MARK: - 电量（L3 佐证）

    private func refreshBattery(store: SessionStore) {
        guard !batteryBusy else { return }
        batteryBusy = true
        defer { batteryBusy = false }

        let readings = BatteryProbe.read()
        guard let best = readings.first(where: { $0.connected }) ?? readings.first else {
            queue.async { [weak self] in
                guard let self = self else { return }
                self.lastBattery = nil
                self.snapshot.battery = nil
                self.publish()
            }
            return
        }

        let previous = lastBattery
        queue.async { [weak self] in
            guard let self = self else { return }
            let drained = best.drainEvidence(comparedTo: previous)
            if drained {
                Log.info("电量下降（\(best.describe)）⇒ 确认在佩戴")
            }
            self.lastBattery = best
            self.snapshot.battery = best
            // 已确认佩戴 ⇒ 把当前 idle 区间补上证据标记
            if drained, let open = store.openInterval(), open.end == nil, store.isWritable {
                store.markWornConfirmed(battery: best)
            }
            self.publish()
        }
    }

    private func publish() {
        let snap = snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snap) }
    }
}
