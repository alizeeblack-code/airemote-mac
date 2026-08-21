图标是用 `gen.swift` 画的矢量，一次输出 10 个尺寸再打成 `.icns`。

改配色或形状后重新生成：

```bash
swiftc -O gen.swift -o gen && ./gen
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

`AppIcon.icns` 已提交，所以 clone 之后直接 `./build.sh` 就有图标，不需要先跑这一步。
