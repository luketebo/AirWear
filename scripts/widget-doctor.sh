#!/bin/bash
# AirWear 小组件可见性排查 / 修复
#
# 依据：CodexBar 的 widgets 可见性排查文档（同为「菜单栏 App + WidgetKit 扩展」）
#   "When widgets do not appear in the gallery at all, the issue is almost always
#    registration, signing, or daemon caching (not SwiftUI code)."
#
# 关键概念：PlugInKit 有「选用（election）」机制。
#   pluginkit -m 输出里 `+` = 已选用（可见），`-` = 被忽略（画廊里看不见）。
#   光把 appex 拷进 PlugIns 是不够的，必须 -a 注册 + -e use 选用，
#   再让 pkd/chronod 丢掉缓存重新扫描。

# 注意：脚本刻意不用 `set -u`。
# 这是给用户跑的诊断脚本，中途因未定义变量崩掉（曾因 `$APP` 紧跟全角括号触发）
# 会让后面真正要做的注册/选用步骤全跑不到，代价远大于收益。
# 变量一律用 ${VAR} 形式，避免紧跟非 ASCII 字符时被当成变量名的一部分。

WIDGET_ID="com.airwear.mac.widget"
POINT="com.apple.widgetkit-extension"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# 优先用 /Applications 里的正式副本（系统守护进程只认一个来源）
if [ -d "/Applications/AirWear.app" ]; then
    APP="/Applications/AirWear.app"
else
    APP="$REPO/build/AirWear.app"
fi
WAPPEX="$APP/Contents/PlugIns/AirWearWidget.appex"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "宿主 App ：$APP"
echo "扩展     ：$WAPPEX"
echo

# ---------- 1. 包结构 ----------
echo "== 1/6 包结构 =="
if [ ! -d "$WAPPEX" ]; then
    echo "  ❌ 找不到 appex —— 先跑 make build"
    exit 1
fi
echo "  ✅ appex 存在"
echo -n "  NSExtensionPointIdentifier: "
plutil -extract NSExtension.NSExtensionPointIdentifier raw "$WAPPEX/Contents/Info.plist" 2>/dev/null || echo "(读不到!)"
echo -n "  CFBundlePackageType: "
plutil -extract CFBundlePackageType raw "$WAPPEX/Contents/Info.plist" 2>/dev/null || echo "(读不到!)"
echo -n "  可执行文件: "
[ -x "$WAPPEX/Contents/MacOS/AirWearWidget" ] && echo "✅ 有且可执行" || echo "❌ 缺失/不可执行"
echo

# ---------- 2. 签名 ----------
echo "== 2/6 签名校验 =="
codesign --verify --strict --verbose=2 "$WAPPEX" 2>&1 | sed 's/^/  /'
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2 | sed 's/^/  /'
echo -n "  TeamIdentifier: "
codesign -dvvv "$WAPPEX" 2>&1 | grep TeamIdentifier | sed 's/^/  /'
echo

# ---------- 3. 重复副本（同 bundle id 多份会让 pkd 选错）----------
echo "== 3/6 重复副本检查 =="
# 不依赖 Spotlight（mdfind 常返回空），直接查已知位置 + 再让 mdfind 补充
COPIES="$(
    {
        [ -d /Applications/AirWear.app ] && echo /Applications/AirWear.app
        [ -d "$REPO/build/AirWear.app" ] && echo "$REPO/build/AirWear.app"
        [ -d "$HOME/Applications/AirWear.app" ] && echo "$HOME/Applications/AirWear.app"
        mdfind -name "AirWear.app" 2>/dev/null
    } | grep -v '^$' | sort -u
)"
if [ -z "$COPIES" ]; then
    echo "  ⚠️ 一个都没找到（连 ${APP} 也不在？）"
else
    printf '%s\n' "$COPIES" | sed 's/^/  /'
    COUNT=$(printf '%s\n' "$COPIES" | wc -l | tr -d ' ')
    if [ "$COUNT" -gt 1 ]; then
        echo "  ⚠️ 有 ${COUNT} 份同 bundle id 副本 —— pkd 可能选中陈旧那一份，画廊里就看不到。"
        echo "     建议只留 ${APP} 一份，其余删掉："
        printf '%s\n' "$COPIES" | while IFS= read -r path; do
            [ "$path" = "$APP" ] && continue
            echo "       rm -rf '${path}'"
        done
    else
        echo "  ✅ 只有一份，无冲突"
    fi
fi
echo

# ---------- 4. 注册与选用 ----------
echo "== 4/6 PlugInKit 注册与选用 =="
echo "  注册前状态："
pluginkit -m -p "$POINT" -i "$WIDGET_ID" -vv 2>&1 | sed 's/^/    /' | head -10
echo "  强制注册 + 选用…"
pluginkit -a "$WAPPEX" 2>&1 | sed 's/^/    /'
pluginkit -e use -p "$POINT" -i "$WIDGET_ID" 2>&1 | sed 's/^/    /'
$LSREG -f "$APP" 2>&1 | sed 's/^/    /'
echo

# ---------- 5. 重启守护进程（缓存）----------
echo "== 5/6 重启 pkd / chronod / Dock（丢掉缓存重新扫描）=="
killall -9 pkd 2>/dev/null && echo "  pkd 已重启" || echo "  pkd 未在运行"
echo "  chronod 需要管理员权限，可能提示输入密码："
sudo killall -9 chronod 2>/dev/null && echo "  chronod 已重启" || echo "  chronod 未重启（跳过）"
killall Dock 2>/dev/null && echo "  Dock 已重启"
killall NotificationCenter 2>/dev/null && echo "  NotificationCenter 已重启"
sleep 3
echo

# ---------- 6. 复查 ----------
echo "== 6/6 复查 =="
RESULT=$(pluginkit -m -p "$POINT" -i "$WIDGET_ID" -vv 2>&1 | head -5)
if [ -n "$RESULT" ]; then
    echo "$RESULT" | sed 's/^/  /'
    case "$RESULT" in
        +*) echo "  ✅ 已选用（+）→ 画廊里应该能看到 AirWear 了" ;;
        -*) echo "  ⚠️ 仍被忽略（-）→ 再跑一次本脚本，或看下一步的日志" ;;
        *)  echo "  ⚠️ 状态不明，看上面输出" ;;
    esac
else
    echo "  ❌ 仍然查不到 —— pkd 没有接受这个扩展，问题在包结构或签名"
fi
echo
echo "现在打开画廊：右键桌面 → 编辑小组件 → 搜 AirWear"
echo "若还是没有，另开一个终端跑下面这行，把输出发我："
echo "  log stream --style compact --predicate '(process == \"pkd\" OR process == \"chronod\")' --timeout 60"
