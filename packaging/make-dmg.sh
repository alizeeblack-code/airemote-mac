#!/usr/bin/env bash
#
# 把 JoyCoding.app 打成可拖拽安装的 DMG。
#
#   packaging/make-dmg.sh <app 路径> <输出 dmg 路径> <卷名>
#
# 用系统自带的 hdiutil 而不是 create-dmg —— 后者要 brew 装, 而这是个公开仓库,
# 任何人 clone 下来应该直接能构建, 不该先配工具链。
#
# ⚠️ DMG 必须**自己再签名 + 公证一次**, 不能只靠里面 app 的票据: 用户下载的是
# DMG, Gatekeeper 检查的也是 DMG。这一步在 build.sh 里做, 本脚本只负责做盘。
set -euo pipefail

APP="${1:?用法: make-dmg.sh <app> <out.dmg> <volname>}"
OUT="${2:?}"
VOLNAME="${3:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# 窗口与图标坐标。和背景图是一套: 背景 600×400, 箭头从 x≈240 指到 x≈345,
# 所以两个图标分别摆在箭头两端。
WIN_W=600; WIN_H=400
ICON_SIZE=104
APP_X=150;  APP_Y=196
LINK_X=450; LINK_Y=196

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "  · 准备内容"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
# ⚠️ 高分屏: 光放 bg.png + bg@2x.png 不保险 —— Finder 对 DMG 背景不一定认
# @2x 命名。Apple 的正式做法是打成**多分辨率 TIFF**, 由系统自己挑,
# Retina 上才不会糊。tiffutil 是系统自带的。
tiffutil -cathidpicheck "$HERE/dmg-background.png" "$HERE/dmg-background@2x.png" \
    -out "$STAGE/.background/bg.tiff" >/dev/null

RW="$(mktemp -u).dmg"
echo "  · 建可写盘"
# 预留 40MB 余量: app 才 ~2MB, 但 HFS+ 目录结构和 .DS_Store 也要地方
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -size 60m "$RW" >/dev/null

echo "  · 挂载并设置窗口外观"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | \
       awk '/\/dev\/disk/{print $1; exit}')"
MOUNT="/Volumes/$VOLNAME"
# 挂载点偶尔要一两秒才出现
for _ in $(seq 1 20); do [ -d "$MOUNT" ] && break; sleep 0.3; done
[ -d "$MOUNT" ] || { echo "❌ 挂载失败"; hdiutil detach "$DEV" >/dev/null 2>&1; exit 1; }

APPNAME="$(basename "$APP")"
osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + 22))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set background picture of theViewOptions to file ".background:bg.tiff"
    set position of item "$APPNAME" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$LINK_X, $LINK_Y}
    close
    open
    update without registering applications
    delay 1.5
  end tell
end tell
APPLESCRIPT

# 让 Finder 把 .DS_Store 落盘, 否则窗口设置不会带进最终镜像
sync; sleep 1
hdiutil detach "$DEV" >/dev/null

echo "  · 压缩成只读镜像"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
echo "  · $(du -h "$OUT" | cut -f1)  $OUT"
