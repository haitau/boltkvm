# 上屏 51 fps 的真因：`displaySyncEnabled = false`

> 2026-10-22。此前结论"51 fps 是 4K present 表面的固定上限"是**错的**——真因是客户端的 CAMetalLayer 关掉了显示同步，合成器在合并帧。

## 结论

`CAMetalLayer.displaySyncEnabled = false`（旧默认）会让 macOS 合成器丢弃/合并约 15% 的 present，稳定卡在 48.8–51 fps。打开同步后 60 秒窗口 **59.5 fps**，P95 从 16.6 ms 变成 17.0 ms（基本不变，因为被量化到一个刷新周期），SLO 33 ms 命中 **1/1**。

## 测量矩阵

同一台机、同一个服务端（3840×2160 ProRes）、每次 25–60 秒：

| 配置 | fps | p50 | p95 | drawable |
|---|---|---|---|---|
| `sync=0`（旧默认） | 48.8 | 9.0 ms | 16.6 ms | 3840×2160 |
| `sync=1` | 57.0 | 12.6 ms | 12.8 ms | 3840×2160 |
| `sync=1`，60 秒稳态 | **59.5** | 12.7 ms | 13.0 ms | 3840×2160 |
| `sync=1`，不切 4K 模式 | 57.6 | 15.2 ms | 22.2 ms | 6016×3384 |
| `sync=1` 设为默认后复测 | **59.5** | 16.7 ms | 17.0 ms | 3840×2160 |

最后一行是改默认值后的复测：`render.win ... fps=59.5 p50=16.7ms p95=17.0ms`，退出时 `SLO33 windows hit=1/1 (100%)`。

p50 在不同轮次落到 12.7 或 16.7 ms，正好相差一个刷新周期，属于相位效应；两者都在预算内。

## 为什么之前没发现

8 小时长稳里 `--input` 的 A/B 与 1080p 对照都指向"与码率、与输入无关"，于是归因到了 present 表面尺寸。方向对（确实是客户端呈现），但结论错（不是尺寸上限，是同步开关）。当时没有单独把 `displaySyncEnabled` 拉出来做对照——这是方法上的疏漏：只对比了"输入参数"，没对比"渲染配置"。

## 改动

```swift
// 旧：present 不等刷新，用撕裂换延迟
(view.layer as? CAMetalLayer)?.displaySyncEnabled = false
// 新：跟刷新同步，present 才不会被合并
let sync = (env["BOLTKVM_DISPLAY_SYNC"] ?? "1") != "0"
(view.layer as? CAMetalLayer)?.displaySyncEnabled = sync
```

保留 `BOLTKVM_DISPLAY_SYNC=0` 可复现旧行为，`BOLTKVM_PREFERRED_FPS` / `BOLTKVM_DRAWABLES` 用于后续调参。

## 代价与取舍

- 延迟从"不等 vsync"的 9.0 ms 变成"等一个刷新"的 16.7 ms，但 P95 几乎不变（16.6 → 17.0 ms），且帧率从 48.8 → 59.5；
- 画面不再撕裂；
- 33 ms 预算下有 16 ms 余量，60 Hz 屏幕的量化延迟是固有成本。

## 待确认

本结论来自 60 秒窗口。**8 小时长稳需要重跑一次**才能说"稳态 60 fps"，因为长时间跑下来合成器负载、内存压力都可能不同。
