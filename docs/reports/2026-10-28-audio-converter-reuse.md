# 音频转换器复用回归：每会话只剩第一个音频包

日期：2026-10-28
状态：已修复并部署 0.13 (245)；无音频/record-only 验证通过；**用户于 2026-10-28 复测“没什么问题”**（未做自动化可听测试）。随 v0.13 发布。

## 现象

0.13 (243) 上 Pro 已连接 mini、视频正常、config 明确声明 `audio=int24 request=selected`，但 Pro 有线耳机完全无声。

- Pro 日志：`audio: playing to 外置耳机 ... volume=0.09 mute=0`，随后 `audio.win frames=960 rms=-120.0 dBFS`，整个会话只收到 960 帧（1 秒静音）；
- mini 日志：`audio source: 48000 Hz 2 ch ... target=int24`，但统计长时间停在 `audio=1 pkts/0.0Mbps`；
- 0.13 (237) 的旧会话同一路径为 `audio=182 pkts/2.3Mbps`，客户端 RMS 约 -14 dBFS，说明采集源和路由本身正常。

## 根因

审计时为修复 44.1 kHz→48 kHz 的 `-50` 错误，把 `AVAudioConverter` 的输入 block 改为：

```swift
if supplied {
    status.pointee = .endOfStream
    return nil
}
supplied = true
status.pointee = .haveData
return inBuf
```

`.endOfStream` 表示“这个转换器以后不会再有输入”，因此第一个 ScreenCaptureKit buffer 之后，转换器永久结束；后续 buffer 仍到达，但 `convert` 不再产出帧，服务端音频计数停在 1。

## 修复

第二个及后续输入回调改为 `.noDataNow`：只表示“当前没有更多输入”，转换器仍可复用。见 `Sources/BoltKVMCore/Server.swift`。

测试 `Audio24Tests.test44kTo48kConversionProducesFrames` 改为在**同一个 converter** 上连续转换 5 个 buffer，每一轮都必须 `frameLength > 0`；旧的 `.endOfStream` 实现会在第 2 轮开始失败。

## 验证

- `swift test`：105 项通过、1 项跳过；
- 0.13 (245) record-only 5 秒短跑（不播放）：客户端收到 **225,600 帧 / 4.7 s**，服务端 `audio=182 pkts/2.3Mbps`；音频包不再停在 1；
- Pro / mini 均已安装 245；
- **用户复测**：2026-10-28 在 245 上连接 mini、播放网易云，反馈“没什么问题”；没有做自动化可听测试或 24-bit 专门听感记录。

## 边界

- record-only 短跑的 RMS 为 -120 dBFS，是因为 mini 当时没有播放媒体，不是链路静音；包数、帧数和码率均已恢复；
- 44.1 kHz 源只做了单元测试的重复转换，没有在 44.1 kHz 物理输出设备上做可听复测。
