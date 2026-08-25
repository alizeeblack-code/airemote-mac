#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/JoyCoding.app"
VERSION="0.6.0"

# 开关。原来只认第一个参数是不是 --no-notarize, 加了 --dmg 之后得正经解析,
# 否则 `./build.sh --dmg` 会被当成"要公证"而 `--no-notarize --dmg` 顺序敏感。
WANT_DMG=0
WANT_NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --dmg)         WANT_DMG=1 ;;
    --no-notarize) WANT_NOTARIZE=0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# 通用二进制: Intel Mac 也能跑。两个切片都是 minos 13.0,
# 代码里没有任何架构条件编译, 依赖的全是系统框架, 所以只是编两遍再合并。
echo "▸ 编译 (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/JoyCoding"

# 手机界面的 JS 是内联在 Swift 字符串里的, Swift 编译器看不见它的语法错误。
# 变量重名这类问题会让【整个脚本不执行】, 页面完全没反应, 而且不报错。
# 已经踩过两次, 所以放进构建流程。
if command -v node >/dev/null 2>&1; then
  echo "▸ 检查内联 JS"
  python3 - <<'PYEOF' > /tmp/joycoding-inline.js
import re
s = open("Sources/JoyCoding/RemoteUI.swift", encoding="utf-8").read()
m = re.search(r'private static let js = #"""(.*?)"""#', s, re.S)
print("const TOKEN='x';" + (m.group(1) if m else ""))
PYEOF
  node --check /tmp/joycoding-inline.js || { echo "❌ 内联 JS 有语法错误"; exit 1; }
fi

# 英文是默认语言, 翻译表漏一条就是中文漏给英文用户看。构建时点一遍。
# 手机页的坑: HTML/JS 都是 Swift 字符串, 里面写 L("…") 不会报错也不会生效。
# 普通 """ 里必须写成 \(L("…")), 裸 JS 里的 L() 必须有对应的 jsKeys 注入。
# 地址检测出过一次真实故障: 写死只查 en0, 别人机器走 en1 就退化成 127.0.0.1。
# 这组用例直接跑真实的 classify(), 不是复刻一份逻辑。
echo "▸ 检查地址分类"
swiftc -O Sources/JoyCoding/NetAddress.swift tools/nettest/main.swift \
  -o /tmp/joycoding-nettest 2>/dev/null
/tmp/joycoding-nettest || { echo "❌ 地址分类有回归"; exit 1; }

echo "▸ 测 DualSense 报告解析"
swiftc -O Sources/JoyCoding/DualSenseRaw.swift tools/dualsense-test/main.swift \
       -o /tmp/jc-ds-test 2>/dev/null && /tmp/jc-ds-test || { echo "❌ DualSense 解析用例失败"; exit 1; }

echo "▸ 检查手机页 L()"
python3 - <<'CHK' || exit 1
import re, sys
src = open("Sources/JoyCoding/RemoteUI.swift", encoding="utf-8").read()
keys = set(re.findall(r'"([^"]+)"',
           re.search(r'jsKeys = \[(.*?)\]', src, re.S).group(1)))

# JS 区间: 裸 js 常量 + 两个页面里的 <script> 块。其余算 HTML。
spans = []
i = src.index('let js = #"""')
spans.append((i, src.index('"""#', i)))
for m in re.finditer(r'<script>', src):
    spans.append((m.start(), src.index('</script>', m.start())))
inJS = lambda p: any(a <= p <= b for a, b in spans)

bad = []
for m in re.finditer(r'(.{2})L\("([^"]+)"\)', src):
    p, pre, k = m.start(1), m.group(1), m.group(2)
    if inJS(p):
        if k not in keys:
            bad.append(f'JS 调了 L("{k}") 但没进 jsKeys, 运行时拿不到译文')
    elif pre != r'\(' and p > src.index('static func pairPage'):
        bad.append(f'HTML 里的 L("{k}") 缺 \\( 插值, 会原样输出到页面')
if bad:
    print("❌ 手机页文案不会生效:")
    for b in bad: print("   ", b)
    sys.exit(1)
print(f"   ✅ jsKeys {len(keys)} 条, JS 调用与 HTML 插值均正确")
CHK

echo "▸ 检查翻译覆盖率"
python3 - <<'PYEOF'
import re, glob, sys, collections
src = open('Sources/JoyCoding/Translations.swift', encoding='utf-8').read()

# 重复 key 是**运行期陷阱**: 编译照过, 启动即 SIGTRAP
# ("Dictionary literal contains duplicate keys")。0824 就这么发过一个
# 启动即崩的本地构建 —— 这道检查必须在覆盖率之前。
i_zh, i_en = src.index('static let zh'), src.index('static let en')
for name, part in [('zh', src[i_zh:i_en]), ('en', src[i_en:])]:
    keys = re.findall(r'"((?:[^"\\]|\\.)*)"\s*:', part)
    dup = [k for k, c in collections.Counter(keys).items() if c > 1]
    if dup:
        print(f"  ❌ {name} 表有重复 key(启动会直接崩): {dup}")
        sys.exit(1)

# 条目可能一行写好几个, 不能只匹配行首
known = set(re.findall(r'"((?:[^"\\]|\\.)*)"\s*:\s*"', src))
miss = []
for f in glob.glob('Sources/JoyCoding/**/*.swift', recursive=True):
    if f.endswith('Translations.swift'): continue
    for line in open(f, encoding='utf-8'):
        st = line.strip()
        if st.startswith('//') or 'NSLog' in line: continue
        # 带参数的 L("x", y) 后面是逗号不是右括号, 老正则一律漏掉
        for lit in re.findall(r'L\("((?:[^"\\]|\\.)*)"\s*[,)]', line):
            if lit not in known: miss.append((f.split('/')[-1], lit))
# 短 key(不是中文原文的那些)如果 zh 表里没有, L() 会原样返回 key,
# 中文界面上就会出现 "noLanAddr" 这种字面量。上面的 known 是两张表
# 合起来算的, 所以拦不住 —— 这里单独查 zh 表。
_src = open('Sources/JoyCoding/Translations.swift', encoding='utf-8').read()
_zh = _src[_src.index('static let zh'):_src.index('static let en')]
_short = set()
for f in glob.glob('Sources/JoyCoding/**/*.swift', recursive=True):
    if f.endswith('Translations.swift'): continue
    _short |= set(re.findall(r'L\("([A-Za-z][A-Za-z0-9]*)"\s*[,)]', open(f, encoding='utf-8').read()))
_nozh = [k for k in sorted(_short) if '"%s":' % k not in _zh]
if _nozh:
    print("  ❌ %d 个短 key 缺中文, 中文界面会显示 key 本身:" % len(_nozh))
    for k in _nozh: print("     " + k)
    sys.exit(1)

if miss:
    print(f"  ⚠️ {len(miss)} 条 L() 包了但没翻译:")
    for f, l in miss[:10]: print(f"     {f}: {l}")
else:
    print(f"  ✅ 翻译表 {len(known)} 条, L() 调用全部覆盖")
PYEOF

echo "▸ 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JoyCoding"

# 两个切片都在, 才算通用包 —— 少一个的话装到 Intel 机上直接打不开
ARCHS="$(lipo -archs "$APP/Contents/MacOS/JoyCoding")"
case "$ARCHS" in
  *arm64*) case "$ARCHS" in *x86_64*) echo "   ✅ 通用二进制: $ARCHS";;
    *) echo "❌ 缺 x86_64 切片, 实际是: $ARCHS"; exit 1;; esac;;
  *) echo "❌ 缺 arm64 切片, 实际是: $ARCHS"; exit 1;;
esac
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>JoyCoding</string>
    <key>CFBundleDisplayName</key>       <string>JoyCoding</string>
    <key>CFBundleIdentifier</key>        <string>com.meiease.joycoding</string>
    <key>CFBundleExecutable</key>        <string>JoyCoding</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- 菜单栏 app, 不占 Dock -->
    <key>LSUIElement</key>               <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# macOS 的辅助功能授权是按【代码签名】记的。ad-hoc 签名没有稳定身份, 只能
# 靠 cdhash 认, 而每次重新编译 cdhash 都会变 —— 系统当成另一个 app, 授权就
# 失效了。用真证书签才有稳定的 designated requirement, 授权能跨重编译保留。
if [ -z "$JOYPAD_SIGN_ID" ]; then
  JOYPAD_SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | awk -F'"' '{print $2}')
fi
if [ -z "$JOYPAD_SIGN_ID" ]; then
  JOYPAD_SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Apple Development' | awk -F'"' '{print $2}')
fi

if [ -n "$JOYPAD_SIGN_ID" ]; then
  echo "▸ 签名: $JOYPAD_SIGN_ID"
  # --options runtime = hardened runtime, 公证的硬性要求。
  # 提前开着, 免得等到要分发时才发现它破坏了 HID 或事件合成。
  codesign --force --deep --options runtime --sign "$JOYPAD_SIGN_ID" "$APP"
else
  echo "▸ 签名: ad-hoc (⚠️ 每次重编译都要重新授权辅助功能)"
  codesign --force --deep --sign - "$APP"
fi

# 公证: 只有用 Developer ID 签名时才有意义。开发证书签的包公证会被拒,
# 所以按签名身份自动判断, 平时开发构建不会被拖慢。
if [[ "$JOYPAD_SIGN_ID" == "Developer ID Application"* && "$WANT_NOTARIZE" == 1 ]]; then
  if security find-generic-password -s "com.apple.gke.notary.tool" >/dev/null 2>&1 \
     || xcrun notarytool history --keychain-profile notary >/dev/null 2>&1; then
    ZIP="build/JoyCoding.zip"
    echo "▸ 打包送公证（要等 1-3 分钟）"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if xcrun notarytool submit "$ZIP" --keychain-profile notary --wait; then
      echo "▸ 钉票据（stapler）"
      # 把公证票据钉进 app, 这样对方【离线也能过 Gatekeeper】
      xcrun stapler staple "$APP"
      xcrun stapler validate "$APP"
      rm -f "$ZIP"
      # 重新打一个已钉票的分发包
      ditto -c -k --keepParent "$APP" "build/JoyCoding-notarized.zip"
      echo "✅ 可分发: build/JoyCoding-notarized.zip"

      # ── DMG ──────────────────────────────────────────────────────
      # ⚠️ DMG 要**自己再走一遍签名 + 公证 + 钉票**。app 里那张票据管不了外层
      # 镜像 —— 用户下载的是 DMG, Gatekeeper 检查的也是 DMG。少这一步, 打开时
      # 照样弹"无法验证开发者"。所以这里是第二次公证, 整体耗时大约翻倍。
      if [[ "$WANT_DMG" == 1 ]]; then
        DMG="build/JoyCoding-$VERSION-universal.dmg"
        echo "▸ 打 DMG"
        packaging/make-dmg.sh "$APP" "$DMG" "JoyCoding"
        echo "▸ 签名 DMG"
        codesign --force --sign "$JOYPAD_SIGN_ID" "$DMG"
        echo "▸ DMG 送公证（再等 1-3 分钟）"
        if xcrun notarytool submit "$DMG" --keychain-profile notary --wait; then
          xcrun stapler staple "$DMG"
          xcrun stapler validate "$DMG"
          echo "✅ 可分发: $DMG"
        else
          echo "⚠️ DMG 公证失败, 别拿这个分发。查原因:"
          echo "   xcrun notarytool log <submission-id> --keychain-profile notary"
        fi
      fi
    else
      echo "⚠️ 公证失败, app 仍可本机使用。查原因:"
      echo "   xcrun notarytool log <submission-id> --keychain-profile notary"
    fi
  else
    echo "⚠️ 没找到 notary 凭据, 跳过公证"
  fi
elif [[ "$WANT_DMG" == 1 ]]; then
  # --dmg 但没走公证分支(ad-hoc 签名, 或显式 --no-notarize): 照打, 但说清楚
  # 这个包只能自己用 —— 没公证的 DMG 在别人机器上会被 Gatekeeper 拦。
  DMG="build/JoyCoding-$VERSION-universal.dmg"
  echo "▸ 打 DMG（未公证, 仅供本机测试外观）"
  packaging/make-dmg.sh "$APP" "$DMG" "JoyCoding"
  echo "⚠️ $DMG 未经公证, 不要拿去分发"
fi

# 已经装过就顺手同步过去 —— 否则很容易出现"改了代码但跑的还是旧版本"
if [ -d /Applications/JoyCoding.app ]; then
  RUNNING=$(pgrep -x JoyCoding || true)
  [ -n "$RUNNING" ] && killall JoyCoding 2>/dev/null && sleep 1
  rm -rf /Applications/JoyCoding.app
  ditto "$APP" /Applications/JoyCoding.app
  echo "▸ 已同步到 /Applications"
  [ -n "$RUNNING" ] && open /Applications/JoyCoding.app
fi

echo "✅ $APP"
