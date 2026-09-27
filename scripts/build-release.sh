#!/bin/sh
#
#  build-release.sh
#  Deep Sleep
#
#  构建 Release 并打包成 GitHub Release 需要的两个文件：
#
#      DeepSleep.zip            —— 应用本体（文件名固定，自动更新会去找它）
#      DeepSleep.zip.sha256     —— 摘要文件（可选，但有的话自动更新会校验）
#
#  用法：scripts/build-release.sh
#  产物：build/release/ 下
#
#  注意 zip 内必须是「Deep Sleep.app」这一层，而不是它的内容 ——
#  ditto 的 --keepParent 正是为此。少了它，自动更新解出来的会是一堆
#  散文件而不是一个可替换的 .app。
#

set -eu

cd "$(dirname "$0")/.."

VERSION=$(/usr/bin/sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
if [ -z "$VERSION" ]; then
    echo "无法从 project.yml 读出 MARKETING_VERSION" >&2
    exit 1
fi

OUT="build/release"
APP="build/Build/Products/Release/Deep Sleep.app"

echo "==> 版本 $VERSION"
echo "==> 生成工程"
/usr/local/bin/xcodegen generate >/dev/null 2>&1 || xcodegen generate >/dev/null

echo "==> 构建 Release"
xcodebuild -project DeepSleep.xcodeproj \
           -scheme DeepSleep \
           -configuration Release \
           -derivedDataPath build \
           build -quiet

if [ ! -d "$APP" ]; then
    echo "构建产物不存在：$APP" >&2
    exit 1
fi

# 产物里的版本号必须与 project.yml 一致，否则自动更新会认为下载的包
# 与 Release 声称的版本不符而拒绝安装 —— 与其等到用户那边才发现，不如这里就拦下。
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "版本不一致：project.yml 是 $VERSION，产物是 $BUILT_VERSION" >&2
    exit 1
fi

echo "==> 打包"
/bin/rm -rf "$OUT"
/bin/mkdir -p "$OUT"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUT/DeepSleep.zip"

echo "==> 计算摘要"
cd "$OUT"
/usr/bin/shasum -a 256 DeepSleep.zip | /usr/bin/awk '{print $1}' > DeepSleep.zip.sha256

echo
echo "产物："
/bin/ls -lh DeepSleep.zip DeepSleep.zip.sha256
echo
echo "发 Release 用："
echo "  gh release create v$VERSION '$OUT/DeepSleep.zip' '$OUT/DeepSleep.zip.sha256' \\"
echo "     --title 'v$VERSION' --notes '...'"
