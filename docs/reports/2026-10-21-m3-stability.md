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

- 客户端 render P95 超过**分档预算**（见 6.1）记 `WARNING`；33ms 仍是产品 SLO，单独统计命中率；
- decoder P95 > 33ms 或解码失败记 `WARNING`；
- 服务端编码均值 > 12ms 或丢帧比例 > 1% 记 `WARNING`；
- 时钟同步 RTT > 20ms 时抑制解码侧延迟统计，避免把队列抖动误报成延迟超标（渲染侧统计不受此门槛影响）。

### 6.1 分档（2026-10-22 定）

排队延迟随编码帧大小上升，固定 33ms 在 4K ProRes 下必然每分钟告警（8 小时长稳刷了 480 条）。改为按客户端实测的每帧字节数分档：

| 帧大小 | 预算 | 典型场景 | 实测 p95 |
|---|---|---|---|
| < 64 KB | 33 ms | 1080p UI / 轻内容 | 25 KB → 35.9 ms |
| 64–512 KB | 40 ms | 4K 轻内容 | 89 KB → 30.5 ms |
| ≥ 512 KB | 55 ms | 4K ProRes 422 @ 60fps | 2480 KB → 48.4 ms |

实现：接收循环每 60s 用窗口内 `winBytes/winFrames` 算平均帧大小，`Renderer.budget(forFrameKB:)` 选档写入渲染器；`render.win` 行携带 `budget=XXms`，只在超过分档预算时告警；退出时另打一行 `SLO33 windows hit=N/M` 保留 33ms 产品口的命中率。

> **口径更新（2026-10-23）**：分档已删除，GUI SLO 改为 50ms 平档（采集→上屏，不含输入上行）。
> 本文的 33/40/55ms 与 `SLO33` 都是历史口径。

## 7. 5 分钟短稳

- server forever + client 300s；
- 活跃阶段 60fps、0 丢帧、编码 ~10ms；
- 静止后心跳维持连接，客户端 300s 正常退出；
- watchdog 同时在线，显示未丢失。

## 8. 8 小时长稳（已执行）

2026-10-21 19:10 → 10-22 03:10 已跑完，结论、数据与分档复核见 [8 小时长稳结论](2026-10-22-m3-soak-8h.md)。下面是当时的执行方式，仍可复用：

```bash
# mini（watchdog 已装）
~/boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# MacBook
.build/release/boltkvm client --host <mini> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect
```

观察项：断连次数、watchdog 重建次数、服务端 dropped、客户端 P95 漂移、输入是否持续可用。

### 8.1 执行方式（2026-10-21 修订）

起跑前用 `scripts/soak-preflight.sh --host <mini>` 自检（caffeinate 标志、pmset 断言、
电源、TCP 可达、残留进程），它同时创建 run 目录并打印双端命令；起跑后把
`scripts/soak-monitor.sh` 挂上做 5 分钟粒度采样，明早直接看 `monitor.tsv`。

```bash
scripts/soak-preflight.sh --host <mini>
nohup .build/release/boltkvm client ... 2>&1 | tee ~/soak/<run>/client.log &
nohup scripts/soak-monitor.sh --client-log ~/soak/<run>/client.log &
```

两点读数口径，避免误判：

- **客户端每 60s 打一行** `render.win`（窗口 fps/p95）与 `loop.win`（包数/重连数）、
  `input.win`（sent/tapDisabled）。窗口 `frames=0` 说明显示休眠或渲染停摆，不是链路故障；
  `tapDisabled` 增长说明输入 tap 被系统禁用（锁屏 / secure input / 回调超时），不是输入源问题。
- **客户端 recv 超时 10s**（服务端心跳 1s），所以"断连次数"必须区分：
  `monitor.tsv` 的 `reconnects` 是成功重连数，`read_errors` 含 10s 抖动触发的重连；
  两者都高才是真链路问题。
- 客户端渲染路径原先没有 `beginActivity` 断言，显示休眠会静默停掉渲染段，已补齐（与 server 同 options）。

## 9. 尚未覆盖

- 输入连续性（8 小时长稳期间无人操作，只验证了 tap 存活）——计划内，见 [input-continuity.md](../plans/input-continuity.md)；
- 睡眠/唤醒、拔插雷雳线、网络切换的恢复——**不列入计划**（需要人工操作），见 [open-items.md](../plans/open-items.md)；
- 锁屏界面能否用注入事件解锁（重启后服务恢复已验，见 §12；解锁本身未验证）；
- VNC 预登录救援（自动登录已可用，预登录窗口未单独验证）——不列入计划；
- macOS 升级后的 TCC 重新授权演练——不列入计划；
- 音频隔离实测——已补，见 [2026-10-22-audio-option.md](2026-10-22-audio-option.md)（默认零音频字节，`--audio` 可选）。

## 10. watchdog v1 误判与修复（2026-10-21）

实际部署后发现 v1 watchdog 在 LaunchAgent 上下文里 **误判虚拟显示丢失**：

```text
watchdog: target display missing (1)
watchdog: target display missing (2)
watchdog: vdscreen on ... displayID=196
（约 10 秒后重复，displayID=198、200 …）
```

- 根因：健康检查只用 `CGGetActiveDisplayList`，在 LaunchAgent 里对 `CGVirtualDisplay` 返回了假阴性；
- 现象：每约 10 秒重建一次 vdscreen，用户在主控端看到 mini “不停操作”；
- 影响：显示 ID 和 vdscreen 进程不断变化，无法稳定采集。

修复：

- 健康检查优先执行 `vdscreen status`，只要输出包含 `6016 x 3384` 即视为健康；
- `CGGetActiveDisplayList` 仅作为 CLI 状态不可用时的回退；
- 连续 2 次不健康才重启，并加 **60 秒重启冷却**，即使再次误判也不会形成风暴；
- `watchdog --once` 只做体检，不自动重建。

验证：

```text
watchdog --once → exit=0，vdscreen PID 不变
重装后 60s  → vdscreen PID 83581 不变
             watchdog PID 84185 不变
             watchdog 日志无 unhealthy 记录
```

v1 日志保留在 `~/Library/Logs/boltkvm-watchdog.log.old` 作为证据；当前运行的是修复后的 v2。

## 11. 传输认证与监听范围（2026-10-22）

原始实现 `bind(INADDR_ANY)` 且无任何握手校验：任何能连到 7474 的机器都能取画面并注入键鼠，与设计文档“雷雳直连使用配对密钥、不监听对外接口”不符。改动：

- **监听范围**：`TCPListener` 增加 `--bind`，默认 `auto` —— 取 `getifaddrs` 里第一个 `bridge*` 接口的 IPv4；找不到就直接报错并提示显式指定。`--bind 0.0.0.0` 仍可用但会打警告。
- **认证**：预共享密钥 + 挑战应答。服务端 accept 后发 `authChallenge`（32 字节 `SecRandomCopyBytes` 随机数），客户端回 `authResponse` = HMAC-SHA256(key, nonce)，服务端常数时间比较后回 `authOk`；不等长或超时（5s）一律断开。密钥来源 `--key` > `$BOLTKVM_KEY` > `~/.boltkvm-key`（64 位 hex 按原始字节解，其余按 UTF-8）。
- **默认安全**：没有密钥且未显式 `--insecure` 时服务端拒绝启动；`--insecure` 会打一行警告。
- 认证阶段会跳过非 `authResponse` 的包，因为客户端可能在看到 challenge 之前就发了 time-sync 请求。

验证（2026-10-22，本机 + 雷雳桥各一轮）：

| 场景 | 结果 |
|---|---|
| 无密钥、无 `--insecure` | 拒绝启动，提示补齐密钥 |
| 正确密钥 | 两端 `auth ok`，8s 收到 157 帧（雷雳桥） |
| 错误密钥 | 服务端 `auth failed ... Permission denied`，连接被重置 |
| 客户端无密钥 | 客户端提示建 key 的三种方式后退出（EACCES） |
| `--insecure` | 正常出流，日志有警告 |
| 默认绑定 | `listening on bridge0 <bridge-ip>:7474`（仅雷雳桥） |

仍存在的限制：链路是明文 TCP，密钥只解决“谁能连”，不解决“谁能看”；重放同一 nonce 无效，但密钥泄露即等于交出这台机器。

## 12. 重启恢复验证（2026-10-22）

触发方式：`ssh mini 'osascript -e "tell application \"System Events\" to restart"'`，无需 sudo，rc=0。

| 阶段 | 结果 |
|---|---|
| 触发 → sshd 重新可用 | 约 25 s |
| 自动登录 | FileVault Off、`autoLoginUser=shawn`；登录窗口过后直接进桌面会话（`who` 显示 console） |
| 虚拟显示 | `io.github.lyondan.vdscreen` LaunchAgent 自动拉起，6016×3384 @60Hz，`Online: Yes` |
| 看门狗 | `com.boltkvm.watchdog` 运行（`launchctl list` 可见，KeepAlive 生效） |
| 服务端 | 从 ssh 执行 `open -a Terminal` 启动成功；`auth ok`；capture 正常出帧 |
| 会话状态 | **锁屏**：`CGSSessionScreenIsLocked = true`。`com.shawn.autolock-after-boot` 在启动 30 s 后执行 `pmset displaysleepnow` |
| 显示器休眠后 | 新会话报 `no display`（`SCShareableContent` 返回 0 个屏），重启服务端即恢复 |

结论：**进程层与服务层的恢复是全自动的，恢复到"可用桌面"不是**——重启后停在锁屏，需要输入密码。

同一轮补的修复（`Server.start()`）：取显示器前先用 `IOPMAssertionDeclareUserActivity` 唤醒显示器，最多重试 5 次（间隔 0.7 s），失败时错误信息提示 `caffeinate -disu`。该路径今天没有复现出失败，属于预防性改动。

### 12.1 无人值守自启（同日第二轮重启）

第一轮之后补了三件事并重测：服务端自启、守护、屏幕共享救援。

| 尝试 | 结果 |
|---|---|
| LaunchAgent 直接托管 `boltkvm server` | **失败**：`Screen Recording permission missing`。TCC 归属是 Terminal（GUI app），launchd 拉起时责任方不是它 |
| 登录项指向 `soak-start.command` | **成功**：重启后 Terminal 自动打开并起服务端，客户端直连出 465 帧 |
| 服务端守护 | `soak-start.sh` 改 `while` 循环；`pkill` 后 3 秒自动重启（实测 10:30:29 杀、10:30:32 起） |
| 单实例守卫 | PID 文件 + `kill -0`；重复执行脚本只打印 "another supervisor is already running" 并退出，避免重复打开时抢 7474 |
| 屏幕共享 | 5900 可达，返回 `RFB 003.889`，锁屏态同样应答——这是不依赖 boltkvm 的解锁通道 |

第二轮重启（10:29:17 引导，10:29:31 ssh 恢复）全自动完成：自动登录 → vdscreen/watchdog → 登录项起服务端 → 客户端出帧，无需人工介入。

仍未验证：锁屏界面能否被注入事件解锁。需要真密码，且 macOS 对登录窗口的合成事件策略没有公开保证；现在的做法是不依赖它——解锁走屏幕共享。

