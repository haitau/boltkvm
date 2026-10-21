# M3 稳定性加固报告

- 日期：2026-10-21
- 目标：虚拟显示看门狗、TCC 权限自检、服务端/客户端断线重连、心跳、延迟预算告警，并准备 8 小时长稳。
- 结论：**加固机制已落地并完成短测**；8 小时连续运行尚未执行（需要夜间无人占用窗口）。

## 1. TCC 权限医生

新增 `boltkvm doctor --role server|client`：

```text
$ boltkvm doctor --role server
PASS Screen Recording (CGPreflightScreenCaptureAccess)
PASS Input Monitoring / listen events (CGPreflightListenEventAccess)
PASS Accessibility / post events (CGPreflightPostEventAccess)
PASS Accessibility trust (AXIsProcessTrusted)
```

- 服务端启动时自动检查 Screen Recording；缺失时直接报错并给出授权路径，不再静默落到 `SCStreamError -3801`。
- 客户端 `--input` 启动 tap 前检查 Input Monitoring。
- macOS 升级后可先跑 doctor，避免“画面/输入一半失效”的隐性故障。

## 2. 虚拟显示看门狗

新增 `boltkvm watchdog`，并已安装为 mini 的 LaunchAgent：

```text
~/Library/LaunchAgents/com.boltkvm.watchdog.plist
Label: com.boltkvm.watchdog
Program: ~/boltkvm watchdog --interval 5
RunAtLoad / KeepAlive: true
```

行为：

- 每 5 秒检查是否存在 `6016×3384` 的活动显示；
- 连续 2 次缺失时执行 `vdscreen on 3008x1692`，写日志并发通知；
- 不依赖 TCC；不常驻终端窗口。

实测：

```text
vdscreen off          → 显示消失
等待 16s              → watchdog 自动执行 vdscreen on
vdscreen state        → on BoltKVM 3008x1692
显示器                → BoltKVM 6016×3384 / 3008×1692 HiDPI
```

`watchdog --once` 也可用于手动体检；`--uninstall` 可移除 LaunchAgent。

## 3. 服务端重连

`boltkvm server --seconds 0` 现在是常驻接受循环：

1. 等待客户端；
2. 每个连接创建独立的 SCK 采集 + 编码会话；
3. 客户端断开后停止采集/编码、关闭连接，回到 accept；
4. 下一个客户端重新建立完整会话。

实测两个连续客户端：

```text
client1: decode 60.7fps failed=0
server:  session ended; accepting next client
client2: decode 60.6fps failed=0
server:  client connected; stats 60.0fps dropped=0
```

单输入源拓扑保持不变：同一时刻只服务一个客户端。

## 4. 客户端重连

新增 `--reconnect`：

- 连接断开后每秒重试，直到 `--seconds` 总时长结束；
- 重连后新建 decoder、重新协商时钟、重新安装输入 tap；
- 窗口、Metal 渲染器与 4K 1× 模式保持不变。

实测：运行中杀掉 server，再重启：

```text
client render error: Connection reset by peer
client render error: Connection refused  (×5)
connected to <mini>:7474
decoder ready 3840x2160 codec=prores422
```

客户端自动恢复，无需重启 app。

## 5. 心跳与静态桌面

M3 测试发现：桌面内容完全静止时，ScreenCaptureKit 可能停止产出新帧；客户端 5 秒 socket 超时会把“静止”误判成断线。

修复：

- 服务端每 1 秒发送 `heartbeat` 包（即使没有视频帧）；
- 客户端接收超时放宽到 10 秒，心跳期间保持连接；
- 客户端 `lastType=heartbeat` 时正常退出，不报错。

实测 300 秒静止桌面：

```text
decode decoded=... failed=0
received frames=... lastType=heartbeat
（无 read error / 无断连）
```

静止桌面下没有新视频帧是预期行为；用户活动或界面变化会恢复出帧。

## 6. 延迟预算告警

- 客户端 render P95 > 33ms 记 `WARNING`；
- decoder P95 > 33ms 或解码失败记 `WARNING`；
- 服务端编码均值 > 12ms 或丢帧比例 > 1% 记 `WARNING`；
- 时钟同步 RTT > 20ms 时抑制延迟统计，避免把队列抖动误报成延迟超标。

## 7. 5 分钟短稳

- server forever + client 300s；
- 活跃阶段 60fps、0 丢帧、编码 ~10ms；
- 静止后心跳维持连接，客户端 300s 正常退出；
- watchdog 同时在线，显示未丢失。

## 8. 8 小时长稳（待执行）

需要夜间无人占用 MacBook：

```bash
# mini（watchdog 已装）
~/boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# MacBook
.build/release/boltkvm client --host <mini> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect
```

观察项：断连次数、watchdog 重建次数、服务端 dropped、客户端 P95 漂移、输入是否持续可用。

## 9. 尚未覆盖

- 真实 8 小时运行；
- 睡眠/唤醒、拔插雷雳线、网络切换的恢复；
- VNC 预登录救援（FileVault 已关闭、自动登录开启，重启链路尚未复测）；
- macOS 升级后的 TCC 重新授权演练。
