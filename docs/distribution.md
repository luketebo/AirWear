# 打包与分发

## 生成安装包

```bash
make dmg          # → dist/AirWear-<版本>.dmg（App + 指向 /Applications 的快捷方式，拖进去即安装）
make zip          # → dist/AirWear-<版本>.zip
make verify-dmg   # 挂载 DMG 自检：内容 / 签名 / Gatekeeper 评估
```

只用了系统自带的 `hdiutil`，不依赖 `create-dmg` 之类的外部工具。
打包后会删掉 `build/AirWear.app`，保持「系统里只有一份已注册的 App」这个不变量
（同一个 bundle id 有多份副本会让 `pkd` 选错）。

## 「能不能给别人用」取决于证书，不取决于打包

`make verify-dmg` 会给出关键指标：

```
$ make verify-dmg
dist/.mount/AirWear.app: valid on disk
dist/.mount/AirWear.app: satisfies its Designated Requirement
dist/.mount/AirWear.app: rejected          ← spctl --assess 的结果
```

| 证书 | Gatekeeper | 结果 |
|---|---|---|
| **Apple Development**（免费账号能拿到的） | **rejected** | 只能自己留档 / 内部机器用。别人打开会看到「Apple 无法验证此 App」或「已损坏」 |
| **Developer ID Application** + 公证 | accepted | 双击即开、零警告，可公开分发 |

**这不是技术问题，是规则问题**：从网络下载的文件会带上 `com.apple.quarantine` 隔离标记，
带标记的 App 首次启动必须同时满足「Developer ID 签名 + 已公证」，否则被拦。
免费 Apple ID 只能签发 Development 证书，做不到这一点。

### 为什么很多开源 macOS App 还是买了 $99/年

因为**不给钱，成本没有消失，只是从作者转移到了每个用户那里**。
一份 $99/年 的会员覆盖**无限个 App**，而且**已公证的 App 永久有效**——明年不续费，
用户手里装好的照常能用，只是不能再公证新版本。

看一下真实分布（统计自一台日常使用的 Mac 的 `/Applications`，共 56 个 App）：

| 分发方式 | 数量 |
|---|---|
| App Store | 20 |
| 站外 Developer ID + 公证 | 28 |
| 站外但未公证/无签名 | 8 |

第二档里大量是个人 / 小团队 / 开源项目（FineTune、Ghostty、draw.io、Typora、Mos、Kap…）。
用 `codesign -dvvv` 看一眼就知道，比如 FineTune：

```
Authority = Developer ID Application: Ronit Singh (MA94NC8B2C)
flags     = 0x10000(runtime)
Gatekeeper= accepted, source=Notarized Developer ID
```

它是开源的（[ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune)），作者是个人开发者。
**开源和自付 $99/年 一点都不矛盾。**

## 不买证书时，用户怎么装

### 方式一：一行命令（推荐给同事 / 同学）

对方从 Release 页面下载 `AirWear-x.y.z.zip` 后运行：

```bash
unzip -q -o ~/Downloads/AirWear-0.1.0.zip -d /Applications && \
xattr -dr com.apple.quarantine /Applications/AirWear.app && \
open /Applications/AirWear.app
```

仓库里也带了 `install.sh`，做的是同一件事，但带注释、可逐行读——
**朋友更愿意执行自己看得懂的命令**：

```bash
bash install.sh ~/Downloads/AirWear-0.1.0.zip
```

### 方式二：DMG + 首次右键打开

双击 DMG → 把 App 拖进 Applications → **首次右键点 App → 打开** → 之后系统会记住。

（macOS 15+ 上这个入口被藏得比较深：双击被拦后要去 系统设置 → 隐私与安全性 → 「仍要打开」。）

## 拿到 Developer ID 之后的完整流程

```bash
make notarize-setup   # 存一次凭证（Apple ID + App 专用密码 + Team ID → 进钥匙串 profile AirWearNotary）
make dmg              # 重打包（会自动用 Developer ID 给 DMG 本身也签名）
make notarize         # notarytool 提交 + stapler 钉票
make verify-dmg       # 复查：这次 spctl 应该是 accepted
```

`make notarize` 里有硬性检查：没有 Developer ID 证书就直接报错退出
（`notarytool` 不接受 Apple Development 证书），不会让你提交一个注定被拒的包。

### 还差两处细节（有证书后应补上）

1. **`codesign` 需要 `--timestamp`**（安全时间戳），这是公证的硬性要求。
   应当只在用 Developer ID 签名时加，避免没网时构建失败。
2. **正确顺序是分别公证两次**：先把 `.app` 打成 zip 提交公证 → `stapler` 钉票；再打包 DMG →
   签名 → 公证 → 钉票。只公证 DMG 的话，用户把 App 从 DMG 里拖出来之后再被重新打标记就会出问题。

> 顺带值得一提：`stapler staple` 不是可选项。上面那台 Mac 上的 FineTune
> **没有**把票据钉在 App 上（`does not have a ticket stapled to it`），
> 这意味着它首次启动需要**联网**去 Apple 服务器核对公证记录——断网环境下首次打开会被拦。
