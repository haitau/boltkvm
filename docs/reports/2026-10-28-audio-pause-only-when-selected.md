# 只有主控端选择音频时才暂停被控端播放器（2026-10-28）

## 现象

重新连接 mini 后，mini 上正在播放的 Now Playing 应用被暂停，但主控端这次连接并没有为该主机选择音频。用户要求：**主控端没选音频时，不得影响被控端音频；只有选择了音频，设备变更等操作才允许暂停被控端播放。**

## 根因

服务端以 `--audio` 启动（`server.audio=true`）后会采集系统音频；`Server.start()` 在采集启动成功后无条件调用 `performRemoteAction(.pauseMedia)`。这个行为与“客户端是否选择音频”无关，所以仅仅重新连接、即使客户端 `playAudio=false`，mini 的播放器也会被暂停。

同时，客户端原来在认证刚完成时发送首次 `pauseMedia`，可能早于服务端命令读取循环启动，命令会丢失；这解释了此前“文档说会暂停，但日志有时没有”的不确定现象。

## 修改

- **服务端不再在采集启动时暂停任何播放器。** `--audio` 只负责采集/发送音频，不改变 Now Playing 状态；`--local-mute` 仍是显式 opt-in 的设备静音。
- **选择音频的客户端在收到第一帧格式后发送一次 `pauseMedia`。** 此时服务端命令 pump 已就绪；`playAudio=false` 时不会创建音频播放器，也不会发送这条命令，重新连接不会影响 mini。
- 输出设备变化（蓝牙耳机开关、有线耳机插拔）仍只在主控端实际播放转发音频时发送 `pauseMedia`。
- CLI 客户端与 GUI 客户端采用同一语义：`--audio` 连接后收到格式再发送首次暂停；未启用音频不发送。

## 验证

- mini 已部署 219；服务端日志中有 `audio source: 48000 Hz ...` 和 `capture started`，说明 `--audio` 采集仍在运行。
- **未选择音频**（`hosts.json` 中 `"audio": false`）重新连接：mini 最新会话只有
  `capture started` / `audio source` / `stats ... audio=...`，**没有** `command: pauseMedia`，也**没有** `media: paused the current Now Playing app`；主控端日志也没有 `audio: asked server to pause media`。
- **临时选择音频**（同一 host 条目改为 `"audio": true`，测完已恢复 false）：主控端日志出现
  `audio: asked server to pause media (client audio enabled)`；mini 日志出现
  `command: pauseMedia` 与 `media: paused the current Now Playing app`，证明选中音频时暂停路径仍有效。
- `swift test`：92 项通过，1 项跳过；`swift build -c release` 通过。

## 未验证

- 没有实际播放网易云音乐来观察暂停后的 UI；只核对了客户端发送与服务端 MediaRemote 返回成功的日志。
- CLI `--audio` 的首次暂停路径只做了代码对齐，未单独跑客户端 CLI。
- 输出设备变化时的防抖/多条通知去重仍沿用 A-2 的既有结论，本次未重新实机切换蓝牙。
