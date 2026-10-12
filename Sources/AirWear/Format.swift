import Foundation

/// 时长/时间的展示格式化
enum Fmt {

    /// 214 分钟 -> "3h34m"；小于 1 小时 -> "34m"；小于 1 分钟 -> "45s"
    /// 分钟级**四舍五入**（不是截断）：2m51s 显示 3m，避免和区间明细对不上账
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(0, total))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }

    /// 菜单栏用：尽量短
    static func menuBarDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(0, total))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }

    static func hours(_ seconds: TimeInterval) -> Double { seconds / 3600 }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEEE"   // 单字星期：一二三…
        return f.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}
