# GUI 客户端音频与 12 分钟稳定性（2026-10-23）

本轮要回答两件事：

1. **app 内音频**到底通没通（服务端 `--audio` + 客户端"音频"勾选）；
2. **app 模式连续跑 ≥10 分钟**会不会崩、会不会越跑越差（延迟漂移、内存泄漏、重连）。

## 环境

| 项 | 值 |
|---|---|
| 被控端 | Mac mini，`boltkvm-server server --width 6016 --height 3384 --port 7474 --virtual-display builtin --virtual-display-size 3008x1692 --audio` |
| 主控端 | MacBook Pro，`dist/BoltKVM.app`（`5dd66ff` + 音频修复），窗口 1200×727、内容 1200×675（16:9） |
| 网络 | 雷雳桥 `<mini 桥接地址>:7474` |
| 画面负载 | mini 侧 `inputprobe --seconds 900 --interval-ms 16`（持续改鼠标位置） |
| 声音负载 | mini 侧循环 `afplay /System/Library/Sounds/Glass.aiff`，间隔 4 s |
| 窗口状态 | 大部分时间被终端遮挡（前台约 25 fps，见下） |

## 1. 音频：先修了一个"永远收不到"的 bug

`ClientSession` 的 `switch` 里，`.audio` 被写进了"客户端永远收不到这些类型"的那个
分支，后面真正处理音频的 `case .audio:` 成了死代码——编译器只给重复 case 的警告，
不报错。表现就是服务端在发、客户端永远 `frames=0`。

| 阶段 | 服务端 `stats` | 客户端 `audio.win` |
|---|---|---|
| 修前 | `audio=3482 pkts/1.5Mbps` | `frames=0 rms=-120.0 dBFS mbps=0.00` |
| 修后 | `audio=3482 pkts/1.5Mbps` | `frames=2871360 rms=-34.6 dBFS mbps=1.53` |

修后 12 分钟里每个 60 s 窗口都有音频，能量集中在 −34.0 ~ −34.6 dBFS、码率恒定
1.54 Mbps：

```
-34.0 dBFS 1.54 Mbps
-34.1 dBFS 1.54 Mbps   ×3
-34.3 dBFS 1.54 Mbps
-34.4 dBFS 1.54 Mbps   ×2
-34.6 dBFS 1.54 Mbps   ×6
```

播放 `Glass.aiff` 时 −34 dBFS、静音时 −120 dBFS，能量对得上，说明 PCM 是真实声音
而不是填充的零。

**未验证**：人耳听感（没法自动判断"是否悦耳/是否有爆音"）、切换输出设备、
音画同步偏差（没有同时录屏录音的采样设备）。

## 2. 12 分钟 GUI 稳定性

会话从 `10:11:57` 开始（日志里插了 `=== stab-start` 标记），连续 13 个 60 s 窗口，
没有一次断连、没有重连、没有崩溃。

| 窗口 | fps | p50 | p95 | max |
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

- **帧率**：25.3–26.6 fps，波动 <5%。这个数是"窗口被遮挡"下的上限（前台那次
  55.1 fps，见 B5 报告），不是衰减；
- **延迟**：p50 从 43.4 ms 缓慢爬到 45.0 ms（12 分钟 +1.6 ms），p95 45.0→46.2 ms。
  有轻微上漂但没失控，和 B5 里"无音频时 p50 39–40 ms"相比整体高约 4 ms——
  这一轮开着音频解码 + 播放，最可能就是那 4 ms 的来源；
- **内存**：RSS 134 MB → 129 MB → 135 MB，12 分钟基本持平，没有泄漏迹象；
- **错误**：整个日志只有一条 IMK 的无关警告
  （`error messaging the mach port for IMKCFRunLoopWakeUpReliable`），没有
  `session ended` / 重连 / 解码失败；
- **服务端**：mini 侧全程 `fps≈31`、`dropped=0`，音频 1.5 Mbps 持续；
- **SLO 33 ms 命中率**：13 个窗口全部 p95 > 33 ms（45.0–46.2 ms），**0/13**。
  这是"开音频 + 窗口被遮挡"的组合，和 B5 里不带音频的 40–42 ms 相比没有改善——
  33 ms 这个目标在 GUI 呈现路径上仍然不成立（见 B7）。

## 结论

| 项 | 结果 |
|---|---|
| app 内音频 | **通**（1.54 Mbps、−34 dBFS、13/13 窗口连续），人耳听感未验证 |
| app 模式 10 分钟+ 稳定性 | **通过**：13 窗口无断连无崩溃，RSS 持平，延迟 +1.6 ms 轻微上漂 |
| 音频的延迟代价 | p50 从 39–40 ms 升到 44 ms，约 +4 ms（同一台 mini、同一条桥） |
| R3 记住登录密码 | 阻塞已写清（见设计文档 §R3），本轮不做 |

## 复现

```bash
# mini：开音频的服务端（由 app 拉起时等价于 defaults write io.github.boltkvm server.audio -bool true）
ssh mini 'pkill -f "BoltKVM.app/Contents/MacOS/BoltKVM"; open -a /Applications/BoltKVM.app'
ssh mini '/Applications/BoltKVM.app/Contents/MacOS/boltkvm-server inputprobe --seconds 900 --interval-ms 16 &'
ssh mini 'for i in $(seq 1 200); do afplay /System/Library/Sounds/Glass.aiff; sleep 4; done &'

# 本机：连接后在日志里看窗口
grep -E "render.win|audio.win" ~/Library/Logs/BoltKVM.log | tail -30
```

## 未验证

- 人耳听感、不同输出设备、音画同步；
- 前台连续 10 分钟（本轮大部分时间窗口被遮挡，前台只跑了 1 个窗口 55.1 fps）；
- 音频在 1.5 Mbps 之外的码率（当前只有一种 `Glass.aiff`）；
- 长于 12 分钟的漂移趋势（p50 缓慢 +1.6 ms 是否收敛未知）。
