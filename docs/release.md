# 发布流程

## 一句话

```bash
./build.sh --dmg
```

产出两个可分发文件（都已公证、已钉票）：

| 文件 | 给谁 |
|---|---|
| `build/JoyCoding-<版本>-universal.dmg` | 普通用户。README 主推这个 |
| `build/JoyCoding-notarized.zip` | 脚本化安装（`curl` + `ditto`）、CI、不想挂载磁盘映像的人 |

两个都传到 GitHub Releases。

## 为什么要 DMG

ZIP 的问题不在技术，在**默认行为**：Safari 下载后自动解压，`JoyCoding.app`
就落在「下载」文件夹里，很多人直接从那儿双击运行。后果是

- 「下载」被清理时 app 跟着没了
- **辅助功能授权是按路径记的**——之后再挪进「应用程序」还得重新授权一次

DMG 打开是一个窗口：左边 app、右边「应用程序」快捷方式、中间一个箭头。
把「拖进去」从一个需要用户自觉的额外步骤，变成默认路径。

## ⚠️ DMG 必须自己再公证一次

这是最容易漏的一步。流程是：

```
app 签名 → app 公证 → 票据钉进 app
   → 做 DMG（app 已带票）
   → **DMG 签名 → DMG 公证 → 票据钉进 DMG**
```

app 里那张票据**管不了外层镜像**。用户下载的是 DMG，Gatekeeper 检查的也是
DMG——少了后半段，打开时照样弹「无法验证开发者」。

所以 `--dmg` 会走**两次公证**，总时长约 3–6 分钟（不打 DMG 时是 1–3 分钟）。
这也是它做成开关而不是默认的原因：日常开发构建不该被拖慢。

## 开关

| 命令 | 行为 |
|---|---|
| `./build.sh` | 构建 + 签名 + 公证 app，出 zip。日常发布 |
| `./build.sh --dmg` | 上面 + 做 DMG + 公证 DMG。**正式发布用这个** |
| `./build.sh --no-notarize` | 只构建签名，不公证。日常开发 |
| `./build.sh --no-notarize --dmg` | 出一个**未公证**的 DMG，只用来本机看窗口外观 |

两个开关顺序随意。

## DMG 窗口是怎么摆的

`packaging/make-dmg.sh` 用系统自带的 `hdiutil`，**不依赖 `create-dmg`**——
那个要 `brew` 装，而这是公开仓库，别人 clone 下来应该直接能构建。

| 项 | 值 |
|---|---|
| 窗口内容区 | 600 × 400 |
| 图标大小 | 104 |
| app 图标 | (150, 196) |
| Applications 链接 | (450, 196) |
| 背景 | `.background/bg.tiff` |

改背景图要同时改 `packaging/dmg-background.png`（1x）和 `@2x`，
两张的尺寸必须是 600×400 / 1200×800，否则图标位置会对不上箭头。

### 高分屏

背景**打成多分辨率 TIFF**（`tiffutil -cathidpicheck`），不是靠 `bg@2x.png`
命名——Finder 对 DMG 背景不一定认 `@2x` 后缀，Retina 上会糊。
验证：`tiffutil -info` 应看到 72 和 144 两个 dpi。

### 窗口设置存在哪

存在卷根目录的 `.DS_Store` 里，由 AppleScript 驱动 Finder 写入。所以脚本里
那句 `sync; sleep 1` 不能删——Finder 是异步落盘的，卸载太快会把设置丢掉，
最终镜像打开就是默认的朴素窗口。

排查时可以直接查：

```bash
hdiutil attach build/JoyCoding-<版本>-universal.dmg -noautoopen
strings -a /Volumes/JoyCoding/.DS_Store | grep bg.tiff   # 应有输出
osascript -e 'tell application "Finder" to get bounds of window "JoyCoding"'
```

（AppleScript 读不回 `background picture` 属性是正常的，它对新版 `icvp`
格式支持不好，不代表背景没设上——以 `.DS_Store` 里的 `backgroundImageAlias`
为准。）

## 发布到 GitHub

```bash
gh release create v<版本> \
  build/JoyCoding-<版本>-universal.dmg \
  build/JoyCoding-notarized.zip \
  --title "JoyCoding <版本>" --notes "..."
```

⚠️ `mac/` 是**公开仓库**。DMG 背景图上的文字、发布说明里的内容都会公开可见，
发之前确认不含证书信息、内部计划、未发布的产品名。
