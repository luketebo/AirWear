APP_NAME    := AirWear
SRC_DIR     := Sources/AirWear
SHARED_DIR  := Sources/Shared
WIDGET_DIR  := Sources/AirWearWidget
WIDGET_NAME := AirWearWidget
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
BIN         := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
WIDGET_BUNDLE := $(BUNDLE)/Contents/PlugIns/$(WIDGET_NAME).appex
WIDGET_BIN    := $(WIDGET_BUNDLE)/Contents/MacOS/$(WIDGET_NAME)
CACHE       := $(BUILD_DIR)/modulecache
ICNS        := $(BUNDLE)/Contents/Resources/AppIcon.icns

# 体检类命令用哪个可执行文件：已装到 /Applications 就优先用它。
# 为什么重要：CLI 目标若依赖 build，跑一次 `make today` 就会重新生成 build/AirWear.app，
# 于是又出现「同 bundle id 两份副本」（pkd 可能选中陈旧那份），而且每条命令都要重编译一遍。
INSTALLED_BIN := /Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
CLI_BIN     := $(shell test -x $(INSTALLED_BIN) && echo $(INSTALLED_BIN) || echo $(BIN))
INSTALLED_WIDGET := /Applications/$(APP_NAME).app/Contents/PlugIns/$(WIDGET_NAME).appex
CLI_WIDGET_BUNDLE := $(shell test -d $(INSTALLED_WIDGET) && echo $(INSTALLED_WIDGET) || echo $(WIDGET_BUNDLE))

# 分发用
DIST_DIR   := dist
VERSION    := $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist 2>/dev/null || echo 0.0.0)
# 构建号自动 = git 提交数：不用手改，且单调递增（Apple 要求每次提交递增）
BUILD      := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
DMG        := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGE  := $(DIST_DIR)/.stage
ZIP        := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip

# 开机自启指向哪一份：优先已安装的（工作区副本会被 make install 清掉）
AUTOSTART_APP := $(shell test -d /Applications/$(APP_NAME).app && echo /Applications/$(APP_NAME).app || echo $(CURDIR)/$(BUNDLE))

# 主 App 也编译小组件的视图文件（不带 AIRWEAR_WIDGET_EXTENSION），只为离屏渲染预览
SOURCES     := $(wildcard $(SRC_DIR)/*.swift) $(wildcard $(SHARED_DIR)/*.swift) $(WIDGET_DIR)/$(WIDGET_NAME).swift
WIDGET_SRC  := $(wildcard $(WIDGET_DIR)/*.swift) $(wildcard $(SHARED_DIR)/*.swift)

# clang 模块缓存必须显式指向可写目录（默认在 /var/folders，受限环境下不可写）
PYTHON      ?= python3

SWIFTFLAGS := -parse-as-library -O -module-cache-path $(CACHE)

# 小组件扩展必须被真实证书签名，系统才会加载它；没有证书时退回 ad-hoc（可用性会打折，见 README）
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

# 主 App / 扩展都不进沙箱。
#
# 这是踩坑之后的结论：entitlements 里只要出现 restricted 权限
# （app-sandbox + temporary-exception.* 之类），而这些权限没有 provisioning profile
# 授权，进程就会在 dyld 阶段被 _libsecinit_appsandbox abort
# （exit=133 / Trace/BPT trap: 5，崩溃报告栈顶就是 _libsecinit_appsandbox）。
# 症状极具迷惑性：chronod 明明"启动了扩展"，紧接着就报 "process does not exist"，
# 看起来像没注册，实际是一启动就死。
#
# 本机只有 Apple Development 证书、没有描述文件，所以：
#   · 扩展不沙箱 → 直接读 ~/Library/Application Support/AirWear/widget.json（AppPaths 拼真实 home）
#   · 主 App 不沙箱 → CoreAudio + system_profiler + osascript 全部照常
# Resources/Widget.entitlements 保持空字典，详见其中的完整记录。
APP_SANDBOX ?= 0
ifeq ($(APP_SANDBOX),1)
$(warning APP_SANDBOX=1：本机无 provisioning profile，restricted 权限会让进程启动即 abort，仅供有描述文件时使用)
APP_ENTITLEMENTS := --entitlements Resources/AirWear.entitlements
else
APP_ENTITLEMENTS :=
endif

.PHONY: all version tag build run stop install uninstall release dmg zip icon notarize notarize-setup verify-dmg widget-doctor dump watch today week export render render-widget widget-status log clean autostart unautostart help

all: build

## icon: 重新生成 App 图标（改 scripts/make-icon.py 的参数后运行；需 pip install pillow numpy）
icon:
	@$(PYTHON) scripts/make-icon.py $(if $(GLYPH),--glyph $(GLYPH),)

## version: 显示将要打包的版本号
version:
	@echo "  $(APP_NAME) $(VERSION) (build $(BUILD))"


## tag: 按当前版本号打 git tag（v$(VERSION)），重复打会报错
tag:
	@git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null 2>&1 && { echo "✗ tag v$(VERSION) 已存在；要重打先 git tag -d v$(VERSION)"; exit 1; } || true
	@git diff --quiet HEAD 2>/dev/null || echo "  ⚠️  有未提交的改动，tag 会指向 HEAD 而不是你的工作区"
	@git tag -a "v$(VERSION)" -m "v$(VERSION)" && echo "  ✅ 已打 tag v$(VERSION)（推送：git push --follow-tags）"

## build: 编译并组装 AirWear.app + 内嵌小组件扩展，然后由内向外签名
build: $(BIN) $(BUNDLE)/Contents/Info.plist $(ICNS) $(WIDGET_BIN) $(WIDGET_BUNDLE)/Contents/Info.plist
	@codesign --force --options runtime --sign "$(SIGN_ID)" --entitlements Resources/Widget.entitlements $(WIDGET_BUNDLE)
	@codesign --force --options runtime --sign "$(SIGN_ID)" $(APP_ENTITLEMENTS) $(BUNDLE)
	@echo "✅ 构建完成：$(BUNDLE)"
	@echo "   签名身份：$(SIGN_ID)"
	@echo "   内嵌小组件：$(WIDGET_BUNDLE)"
	@echo "   沙箱：未启用（本机无 provisioning profile，restricted 权限会让进程启动即被 abort）"

$(BIN): $(SOURCES)
	@mkdir -p $(CACHE) $(BUNDLE)/Contents/MacOS
	swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BIN)

$(WIDGET_BIN): $(WIDGET_SRC) 
	@mkdir -p $(CACHE) $(WIDGET_BUNDLE)/Contents/MacOS
	swiftc $(SWIFTFLAGS) -D AIRWEAR_WIDGET_EXTENSION $(WIDGET_SRC) -o $(WIDGET_BIN)

$(BUNDLE)/Contents/Info.plist: Resources/Info.plist
	@mkdir -p $(BUNDLE)/Contents
	@cp $< $@
	@plutil -replace CFBundleVersion -string "$(BUILD)" $@

# 图标：.icns 已入库，普通构建不需要 Python/Pillow；想重新生成用 make icon
$(ICNS): Resources/AppIcon.icns
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp Resources/AppIcon.icns $@

# 小组件的版本号从主 App 派生，所以只需维护一处（改 Resources/Info.plist）
$(WIDGET_BUNDLE)/Contents/Info.plist: $(WIDGET_DIR)/Info.plist Resources/Info.plist
	@mkdir -p $(WIDGET_BUNDLE)/Contents
	@cp $< $@
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" $@
	@plutil -replace CFBundleVersion -string "$(BUILD)" $@

## run: 启动菜单栏 App（仅开发用；已装到 /Applications 时请改用 make install）
run: build
	@test -d /Applications/$(APP_NAME).app && echo "⚠️ /Applications 已有同 bundle id 副本，本次启动会造成双副本；建议改用 make install" || true
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.3; done
	@open $(BUNDLE)
	@echo "AirWear 已启动，看菜单栏的 AirPods 图标 🎧"

## stop: 退出 App
stop:
	@pkill -x $(APP_NAME) 2>/dev/null && echo "已退出" || echo "未在运行"

## install: 安装到 /Applications，并清掉工作区副本（同 bundle id 双副本会让 pkd 选错）
install: build
	@rm -rf /Applications/$(APP_NAME).app
	@ditto $(BUNDLE) /Applications/$(APP_NAME).app
	@rm -rf $(BUNDLE)
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.3; done
	@open /Applications/$(APP_NAME).app
	@echo "✅ 已安装并启动：/Applications/$(APP_NAME).app"
	@echo "   已同时删除 $(BUNDLE)，避免同 bundle id 两份副本（pkd 可能选中陈旧那份）"
	@echo "   ⚠️ 之后请用 make install 更新，不要再用 make run（那会重新生成工作区副本）"

## uninstall: 卸载 /Applications 里的副本
uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(APP_NAME).app
	@echo "✅ 已卸载 /Applications/$(APP_NAME).app"

## dump: 打印音频设备 + AirPods 电量 + 当前判定状态
dump:
	@$(CLI_BIN) --dump

## watch: 前台监听佩戴状态变化（默认 30s，Ctrl-C 退出）
watch:
	@$(CLI_BIN) --watch $(or $(SECONDS),30)

## today: 打印今日统计
today:
	@$(CLI_BIN) --today

## week: 打印最近 7 天统计
week:
	@$(CLI_BIN) --week

## export: 导出 CSV，用法 make export F=~/Desktop/airwear.csv
export:
	@$(CLI_BIN) --export $(or $(F),./airwear-export.csv)

## render: 渲染界面预览图，用法 make render F=./preview.png
render:
	@$(CLI_BIN) --render $(or $(F),./preview.png) --demo

## render-widget: 渲染小组件预览图（小/中两种尺寸），用法 make render-widget F=./widget
render-widget:
	@$(CLI_BIN) --render-widget $(or $(F),./preview-widget) --demo

## widget-status: 查看小组件扩展的注册与加载状态（系统是否认这个 appex）
widget-status:
	@echo "=== PlugInKit 注册情况 ==="
	@pluginkit -m -v -p com.apple.widgetkit-extension 2>/dev/null | grep -i airwear || echo "  未注册（先启动一次宿主 App）"
	@echo
	@echo "=== appex 签名 ==="
	@codesign -dvvv $(CLI_WIDGET_BUNDLE) 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true
	@echo
	@echo "=== 小组件快照文件 ==="
	@$(CLI_BIN) --widget-status

## widget-doctor: 修复小组件在画廊里不显示（注册 / 选用 / 守护进程缓存）
widget-doctor:
	@bash scripts/widget-doctor.sh

## log: 查看日志
## dmg: 打包成可分发 DMG（App + 拖进 Applications 的快捷方式）
dmg: build
	@rm -rf $(DMG_STAGE) $(DMG)
	@mkdir -p $(DMG_STAGE)
	@ditto $(BUNDLE) $(DMG_STAGE)/$(APP_NAME).app
	@ln -s /Applications $(DMG_STAGE)/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_STAGE) -ov -format UDZO $(DMG) >/dev/null
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then \
		codesign --force --sign "$$(security find-identity -v -p codesigning | sed -n 's/.*\"\(Developer ID Application: [^\"]*\)\".*/\1/p' | head -1)" $(DMG); \
	fi
	@rm -rf $(DMG_STAGE) $(BUNDLE)
	@echo ""
	@echo "✅ 已生成：$(DMG)（$$(du -h $(DMG) | cut -f1)）"
	@echo "   内容：$(APP_NAME).app + 指向 /Applications 的快捷方式（拖进去即安装）"
	@echo "   已删除 $(BUNDLE)，保持系统里只有一份已注册的 App"
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then \
		echo "   签名：Developer ID 可用 → 建议接着跑 make notarize 做公证"; \
	else \
		echo ""; \
		echo "⚠️ 本机只有 Apple Development 证书，没有 Developer ID Application，所以这个 DMG："; \
		echo "   · 适合你自己留档 / 内部机器用，不适合公开分发"; \
		echo "   · 别人首次打开会看到「Apple 无法验证此 App」或「已损坏」"; \
		echo "   · 对方绕过方式（二选一）："; \
		echo "       右键点 App → 打开（只需一次）"; \
		echo "       xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"; \
		echo "   · 想做到双击即开、零警告：需要 Developer ID Application 证书（付费开发者账号）"; \
		echo "     然后：make notarize-setup（存一次凭证）→ make notarize"; \
	fi

## zip: 打成 zip（比 DMG 轻，但少了拖拽安装的引导）
zip: build
	@rm -f $(ZIP)
	@mkdir -p $(DIST_DIR)
	@ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@rm -rf $(BUNDLE)
	@echo "✅ 已生成：$(ZIP)（$$(du -h $(ZIP) | cut -f1)）"

## release: 一次产出 dmg + zip + SHA256（分发用）
# 刻意不在配方里链式调用 dmg/zip：那两个目标各自会在结束时删掉 build/AirWear.app
# （保持"系统里只有一份已注册 App"），链式调用会导致第二次重编译。
release: build
	@rm -rf $(DMG_STAGE) $(DMG) $(ZIP)
	@mkdir -p $(DMG_STAGE)
	@ditto $(BUNDLE) $(DMG_STAGE)/$(APP_NAME).app
	@ln -s /Applications $(DMG_STAGE)/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_STAGE) -ov -format UDZO $(DMG) >/dev/null
	@ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@rm -rf $(DMG_STAGE) $(BUNDLE)
	@echo ""
	@echo "✅ 产物（dist/）："
	@ls -lh $(DMG) $(ZIP) | awk '{printf "   %-46s %s\n", $$9, $$5}'
	@echo ""
	@echo "SHA256（放到 Release 说明里）："
	@shasum -a 256 $(DMG) $(ZIP) | sed 's/^/   /'
	@echo ""
	@echo ""
	@echo "  AirWear 安装："
	@echo "  1) 下载 $(notdir $(ZIP))（把 GitHub Release 页面的链接贴这里）"
	@echo "  2) 打开「终端」执行这三行："
	@echo "     unzip -q -o ~/Downloads/$(notdir $(ZIP)) -d /Applications && \\"
	@echo "     xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app && \\"
	@echo "     open /Applications/$(APP_NAME).app"
	@echo ""

## notarize-setup: 把公证凭证存进钥匙串（只需一次；需 Apple ID + App 专用密码 + Team ID）
notarize-setup:
	@echo "需要三样东西："
	@echo "  1. Apple ID（开发者账号邮箱）"
	@echo "  2. App 专用密码（appleid.apple.com → 登录与安全 → App 专用密码）"
	@echo "  3. Team ID（开发者后台 Membership 页面）"
	xcrun notarytool store-credentials AirWearNotary

## notarize: 提交公证并把票据钉到 DMG 上（需先 make dmg，且要有 Developer ID 证书）
notarize:
	@test -f $(DMG) || { echo "✗ 先跑 make dmg"; exit 1; }
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" \
		|| { echo "✗ 缺少 Developer ID Application 证书，无法公证（Apple Development 证书不被 notarytool 接受）"; exit 1; }
	xcrun notarytool submit $(DMG) --keychain-profile AirWearNotary --wait
	xcrun stapler staple $(DMG)
	@echo "✅ 公证完成并已钉票，现在这个 DMG 双击即开、零警告"

## verify-dmg: 挂载 DMG 检查内容（分发前自检）
verify-dmg:
	@test -f $(DMG) || { echo "✗ 先跑 make dmg"; exit 1; }
	@rm -rf $(DIST_DIR)/.mount && mkdir -p $(DIST_DIR)/.mount
	@hdiutil attach $(DMG) -nobrowse -mountpoint $(DIST_DIR)/.mount >/dev/null
	@echo "=== DMG 内容 ==="; ls -la $(DIST_DIR)/.mount
	@echo "=== App 签名校验 ==="; codesign --verify --deep --strict --verbose=2 $(DIST_DIR)/.mount/$(APP_NAME).app 2>&1 | tail -2
	@echo "=== Gatekeeper 评估（分发关键指标）==="
	@spctl --assess --type execute --verbose=4 $(DIST_DIR)/.mount/$(APP_NAME).app 2>&1 | tail -3 || true
	@hdiutil detach $(DIST_DIR)/.mount >/dev/null && rmdir $(DIST_DIR)/.mount && echo "（已卸载）"

## log: 查看日志
log:
	@tail -n 40 "$$HOME/Library/Logs/AirWear/AirWear.log" 2>/dev/null || echo "暂无日志"

## autostart: 注册开机自启（LaunchAgent）
autostart:
	@test -d $(AUTOSTART_APP) || { echo "✗ 找不到 $(AUTOSTART_APP)，先跑 make install（或 make build）"; exit 1; }
	@mkdir -p "$$HOME/Library/LaunchAgents"
	@sed "s|__BUNDLE__|$(AUTOSTART_APP)|g" Resources/com.airwear.mac.plist \
		> "$$HOME/Library/LaunchAgents/com.airwear.mac.plist"
	@launchctl unload "$$HOME/Library/LaunchAgents/com.airwear.mac.plist" 2>/dev/null || true
	@launchctl load "$$HOME/Library/LaunchAgents/com.airwear.mac.plist"
	@echo "✅ 已注册开机自启：$(AUTOSTART_APP)"

## unautostart: 取消开机自启
unautostart:
	@launchctl unload "$$HOME/Library/LaunchAgents/com.airwear.mac.plist" 2>/dev/null || true
	@rm -f "$$HOME/Library/LaunchAgents/com.airwear.mac.plist"
	@echo "✅ 已取消开机自启"

## clean: 清理构建产物
clean:
	rm -rf $(BUILD_DIR)
	@echo "已清理"

## help: 显示可用命令
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
