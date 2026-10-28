# 2026-10-28 代码审计与安全/音频修复

## 范围

本轮是 0.13 (237) 关窗静音与耳机切换实测通过后的只读代码复查；审计修复后的 build 243 已部署到 Pro / mini，覆盖音频生命周期、传输/认证、输入释放、剪切板文件接收、文档一致性。审计不包含长时间听音、真实网易云暂停或物理拔插的再次验证；没有产生可听声音。

## 已修复

| 问题 | 位置 | 修复 |
|---|---|---|
| 认证前按 20 字节头分配任意大 payload，单个连接可占满监听槽并申请数 GB | `Support.swift` `authenticateServer` | 认证前校验 `payloadLength <= TCPConnection.maxPayload`，超限直接 `EBADMSG` |
| 客户端可接受未认证的明文 `format`/`frame`，假服务器可骗取键鼠事件 | `SessionPump.swift`、`ClientSession.swift`、`CLI.swift` | 生产客户端启用 `requireAuthenticatedTransport`；只有 `authOk` 成功且双向会话密钥已安装后才处理格式、画面、音频、剪切板和文件包 |
| 服务端断线只释放修饰键，按住的字母/方向键会永久重复 | `Server.swift` | 记录所有注入的 keyDown，keyUp 移除；断线时释放修饰键与普通键的并集；断线后 `inject()` 直接忽略 |
| 服务端会话建立后把 socket 设回永久阻塞，读线程可能永不退出 | `Support.swift` | 握手/升级结束后统一恢复 `sessionRecvTimeout`（10 s） |
| 握手阶段用 1–2 s 超时读整帧，慢包留下半帧导致后续流错位 | `Support.swift`、`Protocol.swift` | `waitReadable` 只等首字节；首字节到达后用完整会话超时读整帧；读失败向上传播并结束会话，不再 `try?` 吞掉后继续 |
| 44.1 kHz 输出设备时 `AVAudioConverter.convert(to:from:)` 返回 -50，音频包被静默丢弃 | `Server.swift` `handleAudio` | 改用 block 形式 `convert(to:error:withInputFrom:)`，首次错误写日志 |
| 仅部分声道可写的设备静音到 0 后删除 marker，断线无法恢复 | `AudioOutputMute.swift` | 单个声道写入成功即视为已生效，保留 marker 与保存状态 |
| CLI `--audio-record` 仍声明“选中音频”并在收到首包时静音被控端 | `Protocol.swift`、`CLI.swift` | 新增 `AudioRequest.recordOnly = 3`：服务端采集发送，客户端只录制、不播放、不发送 `muteLocalOutput` |
| 旧 session 的延迟收尾可能 `finish()` 掉新 session 的播放器、取消新路由静音 | `ClientSession.swift` | 每轮收尾先检查 generation；关闭窗口时把 `AudioPlayer.finish()` 移到后台队列，避免阻塞主线程 |
| 关闭会话的 `stop()` 等待期间仍可能处理已缓冲的 `muteLocalOutput`，恢复后再次静音 | `Server.swift`、`CLI.swift` | 会话结束设 `clientAudioEnding`，忽略后续静音命令；CLI 先关闭 socket 再 `stop()`，先停读线程 |

## 验证

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

- release 构建通过；
- `swift test`：105 项通过、1 项跳过、0 失败；
- 新增 `test44kTo48kConversionProducesFrames`：44.1 kHz → 48 kHz 输出 1114 帧，`AVAudioConverter` 无错误；
- 新增 `testProductionPumpRejectsFrameBeforeAuthentication`：未认证明文 frame 返回 `EPROTO`；
- 新增 `AudioRequest.recordOnly` 的 byte 7 编解码断言；
- 0.13 (243) 本地回环短跑：认证/X25519 完成，`sent config 0x0 ... request=unselected`，服务端正常推流，客户端收到 100 帧；
- 0.13 (243) record-only 短跑（不播放、不发声）：`sent config 0x0 audio=int24 request=recordOnly`，服务端 `audio source ... target=int24` 并发送音频，客户端录制 960 帧；服务端日志没有 `muteLocalOutput` 或暂停命令；
- 0.13 (243) 本机 → mini 跨机短跑：认证/X25519 完成，收到 206 帧、0 解码失败；mini 与 Pro 均已安装 243，`/Applications` 无 `.bak` 残留；最终跨机短跑收到 119 帧、0 解码失败。

## 后续回归

审计把 44.1 kHz 转换改成 block API 时误用了 `.endOfStream`，导致 0.13 (243) 每个会话只产生第一个音频包、Pro 完全无声；0.13 (245) 已改为 `.noDataNow` 并加同一 converter 连续 5 个 buffer 的测试。详见 [音频转换器复用回归](2026-10-28-audio-converter-reuse.md)。

## 仍保留的边界

1. **authOk 的 flags 未做 HMAC**：中间人可清掉 `FLAG_SUPPORTS_KEY_EXCHANGE`，使会话退回仅 PSK 派生密钥。当前攻击者没有 PSK 仍无法解密或伪造加密帧；只有日后 PSK 泄露时才会失去前向保密。彻底修复需要给 authOk 增加覆盖 flags 的 MAC，涉及协议兼容，未在本轮改动。
2. **`mute-state.json` 是每用户单文件**：同一 Mac 上客户端路由静音与服务端本地静音同时存在时，可能互相覆盖恢复快照。需要进程级静音管理器或按实例拆分 marker；单机回环测试场景风险最高。
3. **客户端没有发送 `unmuteLocalOutput`**：正常关闭依赖服务端 `stop()` 的暂停+确认+恢复；若服务端读线程/进程异常，设备可能保持静音。重启 helper 时 `restoreStaleState()` 会在 owner pid 已死时恢复。
4. **未做真实播放器听感复测**：本轮只跑无输出设备/无音频的单元与短验证；网易云等第三方播放器是否响应 MediaRemote pause、44.1 kHz 路由下的实际听感、24-bit 听感仍需在物理设备上确认。
5. **24-bit 兼容**：新客户端只在新服务端声明 `FLAG_SUPPORTS_AUDIO_24` 时请求 int24；旧服务端自动回退 int16。

## 相关文档

- [音频会话：选中静音本地，换设备停两端](2026-10-28-audio-route-mute.md)
- [v0.13 记录](2026-10-28-v0.13-release.md)
- [发布流程](../releasing.md)
