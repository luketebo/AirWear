# 桌面小组件（WidgetKit）—— 状态：**未验证**

> ⚠️ **请先读这一行**：小组件代码是完整可编译的，但**没有在真机上验证过它能出现在小组件画廊里**。
> 它不影响主 App 的任何功能——只是待在你的 `Contents/PlugIns/` 里。
> 如果你试出来了（成功或失败），欢迎开 issue 告诉我。

小/中两种尺寸，显示**今日佩戴时长、当前状态、最近 7 天趋势、左右耳电量**，超过久戴阈值时变橙色提示。

## 怎么加

1. 把 App 装到 `/Applications`（`make install`，画廊里更好找）
2. **右键桌面 → 编辑小组件 → 搜索 "AirWear"** → 选小号或中号
3. 加不上去就看 `make widget-status`，它会告诉你卡在哪一环

## 数据怎么流到小组件

```
主 App（唯一真相源）
  ├ 每 5s 把算好的统计写进 ~/Library/Application Support/AirWear/widget.json（几百字节，扁平结构）
  └ 内容真正变化且距上次 ≥60s 时，调 WidgetCenter.reloadAllTimelines()
        ↓
小组件扩展（chronod 拉起）
  └ 只读快照、只负责画；统计口径一行都不重复实现
```

两个刻意的取舍：

- **不让小组件直接读 `sessions.json`**。统计口径必须只有一处实现，否则两边数字会飘；扩展进程能少碰外部路径就少碰。
- **没用 App Group**。`com.apple.security.application-groups` 需要带该权限的 provisioning profile。
  改用「读主 App 写在固定路径的快照」这一更朴素的做法。

## 怎么自查它到底有没有被系统加载

小组件跑在 `chronod` 里，宿主 App 拿不到它的输出。所以做了两层自查：

| 手段 | 命令 | 能回答什么 |
|---|---|---|
| WidgetKit 官方 API | `make widget-status` | 系统认不认这个扩展（失败 = appex 有问题；成功且 0 个 = 有效但还没挂到桌面） |
| 扩展自留痕迹 | `cat ~/Library/Application\ Support/AirWear/widget-ran.log` | 扩展进程**真的被执行过没有**、有没有读到数据（每次打开画廊/刷新时间线都追加一行） |

`WidgetTrace`（在 `Sources/AirWearWidget/AirWearWidget.swift` 里）就是为此存在的：
扩展每次被加载都会往那个文件追加一行。**没有这行日志，就无法区分"扩展没被加载"和"加载了但读不到数据"。**

## 画廊里看不到？→ `make widget-doctor`

**结论先行**：小组件不出现在画廊，几乎总是**注册 / 签名 / 守护进程缓存**问题，而不是 UI 代码问题。
（这个判断与 [CodexBar 的 widgets 可见性文档](https://github.com/steipete/CodexBar/blob/main/docs/widgets.md) 一致，它维护着同为「菜单栏 App + WidgetKit 扩展」的结构。）

最关键的一条：**PlugInKit 有「选用（election）」机制**。
`pluginkit -m` 输出里 `+` = 已选用（可见），`-` = 被忽略（画廊里根本看不见）。
把 `.appex` 拷进 `Contents/PlugIns/` 只是"存在"，**并不等于被选用**。

```bash
make install          # 先用当前构建替换 /Applications 里的副本（旧副本会造成同 ID 重复）
make widget-doctor    # 结构 / 签名 / 重复副本 / 注册 / 选用 / 重启 pkd·chronod 一键跑完
```

`scripts/widget-doctor.sh` 会依次做六件事：包结构校验 → 签名校验 → 同 bundle id 重复副本检查 →
`pluginkit -a` 注册 + `pluginkit -e use` 选用 + `lsregister -f` → 重启 `pkd`/`chronod`/`Dock`/`NotificationCenter` 丢缓存 → 复查选用状态。
其中 `chronod` 需要管理员权限，会提示输入密码。

---

## 弯路记录：真因是「沙箱权限把进程启动就杀了」

这段值得留着，因为它是一个很典型的误判案例。

调试过程中我先后得出过**两个错误结论**，最后靠崩溃报告才定位到真因：

**错误结论一：「宿主 App 必须沙箱」。**
依据是本机能用的第三方 widget 扩展（Teams / TickTick / Tide）宿主全都是沙箱的。
这是**相关性冒充因果**——那 4 个都是 App Store 应用，本来就沙箱。
实测证明宿主不沙箱时，`chronod` 照样会去启动我们的扩展。

**错误结论二：「沙箱让电量证据失效」。**
给主 App 加沙箱后 `system_profiler` 确实读不到数据了，我据此判定"沙箱破坏了电量探测"。
**实际上进程根本没活到跑代码那一步。**

**真因**（`~/Library/Logs/DiagnosticReports/AirWear-*.ips` 里的崩溃栈）：

```
EXC_BREAKPOINT / SIGTRAP  (exit=133, Trace/BPT trap: 5)
  libsystem_secinit.dylib  _libsecinit_appsandbox.cold.9   ← App Sandbox 初始化
  libsystem_secinit.dylib  _libsecinit_appsandbox
  libsystem_secinit.dylib  _libsecinit_initializer
  dyld                     dyld4::prepare
```

`com.apple.security.temporary-exception.*`（以及 `application-groups`）是**需要 provisioning profile
授权的受限权限**。缺少描述文件时沙箱应用失败，进程在 dyld 初始化阶段就被 abort。
**而 `chronod` 那边的表现极具迷惑性**：

```
chronod: Launching process with config: bundleID: com.airwear.mac.widget   ← 启动了
chronod: Error acquiring assertion: "Specified target process 61515 does not exist"  ← 当场死了
```

看起来像"没注册"，实际是"注册好了但一启动就死"。

**最终配置**：App 和扩展**都不沙箱、都不带 entitlements**
（`Resources/Widget.entitlements` 保持空字典，里面有完整记录）。
扩展直接读 `~/Library/Application Support/AirWear/widget.json`，
路径由 `AppPaths` 用真实 home 拼出来，不依赖沙箱容器。
代价：想上架 App Store 需要换成 App Group + 真正的描述文件。

**自查手法**：直接跑扩展二进制就能复现/验证这个问题——

```bash
AirWear.app/Contents/PlugIns/AirWearWidget.appex/Contents/MacOS/AirWearWidget
```

崩在沙箱就是 `Trace/BPT trap: 5`；正常则报
`Failed to create running extension of type: 'viewBridgeUI'`（缺宿主，属预期）。

## 无 GUI 下预览小组件长相

```bash
make render-widget F=./widget-preview            # 生成 -small.png / -medium.png
```

原理：`Sources/AirWearWidget/AirWearWidget.swift` 被编译两次——扩展目标带 `-D AIRWEAR_WIDGET_EXTENSION`
（`@main` 是 `WidgetBundle`），主 App 不带该宏（只借用视图代码 + `ImageRenderer` 离屏渲染）。
这样在**没有屏幕录制权限、截不了桌面**的环境下也能确认小组件的长相。
