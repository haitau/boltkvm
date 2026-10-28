# 音频会话：选中静音本地，换设备停两端

日期：2026-10-28
状态：代码已改，构建与无音频单测通过；**未做实际发声/耳机切换验收**（用户要求在办公时间不要出声）。

## 背景

旧逻辑把“选中音频”和“换输出设备”都实现成向被控端发 `pauseMedia`，但转发的音频源正是被控端的 Now Playing 应用。暂停源之后，主控端必然没有声音可转发；再叠加自动重连、CoreAudio 多通知和 `AVAudioEngine` 重建，就会出现“mini 响 → Pro 响 → 突然没声音”。

## 新语义

### 选中音频

1. 客户端收到第一帧视频格式后发 `muteLocalOutput`；
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
- `swift test --filter ProtocolTests`：11 项通过；
- `swift test --skip Audio`：90 项通过，未运行会出声的音频回归；
- **未验证**：真实耳机切换听感、Pro 系统其他 App 的 2.5 s 静音与恢复、mini 的 `AudioOutputMute` 恢复、蓝牙多通知、24-bit 格式。

## 边界

- 48 kHz / 16-bit / 双声道仍为当前线格式，约 1.54 Mbps；48 kHz 本身是 CD 级，升级优先做 24-bit，96 kHz 仅作可选；需要协议格式协商，本次未做。
- Pro 系统静音是**路由过渡期** 2.5 s，不是永久静音；若要求永久停到手动恢复，需要显式恢复入口。
- mini 226 及更早版本没有 `muteLocalOutput` 处理；客户端 227 连接旧 mini 时静音命令会被忽略，需要同步升级 mini 后才能验收。
- 首次选中音频时若服务端静音失败，会记录 `audio: could not mute local output`，此时仍可能有双端声音；需要后续加能力确认/降级策略。
