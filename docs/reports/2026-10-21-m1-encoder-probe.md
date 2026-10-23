# M1 编码可行性探针：6K 不可行，4K 可行

- 日期：2026-10-21
- 环境：无头 Mac mini（M4 Pro，macOS 27.0.1），虚拟显示器 `BoltKVM` `3008×1692 HiDPI @ 60Hz`（背板 `6016×3384`），雷雳网桥直连
- 目的：在构建完整管线前，验证 6K60 HEVC 低延迟硬件编码的可行性

## 1. 合成帧探针

工具：[`tools/vt-probe.swift`](../../tools/vt-probe.swift)。使用 `VTCompressionSession` + HEVC 硬件编码 + `EnableLowLatencyRateControl` 编码两组随机噪声帧（最坏情况压测），最多 4 帧在途。

| 分辨率 | 编码帧数 | 丢帧 | 活跃耗时 | 编码吞吐 | 码率 |
|---|---|---|---|---|---|
| 1920×1080 | 125 / 180 | 55 | 0.833s | **150.1 fps** | 508.7 Mbps |
| 3840×2160 | 59 / 180 | 121 | 1.201s | **49.1 fps** | 393.3 Mbps |
| 6016×3384 | 26 / 60 | 34 | 1.370s | **19.0 fps** | 511.9 Mbps |

结论【事实】：

- 探针按“尽快喂帧”模式运行，丢帧源于输入速率超出编码器容量后的主动丢弃，活跃吞吐反映编码器上限。
- 1080p 噪声可达 150fps，确认走硬件加速路径。
- 4K 噪声约 49fps，6K 噪声仅 19fps，说明 6K60 编码余量不足。

## 2. 真实桌面探针

工具：[`tools/capture-encode-probe.swift`](../../tools/capture-encode-probe.swift)。通过 ScreenCaptureKit 采集 `BoltKVM`，按目标尺寸缩放后送入 HEVC 编码，持续 15 秒。采集端从已获屏幕录制权限的 GUI 终端启动。

### 6K（6016×3384）

```text
captured=870 encoded=355 dropped=515 keyframes=6 bytes=4999337
elapsed=15.291s fps=23.2 bitrate=2.6 Mbps avgEncodeLatency=162.89ms max=191.95ms
```

### 4K（3840×2160，SCK 从 6K 缩放到 4K）

```text
captured=792 encoded=792 dropped=0 keyframes=14 bytes=4475582
elapsed=15.189s fps=52.1 bitrate=2.4 Mbps avgEncodeLatency=18.67ms max=69.38ms
```

## 3. 结论

**6K（β）不可行**【事实】：

- 真实桌面下 6K 编码平均延迟 **162.89ms**，吞吐仅 23fps，870 帧中丢弃 515 帧；
- 即使在静态桌面场景下，6K60 HEVC 低延迟编码也远达不到 60fps；
- “采集 6016×3384 → 传 6016×3384 → 客户端 1:1 渲染”的 β 路径在当前硬件编码器上不成立。

**4K（α′）可行**【事实】：

- 4K 下 0 丢帧，编码平均延迟 **18.67ms**，吞吐 52fps（接近桌面静态/轻度变化下的采集帧率）；
- 静态桌面码率仅 2.4Mbps，雷雳链路余量充足；
- 采集端将 6K 背板缩放到 4K，客户端全屏 1:1 上屏，即可保留 `3008×1692` 的 UI 布局与字体比例。

**决策**：M1 采用 **α′** 路径：ScreenCaptureKit 采集 6K 背板并硬件缩放到 4K，4K60 编码传输，客户端 4K 硬解 + Metal 1:1 渲染。

## 4. 尚未验证

- SCK 6K→4K 缩放与本地 WindowServer 6K→4K 缩放的画质差异（SSIM/PSNR）；
- 4K 动态内容下的码率上限与延迟；
- 客户端 4K 1× 模式切换的黑屏时间与恢复；
- 端到端 glass-to-glass 延迟；
- 4:2:0 与 4:4:4 对彩色文字边缘的影响。

## 5. 复跑

```bash
# 合成帧
xcrun swiftc -O -parse-as-library tools/vt-probe.swift -o /tmp/vt-probe
/tmp/vt-probe 3840 2160 180

# 真实桌面（需 GUI/Terminal 继承 TCC）
xcrun swiftc -O -parse-as-library tools/capture-encode-probe.swift -o /tmp/ce-probe
/tmp/ce-probe 3840 2160 15
```
