#!/bin/bash
#
# AirWear 安装脚本
#
# ── 为什么需要这个脚本 ───────────────────────────────────────────
# AirWear 没有购买付费的 Apple 开发者证书，所以从网络下载的 App 会被 macOS
# 打上「隔离标记」(com.apple.quarantine)。带这个标记的 App 首次启动时，
# Gatekeeper 会要求「Developer ID 签名 + 已公证」——两个条件都不满足，于是被拦。
#
#   1. 把 zip 解压到 /Applications
#   2. 抹掉解压出来的 App 上的隔离标记（xattr -dr）
#   3. 启动它
#
# 全程只动 /Applications/AirWear.app。
#
# ── 用法 ────────────────────────────────────────────────────────
#   bash install.sh ~/Downloads/AirWear-0.1.0.zip
#
# 不带参数时会在 ~/Downloads 里自动找 AirWear-*.zip。

set -euo pipefail

APP_NAME="AirWear"
DEST="/Applications/${APP_NAME}.app"

ZIP="${1:-}"
if [ -z "$ZIP" ]; then
    ZIP="$(ls -t "$HOME"/Downloads/${APP_NAME}-*.zip 2>/dev/null | head -1 || true)"
    if [ -z "$ZIP" ]; then
        echo "✗ 没找到 zip。用法：bash install.sh ~/Downloads/${APP_NAME}-0.1.0.zip" >&2
        exit 1
    fi
    echo "→ 自动选中：$ZIP"
fi

if [ ! -f "$ZIP" ]; then
    echo "✗ 文件不存在：$ZIP" >&2
    exit 1
fi

# 解压到临时目录，先确认里面确实是我们想要的 App，再动 /Applications
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ 解压到临时目录…"
ditto -x -k "$ZIP" "$TMP"

SRC="$TMP/${APP_NAME}.app"
if [ ! -d "$SRC" ]; then
    echo "✗ 这个 zip 里没有 ${APP_NAME}.app，确认下载的是正确的包？" >&2
    echo "  实际内容：" >&2
    ls -1 "$TMP" >&2
    exit 1
fi

if [ -d "$DEST" ]; then
    echo "→ 已存在旧版本，先退出它并替换"
    pkill -x "$APP_NAME" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.3
    done
    rm -rf "$DEST"
fi

echo "→ 安装到 $DEST"
ditto "$SRC" "$DEST"

echo "→ 抹掉隔离标记（这一步就是绕过 Gatekeeper 的必要动作）"
xattr -dr com.apple.quarantine "$DEST" || true

echo "→ 启动"
open "$DEST"

echo
echo "✅ 装好了。菜单栏右上角会出现 AirWear（一个 AirPods 图标 + 今日佩戴时长）。"
echo "   找不到的话：确认没有在「系统设置 → 控制中心」里把它藏起来。"
echo
echo "   卸载：rm -rf \"$DEST\""
echo "   数据：~/Library/Application Support/AirWear/（删掉即彻底清除记录）"
