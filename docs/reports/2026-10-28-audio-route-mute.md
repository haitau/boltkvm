# 音频会话：选中静音本地，换设备停两端

日期：2026-10-28
状态：代码已改，构建与无音频单测通过；**未做实际发声/耳机切换验收**（用户要求在办公时间不要出声）。0.13 已追加 24-bit/48 kHz 协商，并用 record-only 会话验证端到端格式。

## 背景

旧逻辑把“选中音频”和“换输出设备”都实现成向被控端发 `pauseMedia`，但转发的音频源正是被控端的 Now Playing 应用。暂停源之后，主控端必然没有声音可转发；再叠加自动重连、CoreAudio 多通知和 `AVAudioEngine` 重建，就会出现“mini 响 → Pro 响 → 突然没声音”。

## 新语义

### 选中音频

1. 客户端收到第一个音频包后发 `muteLocalOutput`；
2. 服务端用 `AudioOutputMute` 静音被控端默认输出，但**不暂停 Now Playing**；
3. ScreenCaptureKit 在设备静音之前取音，Pro 继续收到完整音频；
4. 未选音频的会话不发任何音频命令，不受重连影响；服务端是否采集由 `--audio` 决定，但客户端不会播放，也不会影响被控端播放。

### 主控端换输出设备

1. `AudioPlayer` 立即 suspend：停止旧 graph、清空队列、generation++；
2. `AudioOutputMute` 静音主控端整机默认输出（不是只停 BoltKVM 播放器）；
3. 0.5 s 防抖后向被控端发一次 `pauseMedia`，2 s 冷却；
4. CoreAudio 的多次通知用 `rebuildToken` 合并，稳定 0.6 s 后只重建一次；
5. 2.5 s 后恢复主控端系统输出；
6. 被控端媒体保持暂停，不自动恢复。

### 音量键

选中音频播放时，音量加/减/静音键不再转发给被控端，而是交给主控端本地处理；未选音频的会话保持原来的远程音量控制。这样调本地耳机音量不会再把 mini 的音量 HUD 打得忽大忽小。

阈值/按键码：macOS 虚拟键码 `0x48`/`0x49`/`0x4A`。这里只处理 `keyDown`/`keyUp`；若系统把这些键作为 `systemDefined` 事件投递，则不会经过转发路径，也就不会影响远端。

### 断开

- 服务端 `stop()` 恢复 `AudioOutputMute` 保存的静音/音量状态；
- 客户端结束 route mute 并关闭播放器；
- 不自动恢复被控端媒体。

## 实现位置

- `Sources/BoltKVMCore/Protocol.swift`：新增 `muteLocalOutput = 8`、`unmuteLocalOutput = 9`；
- `Sources/BoltKVMCore/Server.swift`：客户端选中音频时启动 `AudioOutputMute`，停止/断开时恢复；
- `Sources/BoltKVMCore/App/ClientSession.swift`：首次选音频发 mute、换设备静音 Pro 系统输出、暂停命令冷却；
- `Sources/BoltKVMCore/Audio.swift`：路由信号立即 suspend、路由重建合并；
- `Sources/BoltKVMCore/CLI.swift`：CLI 音频会话同步改为 mute，不再首次 pause。

## 验证

- `swift build -c release`：通过；
- `swift test --filter ProtocolTests`：14 项通过；
- `swift test --filter Audio24Tests`：3 项通过（含静音播放图和 float32 记录文件）；
- `swift test`：99 项通过、1 项跳过（`AudioRouteChangeTests` 需要显式音频输出环境）；
- 0.13 record-only 端到端：客户端 `sent config 0x0 audio=int24`，服务端 `audio source ... target=int24`，统计 `audio=182 pkts/2.3Mbps`，客户端记录 178,560 帧 / 3.72 s（文件为 float32 诊断容器）；
- **未验证**：真实耳机切换听感、Pro 系统其他 App 的 2.5 s 静音与恢复、mini 的 `AudioOutputMute` 恢复、蓝牙多通知、音量键的实际事件类型（本地/远端）、24-bit 的实际听感（只验证了格式、帧数、码率与无声播放图）。

## 24-bit/48 kHz（0.13 追加）

认证时服务端在 `authOk` 追加能力位 `FLAG_SUPPORTS_AUDIO_24`；客户端看到后把 `SessionConfig` 的保留字节 6 设为 `AudioWireFormat.int24`。服务端在开始采集前读取该 config，用 `AVAudioConverter` 转到 int32，再取高 24 位按 3 字节小端打包；客户端按 3 字节解包并左移 8 位，再归一化到 float32 交给混音器。旧客户端不读能力位、旧服务端不读字节 6，双方自动保持 int16；`0x0` 尺寸的 config 只用于音频协商，服务端会保留当前显示尺寸，不会重建虚拟屏。

24-bit 线格式为 48 kHz / 2 ch / 3 bytes/sample = 6 bytes/frame，约 2.30 Mbps。客户端没有把 int32 直接接到 `AVAudioEngine`：实测该连接在当前 macOS 返回 `-10868 FormatNotSupported`，因此播放和 `--audio-record` 都使用 float32 缓冲；float32 的尾数足以无损容纳 24-bit 样本，记录文件本身是 32-bit float 诊断容器，不是 packed 24-bit 文件。

## 边界

- 当前线格式为 48 kHz / 双声道，协商 int16（约 1.54 Mbps）或 packed int24（约 2.30 Mbps）；96 kHz 未实现。
- Pro 系统静音是**路由过渡期** 2.5 s，不是永久静音；若要求永久停到手动恢复，需要显式恢复入口。
- 0.12.1 及更早版本没有 `muteLocalOutput` 处理；连接旧 mini 时静音命令会被忽略，需要两端同步升级后才能验收。本次 Pro/mini 都已部署 0.13。
- 首次选中音频时若服务端静音失败，会记录 `audio: could not mute local output`，此时仍可能有双端声音；需要后续加能力确认/降级策略。
