#!/bin/bash
# 版本号自增：0.1.0 → 0.1.1（patch）/ 0.2.0（minor）/ 1.0.0（major）
#
# 版本号的唯一来源是 Resources/Info.plist 的 CFBundleShortVersionString。
# 本脚本把这个数字算出来写回去，并同步 README / docs 里写死的产物文件名，
# 所以你不会因为漏改一处而让文档指向一个不存在的文件。
#
# 构建号（CFBundleVersion）不归这里管 —— 它由 Makefile 从 git 提交数自动派生。
#
# 用法：
#   scripts/bump-version.sh patch              # 写入：0.1.0 → 0.1.1
#   scripts/bump-version.sh minor --dry-run    # 只看会变成什么，不写文件
set -euo pipefail
cd "$(dirname "$0")/.."

PART="${1:-}"
DRY="${2:-}"
case "${PART}" in
  patch | minor | major) ;;
  *)
    echo "用法：$0 patch|minor|major [--dry-run]" >&2
    exit 1
    ;;
esac

PLIST="Resources/Info.plist"
CUR="$(plutil -extract CFBundleShortVersionString raw "${PLIST}")"

# 只接受 x.y.z；否则下面的算术会静默算出错误结果
if ! [[ "${CUR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ ${PLIST} 里的版本号不是 x.y.z 形式：'${CUR}'" >&2
  exit 1
fi

IFS=. read -r MA MI PA <<<"${CUR}"
case "${PART}" in
  major) MA=$((MA + 1)); MI=0; PA=0 ;;
  minor) MI=$((MI + 1)); PA=0 ;;
  patch) PA=$((PA + 1)) ;;
esac
NEW="${MA}.${MI}.${PA}"

echo "  ${CUR} → ${NEW}  （${PART}）"

if [ "${DRY}" = "--dry-run" ]; then
  echo "  （--dry-run：未写入任何文件）"
  exit 0
fi

# 只改 key 后面那一行，其余原样保留（plutil -replace 会吃掉 plist 里的注释）
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>${NEW}</string>|;}" "${PLIST}"

# 文档里写死的产物文件名一并跟上
for f in README.md docs/distribution.md; do
  [ -f "${f}" ] || continue
  sed -i '' -E "s/AirWear-[0-9]+\.[0-9]+\.[0-9]+\.(zip|dmg)/AirWear-${NEW}.\1/g" "${f}"
done

echo "  ✅ 已写入 ${PLIST}，并同步 README.md / docs/distribution.md"
echo
echo "  接着："
echo "    make release                    # 出包（文件名自动用 ${NEW}）"
echo "    git add -A && git commit -m \"v${NEW}\""
echo "    make tag                        # 按版本号自动打 tag"
echo "    git push --follow-tags"
