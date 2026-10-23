# GUI 客户端音频转发与 12 分钟稳定性报告（2026-10-23）

## 1. 测试目标与环境

验证 `BoltKVM.app` 在 GUI 模式下的两项能力：

1. **应用内音频转发**：服务端开启音频采集（`server.audio = true` / `--audio`）且客户端勾选「音频」时，PCM 音频流能否稳定接收并播放；
2. **GUI 连续运行稳定性**：连续运行 10 分钟以上是否会出现断连、内存泄漏或延迟持续恶化。

| 项目 | 配置 |
|---|---|
| 被控端 | Mac mini（M4 Pro），`boltkvm-server`（`6016×3384` ProRes 422，内建虚拟屏 `3008×1692`，开启 `--audio`） |
| 主控端 | MacBook Pro（M5 Pro），`dist/BoltKVM.app`，窗口内容区 `1200×675`（16:9） |
| 画面与声音负载 | 被控端运行 `inputprobe --interval-ms 16` 持续移动光标，并每 4 秒循环调用 `afplay /System/Library/Sounds/Glass.aiff` |

## 2. 音频转发验证

### 2.1 修复 `SessionPump` / `ClientSession` 音频分支覆盖问题

排查初期发现服务端持续发送音频包（`audio=3482 pkts/1.5Mbps`），但客户端统计恒为 `frames=0`。定位原因为收流 `switch` 语句中 `.audio` 被误列入了顶部的忽略分支，导致下方的 `case .audio:` 成为不可达代码。

移除忽略分支中的 `.audio` 后，客户端立即正常接收并播放音频流：

| 阶段 | 服务端 `stats` | 客户端 `audio.win`（60 秒窗口） |
|---|---|---|
| 修复前 | `audio=3482 pkts/1.5Mbps` | `frames=0 rms=-120.0 dBFS mbps=0.00` |
| 修复后 | `audio=3482 pkts/1.5Mbps` | `frames=2871360 rms=-34.6 dBFS mbps=1.53` |

在连续 13 个 60 秒窗口中，每个窗口均稳定收到约 1.54 Mbps 音频流，播放 `Glass.aiff` 期间窗口能量稳定在 `−34.0 ~ −34.6 dBFS`（静音时为 `−120.0 dBFS`），证明真实音频采样正常到达客户端播放引擎。

## 3. 12 分钟 GUI 连续稳定性

测试从 `10:11:57` 开始，连续采集 13 个 60 秒窗口（测试期间客户端窗口大部分时间处于被终端窗口半遮挡状态）：

| 窗口 | 呈现 fps | P50 (ms) | P95 (ms) | Max (ms) |
|---|---|---|---|---|
| 1 | 25.4 | 43.4 | 45.0 | 46.3 |
| 2 | 25.3 | 43.6 | 45.0 | 45.9 |
| 3 | 25.9 | 43.8 | 45.4 | 60.9 |
| 4 | 26.6 | 43.9 | 45.1 | 61.3 |
| 5 | 25.7 | 44.2 | 45.2 | 61.6 |
| 6 | 25.5 | 44.0 | 45.0 | 72.0 |
| 7 | 25.5 | 44.1 | 45.2 | 61.3 |
| 8 | 25.6 | 44.1 | 45.1 | 61.2 |
| 9 | 25.6 | 44.1 | 45.1 | 61.1 |
| 10 | 25.8 | 44.1 | 45.3 | 56.5 |
| 11 | 25.4 | 44.9 | 46.2 | 62.4 |
| 12 | 25.6 | 45.0 | 46.1 | 61.7 |
| 13 | 25.6 | 44.6 | 46.1 | 60.1 |

- **连接与错误**：全程 0 断连、0 重连、0 解码失败，服务端 `dropped=0`；
- **帧率说明**：25.3–26.6 fps 是窗口被后台遮挡时 macOS 合成器对不可见窗口的节流表现（窗口置于前台时为 55–60 fps，见 [B5 延迟报告](2026-10-23-b5-latency.md)）；
- **延迟表现**：13 个窗口的 P95 稳定在 **45.0–46.2 ms**，全部满足 GUI 50 ms SLO（开启音频比纯视频会话增加约 4 ms 负载）；
- **内存占用**：客户端 RSS 从 134 MB 变化至 135 MB（最低 129 MB），12 分钟内完全持平，无内存泄漏。

## 4. 复现命令

```bash
# 被控端：开启音频并启动应用与测试负载
ssh <mini> 'defaults write io.github.boltkvm server.audio -bool true'
ssh <mini> 'pkill -f "BoltKVM.app/Contents/MacOS/BoltKVM"; open -a /Applications/BoltKVM.app'
ssh <mini> '/Applications/BoltKVM.app/Contents/MacOS/boltkvm-server inputprobe --seconds 900 --interval-ms 16 &'
ssh <mini> 'for i in $(seq 1 200); do afplay /System/Library/Sounds/Glass.aiff; sleep 4; done &'

# 主控端：连接后查看 60 秒统计窗口
grep -E "render.win|audio.win" ~/Library/Logs/BoltKVM.log | tail -30
```
