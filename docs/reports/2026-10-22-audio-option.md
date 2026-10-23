# 音频转发：默认隔离与 `--audio` 可选开启

- 日期：2026-10-22

## 1. 结论

| 模式 | 实测结果 |
|---|---|
| **默认模式（不带 `--audio`）** | 服务端不启用音频采集、传输链路零音频字节；主控端音频设备表与系统默认输出在连接前后完全不变，结构性满足音频隔离 |
| **开启模式（`--audio`）** | 被控端播放 440 Hz 标准测试音，主控端接收并录制 11.88 s（2.28 MB），整段 RMS 为 −9.5 dBFS，频谱峰值准确落在 **440 Hz** |

## 2. 实现机制

- **协议包定义**：`PacketType.audio = 9`，载荷为固定格式的裸 PCM 数据（48 kHz、双声道、有符号 16-bit 交错格式，每帧 4 字节）；
- **服务端采集**：仅当指定 `--audio`（或被控端偏好 `server.audio = true`）时，才在 `SCStreamConfiguration` 中设置 `capturesAudio = true`（`sampleRate = 48000`、`channelCount = 2`、`excludesCurrentProcessAudio = true`），并通过 `AVAudioConverter` 将系统输出的浮点非交错缓冲统一转换为线上 `Int16` 交错格式；未开启时完全不注册音频回调；
- **客户端播放与录制**：使用 `AVAudioEngine` + `AVAudioPlayerNode` 播放至当前输出设备（限制最多 256 个在途缓冲防止积压，并监听 `AVAudioEngineConfigurationChange` 在切换耳机/扬声器时自动恢复播放），同时支持 `--audio-record <path>` 写入音频文件；
- **窗口统计**：每 60 秒输出一行 `audio.win frames=<N> rms=<dBFS> mbps=<M>`，会话结束时输出 `audio done` 汇总。

## 3. 实测数据

### 3.1 默认隔离验证（被控端持续放音，主控端不带 `--audio` 连接 65 秒）

```text
主控端音频设备列表与默认输出：无变化
客户端 audio 日志行数：0
received frames=3888 lastType=frame
服务端：stats captured=3895 encoded=3895 sent=3888 dropped=6 fps=60.0 bitrate=448.5Mbps（无 audio= 字段）
```

### 3.2 开启 `--audio` 转发验证

```text
audio source: 48000 Hz 2 ch interleaved=false float=true
audio.win frames=570240 rms=-9.5 dBFS mbps=1.52
audio done frames=570240 (11.9s) rms=-9.5 dBFS kb=2228
录制文件：2,285,056 B，格式：2 ch, 48000 Hz, Int16, interleaved
DFT 频谱校验：峰值频率 440 Hz（幅度 6029）
```

## 4. 已知限制

1. **仅采集系统输出音频**：ScreenCaptureKit `capturesAudio` 仅捕获应用播放的声音，不采集被控端麦克风输入；
2. **即时播放无 PTS 强对齐**：音频包到达后立即送入 `AVAudioPlayerNode` 队列，在雷雳网桥低延迟链路上与画面的偏差在数十毫秒内，未做复杂的音画同步缓冲。

## 5. 复现命令

```bash
# 1. 被控端开启音频启动服务
.build/release/boltkvm server --width 3840 --height 2160 --port 7474 --audio

# 2. 主控端接收并录制 12 秒音频（同时在被控端执行 afplay 播放声音）
.build/release/boltkvm client --host <被控端地址> --port 7474 --seconds 12 --audio --audio-record /tmp/audio.caf

# 3. 检查录制文件格式与时长
afinfo /tmp/audio.caf | grep -E "Data format|duration"
```
