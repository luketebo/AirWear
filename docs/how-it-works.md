# 它是怎么判断「佩戴」的

「AirPods 佩戴时间」听起来是一个数，其实是三个不同的问题。AirWear 把三层信号都记下来，并且**永远把口径标出来**。

## 三层口径

| 口径 | 判据 | 含义 | 偏差方向 |
|---|---|---|---|
| **连接时长**（L1） | CoreAudio 里出现该蓝牙输出设备 | 耳机与 Mac 保持连接 | **上限**：盒子开盖、连接着但没播都算 |
| **出声时长**（L2） | `kAudioDevicePropertyDeviceIsRunningSomewhere == 1` | 确实有音频在流 | 几乎等价于「戴在耳朵上」 |
| **确认佩戴**（L3） | 左右耳电量在下降 | 放电中 ⇒ 不可能在充电盒里 | 粒度粗（1%，约十几分钟才动一格），但**能抓到「戴着但没播」** |

菜单栏和弹窗里的主数字 = **出声时长 + 被电量证据确认的静默时长**，也就是最接近「真的戴在耳朵上」的估计值。
弹窗里同时给出「连接（上限）」，让你一眼看出这个数字里有多少水分。

### 为什么不直接读入耳检测

AirPods 的逐耳入耳状态走私有 AACP 协议（[LibrePods](https://github.com/beidaoc/librepods) 已经在 Linux/Android 上把它逆向出来了）。
macOS 上要复刻得走 `IOBluetooth` 裸 L2CAP + 申请蓝牙权限，属于「能做但脆」的路线。

本项目的取舍是：**先用零权限的公共 API 把 90% 的价值拿到手**，AACP 留作后续增强，而不是前置依赖。

## 状态机与存储

```
每 5s 轮询 CoreAudio（只读无副作用属性，绝不碰 StreamConfiguration —— 那会打断蓝牙 A2DP 协商）
   ├ 找到候选：蓝牙输出设备，AirPods 优先，其次正在出声的
   ├ raw 状态 = 有设备 ? (runningSomewhere ? active : idle) : absent
   ├ 去抖：absent→有设备 需确认 4s；idle↔active 需持续 15s（吞掉播放/暂停抖动）
   └ 改判 → 写库（开一段新区间，自动闭合上一段）

每 60s 读电量（专用队列，卡住也只影响电量新鲜度，不拖累状态判定）
   └ 任一只耳机电量下降 ⇒ 给当前未闭合区间打上「确认佩戴」

存储层
   ├ 同设备同状态、间隔 ≤ 60s 的两段自动合并（连上→断开→重连 只算一次）
   ├ 丢弃 < 3s 的采样毛刺
   └ 系统睡眠（NSWorkspace.willSleep）立即收口，睡眠时段不计入
```

### 两个刻意的工程决定

**1. 存储用 SQLite（WAL + 事务），而不是自己维护一个 JSON 文件。**
区间数量是「状态变化次数」级别（每天几十到几百条），整个库只有几百 KB，于是每次落盘都是
**全量重写**：`BEGIN IMMEDIATE` → 清空 `intervals` 表 → 逐条插入 → 更新 `heartbeat` → `COMMIT`。
任何一步失败就 `ROLLBACK`，所以**永远不存在半截记录**，也不会写出坏文件。
`PRAGMA journal_mode=WAL` 让读写不互相阻塞；`synchronous=FULL` 是宁可慢一点也别丢数据。
未闭合区间把 `end` 留空，`heartbeat` 存进 `metadata` 表，进程被杀后按心跳时间收口。

> 早期版本用的是「JSON 单文件 + 原子重写」，目的相同。首次启动会把旧的 `sessions.json`
> 一次性导入；如果解析失败则保留原文件不动，方便人工恢复。

**2. `flock` 跨进程锁。**
App 在跑时，命令行工具自动降级为只读模式，避免两个进程同时写坏数据。

## 实测验证记录（不是推测）

| 探测项 | 实测结果 |
|---|---|
| AirPods 传输码 | CoreAudio 报 `blue`（不是常见的 `blut`）；同名输入对象 uid 带 `:input`，必须排除，否则会重复计数 |
| 电量读取成本 | `system_profiler SPBluetoothDataType -json` 耗时 **50–110ms**（采样周期 60s，开销可忽略） |
| L2 信号有效性 | 播放时 `runningSomewhere=1`；未出声时同一设备为 `0`，**能真实区分**「连着」和「在播」 |
| L3 电量证据 | 一次实测中左耳 33%→25%、右耳 27%→18%；期间有一段「连着但没出声」被电量下降**提升为「确认佩戴」** |
| 崩溃安全 | 写入在单个事务内完成（任一步失败即 `ROLLBACK`）；未闭合区间把 `end` 留空、`heartbeat` 存进 `metadata` 表，进程被杀后按心跳时间收口 |
| 多进程 | `flock` 跨进程锁：App 在跑时，CLI 自动降级为只读，不会两写一坏 |

## 已知限制（都写在这里，不藏着）

1. 任何基于 `runningSomewhere` 的判断都无法区分「戴在耳朵上播」和「耳机放在桌上播」——但后者本来也少。
2. 电量粒度是 1%，短于十几分钟的静默佩戴拿不到电量证据，只能算进「连接（上限）」。
3. 只看当前这一副设备（默认 AirPods 优先）。同时连两副耳机时不做并行统计。
4. 久戴提醒走 `osascript display notification`，通知来源会显示为「脚本编辑器」而不是 AirWear（换来的是零权限、零签名依赖）。菜单栏图标变色和弹窗横幅不受影响。
5. 菜单栏那一格是否显示文字，取决于 `MenuBarExtra` 的 `Label` 渲染。如果你只看到图标没看到时长，把 `Sources/AirWear/AirWearApp.swift` 里的 `Label(model.menuBarTitle, systemImage:)` 换成 `Text(model.menuBarTitle)` 即可。标题变化都会写进日志（`菜单栏标题 →` 那几行），可据此确认数据侧是好的。

## 数据与日志的位置

- `~/Library/Application Support/AirWear/sessions.sqlite3` —— 区间数据库（首次启动从旧 `sessions.json` 导入）
- `~/Library/Application Support/AirWear/widget.json` —— 给小组件的扁平快照
- `~/Library/Logs/AirWear/AirWear.log` —— 运行日志（超过 2MB 自动截断）

环境变量 `AIRWEAR_DATA_DIR` / `AIRWEAR_LOG_DIR` 可以覆盖前两个目录（调试用）。

所有数据都只在本机，不上传任何地方。
