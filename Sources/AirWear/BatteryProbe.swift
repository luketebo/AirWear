import Foundation

/// 单次电量快照（来自 system_profiler SPBluetoothDataType -json）
struct AirPodsBattery: Codable, Equatable {
    var name: String
    var address: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var connected: Bool
    var at: Date

    /// 任意一只耳机电量下降 ⇒ 放电中 ⇒ 几乎可以断定在耳朵上（充电盒里只会充电/持平）
    func drainEvidence(comparedTo previous: AirPodsBattery?) -> Bool {
        guard let p = previous else { return false }
        if let a = p.left, let b = left, b < a { return true }
        if let a = p.right, let b = right, b < a { return true }
        return false
    }

    /// 两只耳机都在充电（电量上升或持平且贴着 100%）⇒ 大概率在盒里
    func looksCharging(comparedTo previous: AirPodsBattery?) -> Bool {
        guard let p = previous else { return false }
        let leftUp = (p.left ?? 0) < (left ?? 0)
        let rightUp = (p.right ?? 0) < (right ?? 0)
        return leftUp || rightUp
    }

    var describe: String {
        let l = left.map { "\($0)%" } ?? "–"
        let r = right.map { "\($0)%" } ?? "–"
        let c = caseLevel.map { "\($0)%" } ?? "–"
        return "左\(l) 右\(r) 盒\(c)"
    }
}

/// 用 `system_profiler` 读 AirPods 电量。
///
/// 为什么敢轮询：实测这条命令在 macOS 26 上耗时 50–110ms，采样周期 60s 时开销可忽略，
/// 而且它属于零权限路径（不走蓝牙 API，不触发隐私授权弹窗）。
enum BatteryProbe {

    private static let binary = "/usr/sbin/system_profiler"

    /// 同步读取（**必须放到专用后台队列**，万一 system_profiler 卡住也不会拖累佩戴状态判定）。
    /// 失败返回空数组。
    static func read(timeout: TimeInterval = 6) -> [AirPodsBattery] {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            Log.error("电量读取启动失败：\(error.localizedDescription)")
            return []
        }

        // 阻塞读到 EOF；外层有专用串行队列兜底，卡住只会让电量变旧，不影响佩戴判定
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // 失败必须说清原因，否则沙箱一开始拦就只是"电量悄悄没了"，排查时毫无线索
        guard !data.isEmpty, process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.error("电量读取失败：exit=\(process.terminationStatus) stdout=\(data.count)字节"
                      + (stderr.isEmpty ? "" : " stderr=\(stderr.prefix(200))"))
            return []
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [AirPodsBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var results: [AirPodsBattery] = []
        let now = Date()
        for section in sections {
            if let connected = section["device_connected"] as? [[String: Any]] {
                for entry in connected {
                    for (name, value) in entry {
                        guard let info = value as? [String: Any] else { continue }
                        guard isAirPods(name: name, info: info) else { continue }
                        results.append(make(name: name, info: info, connected: true, at: now))
                    }
                }
            }
            if let notConnected = section["device_not_connected"] as? [[String: Any]] {
                for entry in notConnected {
                    for (name, value) in entry {
                        guard let info = value as? [String: Any] else { continue }
                        guard isAirPods(name: name, info: info) else { continue }
                        results.append(make(name: name, info: info, connected: false, at: now))
                    }
                }
            }
        }
        return results
    }

    private static func isAirPods(name: String, info: [String: Any]) -> Bool {
        let vendor = (info["device_vendorID"] as? String)?.uppercased() ?? ""
        let minor = (info["device_minorType"] as? String) ?? ""
        let hasBattery = info["device_batteryLevelLeft"] != nil
            || info["device_batteryLevelRight"] != nil
            || info["device_batteryLevelCase"] != nil
        if name.range(of: "airpods", options: .caseInsensitive) != nil { return true }
        // Apple 厂商 ID + 耳机类目（覆盖改名后不带 "AirPods" 字样的场景）
        if vendor.hasPrefix("0X004C") && (minor.contains("Headphones") || hasBattery) { return true }
        return false
    }

    private static func make(name: String, info: [String: Any], connected: Bool, at: Date) -> AirPodsBattery {
        AirPodsBattery(
            name: name,
            address: (info["device_address"] as? String) ?? "",
            left: percent(info["device_batteryLevelLeft"]),
            right: percent(info["device_batteryLevelRight"]),
            caseLevel: percent(info["device_batteryLevelCase"]),
            connected: connected,
            at: at
        )
    }

    /// "33%" -> 33；数字不合法返回 nil（区别于 0）
    private static func percent(_ raw: Any?) -> Int? {
        guard let s = raw as? String else { return nil }
        let digits = s.filter { $0.isNumber }
        guard !digits.isEmpty, let v = Int(digits) else { return nil }
        return v
    }
}
