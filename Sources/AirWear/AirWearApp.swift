import AppKit
import SwiftUI

/// 程序入口：先处理 CLI 参数，否则启动菜单栏 App。
@main
enum AirWearMain {
    static func main() {
        if CLI.runIfRequested() {
            exit(0)
        }
        AirWearApp.main()
    }
}

struct AirWearApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // 菜单栏直接显示今日佩戴时长：这是这个 App 唯一需要「一眼看到」的信息
            Label(model.menuBarTitle, systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
