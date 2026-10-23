# 呈现帧率 51 fps 根因定位与修复：`displaySyncEnabled`

- 日期：2026-10-22

## 1. 结论

此前在 8 小时长稳测试中观察到客户端呈现帧率稳定在 48.8–51.0 fps（服务端编码与客户端解码均为 59.9 fps）。经对照排查，根因是客户端将 `CAMetalLayer.displaySyncEnabled` 设为了 `false`，导致 macOS 窗口合成器合并了约 15% 的提交帧。

将 `displaySyncEnabled` 恢复为开启（默认 `true`）后，60 秒稳态窗口呈现帧率立即升至 **59.5 fps**，P95 延迟为 **17.0 ms**（4K 1× 模式）。

## 2. 对照实测数据

在同一台主控端、同一台 3840×2160 ProRes 服务端下进行 25–60 秒对照测试：

| 配置 | 呈现 fps | P50 | P95 | Drawable 尺寸 |
|---|---|---|---|---|
| `displaySync=0`（旧设置） | 48.8 | 9.0 ms | 16.6 ms | 3840×2160 |
| `displaySync=1`（短跑） | 57.0 | 12.6 ms | 12.8 ms | 3840×2160 |
| `displaySync=1`（60 秒稳态） | **59.5** | 12.7 ms | 13.0 ms | 3840×2160 |
| `displaySync=1`（不切 4K 模式） | 57.6 | 15.2 ms | 22.2 ms | 6016×3384 |
| `displaySync=1` 设为默认后复测 | **59.5** | 16.7 ms | 17.0 ms | 3840×2160 |

不同轮次中 P50 在 12.7 ms 与 16.7 ms 之间切换，对应 60Hz 显示器刷新周期的相位量化，P95 稳定在 13–17 ms。

## 3. 代码修改

在 `Sources/BoltKVMCore/Renderer.swift` 中默认开启垂直同步，并保留环境变量开关供对照实验使用：

```swift
let sync = (env["BOLTKVM_DISPLAY_SYNC"] ?? "1") != "0"
(view.layer as? CAMetalLayer)?.displaySyncEnabled = sync
```

同时支持通过 `BOLTKVM_PREFERRED_FPS` 与 `BOLTKVM_DRAWABLES` 调整目标帧率与可绘制缓冲数量。
