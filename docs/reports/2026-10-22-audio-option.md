# 音频：默认隔离，`--audio` 可选转发

> 2026-10-22。把"音频隔离"从一句承诺变成一个开关：默认关（结构性隔离），显式开启才传。

## 结论

| 场景 | 结果 |
|---|---|
| 默认（不带 `--audio`） | 服务端 `stats` 行**没有** `audio=` 字段，客户端日志零条 `audio.*`，主控端音频设备表与默认输出播放前后完全一致 → **隔离成立** |
| `--audio` 开启 | 被控端播放 8 s 440 Hz 测试音，客户端落盘 11.88 s / 2.28 MB，整段 RMS −9.5 dBFS，最响窗口 DFT 峰值 **440 Hz**（幅度 6029）→ **转发成立且频率无偏移** |

## 怎么实现的

- 协议新增 `PacketType.audio = 9`，负载是固定格式裸 PCM：48 kHz、2 ch、int16、交错，不带头（长度由 payload 推）。
- 服务端 `--audio` 才设 `config.capturesAudio = true`（并 `sampleRate = 48_000`、`channelCount = 2`、`excludesCurrentProcessAudio = true`），并注册 `.audio` 流输出；关闭时不注册、不采集、不发包。
- 采集到的缓冲格式由系统决定，服务端读 ASBD 后用 `AVAudioConverter` 统一转成线上格式，首次转换打印 `audio source: ...`。
- 客户端 `--audio` 播放（AVAudioEngine + AVAudioPlayerNode），`--audio-record <path>` 落盘（AVAudioFile），两者可同开。
- 每 60 s 打一行 `audio.win frames= rms=dBFS mbps=`，结束时 `audio done ...`。

默认关闭时，这条链路上不存在任何音频字节——不是"不播放"，而是根本不产生。

## 验证数据

**默认隔离**（被控端持续放音 8 s，主控端流式接收 65 s）：

```
设备列表与默认输出：无变化
audio 日志行数（应为 0）: 0
received frames=3888 lastType=frame
服务端：stats captured=3895 encoded=3895 sent=3888 dropped=6 fps=60.0 bitrate=448.5Mbps
        （行尾无 audio= 字段）
```

**`--audio` 转发**：

```
audio source: 48000 Hz 2 ch interleaved=false float=true     ← 系统给的是非交错 float32
audio.win frames=570240 rms=-9.5 dBFS mbps=1.52
audio done frames=570240 (11.9s) rms=-9.5 dBFS kb=2228
文件：2 285 056 B，Data format: 2 ch, 48000 Hz, Int16, interleaved
DFT：最响窗口（4.00 s）峰值 440 Hz，幅度 6029
```

## 已知限制

1. **没有音画同步**：音频包一到就入播放节点，相对视频有约 50–100 ms 偏差；需要同步时再引入 PTS 对齐。
2. **与视频共用同一条 TCP**：音频包可能排在视频帧后面，雷雳 1.5 Mbps 的音频流影响很小，但没有独立通道。
3. **播放音质未亲验**：可自动验证的是"有声音、频率对、电平对"，音色/爆音需要人耳听一次。
4. **只采系统输出，不采麦克风**：SCK 的 `capturesAudio` 抓的是应用播放的声音。

## 复现

```bash
# 被控端：开音频
echo "--audio" > ~/boltkvm-flags && kill $(cat /tmp/boltkvm-server.pid)   # 守护循环 3 s 内重启

# 主控端：录 12 s
boltkvm client --host <bridge-ip> --port 7474 --seconds 12 --audio-record /tmp/a.caf

# 被控端同时放测试音
afplay /tmp/tone.wav

# 校验
afinfo /tmp/a.caf | grep -E "Data format|duration"

# 恢复默认（隔离）
rm -f ~/boltkvm-flags && kill $(cat /tmp/boltkvm-server.pid)
```
