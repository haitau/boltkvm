# M3 稳定性、安全与重启自愈验证报告

- 日期：2026-10-21（2026-10-22 补充认证与重启恢复实测）
- 目标：落地 TCC 权限自检、虚拟显示守护、断线自动重连、静止桌面心跳保活、传输层挑战-应答认证与重启无人值守恢复。

## 1. TCC 权限自检（`boltkvm doctor`）

`boltkvm doctor --role server|client` 负责在启动或系统升级后一次性检查所需的 TCC 权限：

```text
$ boltkvm doctor --role server
PASS Screen Recording (CGPreflightScreenCaptureAccess)
PASS Input Monitoring / listen events (CGPreflightListenEventAccess)
PASS Accessibility / post events (CGPreflightPostEventAccess)
PASS Accessibility trust (AXIsProcessTrusted)
```

- 服务端启动时自动检查「屏幕录制」权限，缺失时明确提示授权路径；
- CLI 客户端开启 `--input` 时检查「输入监控」权限（GUI 客户端采用窗口内 `NSEvent` 本地监听，无需该权限）。

## 2. 服务端常驻循环与客户端自动重连

- **服务端常驻（`--seconds 0`）**：单个客户端断开后自动停止当次采集/编码会话，清理资源并回到 `accept` 等待下一次连接；同一时刻只服务一个客户端，保证单输入源；
- **客户端重连（`--reconnect`）**：连接中断后每秒自动重试（认证密钥错误时直接退出不盲目重试），重连成功后重新协商时钟偏移、会话密钥与解码器。

实测运行中重启服务端，客户端在 5 秒内自动恢复连接并继续渲染画面。

## 3. 静止桌面心跳保活

ScreenCaptureKit 在桌面完全静止时会暂停输出新帧。为避免客户端因收不到数据而误判连接超时：

- 服务端每 1 秒发送一次 `heartbeat` 包；
- 客户端在会话期间每 3 秒发送一次 `timeSync` 保活包，接收超时设为 10 秒。

实测完全静止桌面连续运行 300 秒，0 断连、0 读取错误。

## 4. 延迟与丢帧监控阈值

- **服务端**：每 2 秒输出一行 `stats`；当平均编码延迟 > 12 ms 或丢帧率 > 1% 时输出 `WARNING`；
- **客户端解码层**：`capture→decode` P95 > 33 ms 或出现解码失败时输出 `WARNING`（时钟同步 RTT > 20 ms 时自动抑制延迟统计，排除握手期队列抖动干扰）；
- **客户端渲染层**：每 60 秒输出一行 `render.win` 与 `render split`，当 GUI `capture→present` P95 > 50 ms 或窗口 0 帧时输出 `WARNING`。

## 5. 传输认证与默认监听范围（2026-10-22）

- **默认仅绑雷雳网桥**：`--bind auto`（默认）通过 `getifaddrs` 自动查找第一个 `bridge*` 接口的 IPv4 地址进行监听，避免将控制端口暴露到局域网或 Wi-Fi；本机回环测试可传 `--bind 127.0.0.1`；
- **挑战-应答认证**：服务端接受连接后发送 32 字节随机 `authChallenge`，客户端使用预共享密钥计算 `HMAC-SHA256(key, nonce)` 返回 `authResponse`，服务端采用常数时间比对通过后返回 `authOk`，失败则立即断开并延迟 1 秒；
- **默认强制认证**：未提供密钥时 CLI 会自动生成 8 位连接口令（`Sources/BoltKVMCore/CLI.swift` 的 `ensureKey` 路径）；只有生成失败才拒绝启动。

| 测试场景 | 实测结果 |
|---|---|
| 正确密钥连接 | 两端 `auth ok`，雷雳桥稳定出流 |
| 错误密钥连接 | 服务端记录 `auth failed` 并重置连接，客户端收到拒绝后停止重试 |
| 默认绑定地址 | `listening on bridge0 <bridge-ip>:7474` |

## 6. 虚拟显示守护与重启恢复验证（2026-10-22）

在早期使用外置 `vdscreen` 的阶段，`boltkvm watchdog` 提供独立的 LaunchAgent 守护（通过 `vdscreen status` 与 `CGGetActiveDisplayList` 双重检查并在连续缺失时自动重建，带 60 秒冷却期防止误判风暴）。在阶段 2 内建 `CVirtualDisplay` 并升级为 `BoltKVM.app` 后，虚拟屏直接由 `boltkvm-server` 子进程持有，被系统移除时退出并由宿主 App 在 3 秒后自动拉起重建。

针对被控端整机重启场景（`osascript -e 'tell application "System Events" to restart'`）进行了两轮端到端恢复实测：

| 恢复环节 | 实测表现 |
|---|---|
| 系统引导与 SSH 恢复 | 触发重启后约 25 秒 `sshd` 重新可达 |
| 自动登录与服务自启 | 开启自动登录后直接进入 Aqua 桌面会话，登录项自动拉起服务端并创建 `6016×3384 @ 60Hz` 虚拟屏 |
| 显示器唤醒保护 | `Server.start()` 在枚举显示器前调用 `IOPMAssertionDeclareUserActivity` 唤醒显示器并持有防休眠断言，避免无头显示器休眠导致 `SCShareableContent` 报 `no display` |
| 锁屏救援通道 | 系统屏幕共享（VNC 5900 端口）在锁屏状态下正常返回 `RFB 003.889`，可随时作为带外解锁通道 |

## 证据分级

- 【事实】`boltkvm doctor --role server` 的四项 `PASS` 输出是本报告唯一成段贴出的原始输出。
- 【推断】常驻循环的断开清理、每秒重连并重协商时钟偏移/会话密钥/解码器、1 秒心跳与 3 秒 `timeSync`、看门狗 60 秒冷却、挑战-应答认证与失败后延迟 1 秒断开，都是对代码机制的解释。
- 【未经核实】“重启服务端后客户端 5 秒内恢复”“静止桌面 300 秒 0 断连、0 读取错误”只有结论性描述，未附原始客户端/服务端日志。
- 【未经核实】认证的三种实测场景（正确密钥、错误密钥、默认绑定地址）仅以表格给出，没有原始输出，无法复跑核对。
- 【未经核实】整机重启各环节（约 25 秒 `sshd` 可达、自动登录、`IOPMAssertionDeclareUserActivity` 唤醒、锁屏 VNC 返回 `RFB 003.889`）未附时间戳与日志。
