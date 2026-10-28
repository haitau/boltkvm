# mini 本地被莫名静音：默认不再设备静音，改为暂停媒体（2026-10-28）

## 现象

用户反馈控制 mini 时，mini 本机会“经常不知道怎么回事就静音”，应用仍在运行；如果是暂停网易云音乐一类的播放器可以理解，但设备被静音（应用没停）不能接受。

## 事实

- 部署前 mini 为 0.12.2 (212)，系统 `output muted:true`、`output volume:13`；
- `~/Library/Application Support/BoltKVM/mute-state.json` 存在，内容为：
  `{"uid":"BuiltInHeadphoneOutputDevice","mute":0,"pid":18019,"usedMute":true,"volume":0.125}`
- 旧 helper 18019 仍存活，marker 的 pid 属于它，因此它一直保持着设备静音；
- 旧版 A-1 在 `--audio` 采集启动后默认调用 `AudioOutputMute`，优先写 `kAudioDevicePropertyMute=1`，设备不支持才退回音量 0。

这是 A-1 的设计行为，不是随机故障；但“静音设备而不是暂停播放器”与用户预期冲突。

## 改动

- `Server.init` 的 `muteLocalOutput` 默认从 `true` 改为 `false`。
- CLI 只有显式 `--local-mute` 才设备静音；`--no-local-mute` 仍接受但不再改变默认值。
- 音频采集启动成功后调用 `performRemoteAction(.pauseMedia)`，用 MediaRemote 暂停当前 Now Playing 应用；日志为 `media: paused the current Now Playing app`。
- 客户端断开后媒体保持暂停，不自动恢复；避免把用户后来手动播放的内容再切掉。
- 旧版残留 marker 的恢复逻辑保持不变：新 helper 启动时若 marker 的 pid 已死，先恢复原静音/音量并删除 marker。
- 文档同步：README / README_EN 的音频隔离、CLI 和排障说明改为“暂停媒体，不静音设备”。

## 验证

mini 已部署 0.12.2 (214)，部署脚本确认签名身份未变、保留 TCC 授权：

```text
签名身份未变，保留现有 TCC 授权。
virtual display: id=351 logical=3008x1692 backing=6016x3384 hiDPI=true
listening on bridge0 <bridge-ip>:7474 ...
client connected
audio source: 48000 Hz 2 ch ...
capture started; waiting for frames
media: paused the current Now Playing app
```

部署后：

```text
VER=214
output volume:13, input volume:81, alert volume:100, output muted:false
no-marker
```

即：设备已解除静音、marker 已删除、播放器被暂停；日志中没有 `audio: muted local output`。本机 `swift build -c release` 通过。

## 未验证 / 边界

- 只验证了本机与 mini 这一对机器；未验证所有第三方播放器是否都响应 MediaRemote（不响应的播放器可能继续出声，但不会再静音设备）。
- 暂停只在音频采集启动时触发一次；会话中用户重新播放不会被自动暂停，也不做持续监听。
- 显式 `--local-mute` 的崩溃恢复路径沿用旧实现，未重新做 `kill -9` 长跑；旧 marker 的恢复属于恢复原状态，不会主动新增静音。
