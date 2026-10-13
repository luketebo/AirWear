import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// User preferences persisted in UserDefaults.
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let prefix = "airwear."

    private func register() {
        defaults.register(defaults: [
            prefix + "airPodsOnly": true,
            prefix + "breakThresholdMinutes": 90,
            prefix + "dailyGoalMinutes": 180,
            prefix + "notificationsEnabled": true,
            prefix + "idleCountsAsWorn": false,
            prefix + "appearance": AppAppearance.system.rawValue,
        ])
    }

    private init() { register() }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: prefix + "appearance") ?? "system") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: prefix + "appearance") }
    }

    /// 只统计名字里带 AirPods 的设备（关掉则统计任意蓝牙耳机）
    var airPodsOnly: Bool {
        get { defaults.bool(forKey: prefix + "airPodsOnly") }
        set { defaults.set(newValue, forKey: prefix + "airPodsOnly") }
    }

    /// 连续佩戴提醒阈值（分钟）
    var breakThresholdMinutes: Int {
        get { max(15, defaults.integer(forKey: prefix + "breakThresholdMinutes")) }
        set { defaults.set(newValue, forKey: prefix + "breakThresholdMinutes") }
    }

    /// 每日佩戴软目标（分钟），仅用于进度条，不做医学建议
    var dailyGoalMinutes: Int {
        get { max(30, defaults.integer(forKey: prefix + "dailyGoalMinutes")) }
        set { defaults.set(newValue, forKey: prefix + "dailyGoalMinutes") }
    }

    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: prefix + "notificationsEnabled") }
        set { defaults.set(newValue, forKey: prefix + "notificationsEnabled") }
    }

    /// 是否把"连接但没出声"的 idle 时段也算进佩戴（默认否，等电量证据来确认）
    var idleCountsAsWorn: Bool {
        get { defaults.bool(forKey: prefix + "idleCountsAsWorn") }
        set { defaults.set(newValue, forKey: prefix + "idleCountsAsWorn") }
    }

    /// 被跟踪设备的 UID（手动锁定某副耳机；空表示自动挑选）
    var pinnedDeviceUID: String? {
        get { defaults.string(forKey: prefix + "pinnedDeviceUID") }
        set { defaults.set(newValue, forKey: prefix + "pinnedDeviceUID") }
    }
}
