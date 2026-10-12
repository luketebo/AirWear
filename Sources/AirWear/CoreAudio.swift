import CoreAudio
import Foundation

/// 把 UInt32 四字符码转成可读字符串，如 'blue' -> "blue"
func fourCC(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    let printable = bytes.map { b -> UInt8 in (b >= 0x20 && b < 0x7F) ? b : 0x3F /* '?' */ }
    return String(bytes: printable, encoding: .ascii) ?? "????"
}

/// 设备传输类型（CoreAudio 四字符码 → 语义化）
enum DeviceTransport: Equatable {
    case builtIn
    case aggregate
    case virtual
    case usb
    case bluetooth
    case bluetoothLE
    case airPlay
    case hdmi
    case displayPort
    case thunderbolt
    case avb
    case pci
    case fireWire
    case continuityWired
    case continuityWireless
    case unknown(UInt32)

    init(raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        default:
            // 这几个常量在旧 SDK 里没有，用四字符码比对，避免可用性标注
            switch fourCC(raw) {
            case "ccwd": self = .continuityWired
            case "ccwl": self = .continuityWireless
            default: self = .unknown(raw)
            }
        }
    }

    /// 注意：实测 macOS 26 上 AirPods 的传输码是 `blue`（kAudioDeviceTransportTypeBluetooth）
    var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }

    var label: String {
        switch self {
        case .builtIn: return "内置"
        case .aggregate: return "聚合"
        case .virtual: return "虚拟"
        case .usb: return "USB"
        case .bluetooth: return "蓝牙"
        case .bluetoothLE: return "蓝牙LE"
        case .airPlay: return "AirPlay"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .thunderbolt: return "雷电"
        case .avb: return "AVB"
        case .pci: return "PCI"
        case .fireWire: return "FireWire"
        case .continuityWired: return "连续互通(有线)"
        case .continuityWireless: return "连续互通(无线)"
        case .unknown(let v): return "未知(\(fourCC(v)))"
        }
    }
}

/// 音频设备快照项（值类型，线程安全）
struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: DeviceTransport
    let isAlive: Bool
    /// 能否作为默认输出设备。用 `kAudioDevicePropertyDeviceCanBeDefaultDevice`（输出 scope）判定，
    /// **读取它不会实例化 IO stream**，因此可以安全地在热路径查询。
    let canBeDefaultOutput: Bool?
    /// 该设备此刻是否正被某个进程使用（A2DP 流出声中 ⇒ 几乎可以断定戴在耳朵上）。
    /// 读取无副作用，可安全高频查询。
    let runningSomewhere: Bool

    var isAirPods: Bool {
        name.range(of: "airpods", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// 可计入佩戴统计的蓝牙输出设备。
    /// 排除 `…:input` 那个同名对象（AirPods 在 CoreAudio 里是输入/输出两个 object）。
    var isBluetoothOutput: Bool {
        guard transport.isBluetooth, isAlive else { return false }
        if uid.hasSuffix(":input") { return false }
        return canBeDefaultOutput ?? true
    }
}

/// CoreAudio 属性式 API 的薄封装。全部为公共、非废弃 API，无需蓝牙 / 麦克风 / 辅助功能权限。
///
/// ⚠️ 沿用 AutoBT 的约定：**绝不读 `kAudioDevicePropertyStreamConfiguration` / `Streams`**，
/// 那会实例化设备 IO stream，对蓝牙设备会打断 A2DP 协商。热路径只用无副作用属性。
enum CoreAudioClient {

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func deviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let err = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, UnsafeMutableRawPointer(base))
        }
        guard err == noErr else { return [] }
        return ids
    }

    static func stringProperty(_ objectID: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: CFString? = nil
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let v = value else { return nil }
        return v as String
    }

    static func uint32Property(_ objectID: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        guard err == noErr else { return 0 }
        return value
    }

    /// 三态布尔：`nil` 表示该属性**读取失败/未被驱动实现**，与"明确为 0"必须区分开。
    static func optionalBoolProperty(_ objectID: AudioObjectID,
                                     _ selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        guard err == noErr else { return nil }
        return value != 0
    }

    static func isAlive(_ objectID: AudioObjectID) -> Bool {
        optionalBoolProperty(objectID, kAudioDevicePropertyDeviceIsAlive) ?? true
    }

    /// 「设备此刻在跑」——L2 信号的核心。输出 scope 优先，读不到再退回 global scope。
    static func isRunningSomewhere(_ objectID: AudioObjectID) -> Bool {
        if let out = optionalBoolProperty(objectID, kAudioDevicePropertyDeviceIsRunningSomewhere,
                                          scope: kAudioObjectPropertyScopeOutput) {
            return out
        }
        return optionalBoolProperty(objectID, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? false
    }

    /// 轻量快照（热路径用）：只读无副作用属性。
    static func lightSnapshot() -> [AudioDevice] {
        deviceIDs().compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            let transport = DeviceTransport(raw: uint32Property(id, kAudioDevicePropertyTransportType))
            return AudioDevice(id: id, uid: uid, name: name, transport: transport,
                               isAlive: isAlive(id),
                               canBeDefaultOutput: optionalBoolProperty(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                                        scope: kAudioObjectPropertyScopeOutput),
                               runningSomewhere: isRunningSomewhere(id))
        }
    }

    static func defaultOutputUID() -> String? {
        let id = uint32Property(systemObject, kAudioHardwarePropertyDefaultOutputDevice)
        guard id != 0 else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// 取出「候选佩戴设备」：蓝牙输出设备，按 AirPods 优先 + 正在出声优先排序。
    static func bluetoothOutputCandidates(from devices: [AudioDevice]? = nil) -> [AudioDevice] {
        let list = devices ?? lightSnapshot()
        return list.filter { $0.isBluetoothOutput }
            .sorted { a, b in
                if a.isAirPods != b.isAirPods { return a.isAirPods }
                if a.runningSomewhere != b.runningSomewhere { return a.runningSomewhere }
                return a.name < b.name
            }
    }
}
