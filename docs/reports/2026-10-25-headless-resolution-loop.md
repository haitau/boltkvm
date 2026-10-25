# 无雷雳网桥时虚拟屏分辨率来回跳：根因与修复（2026-10-25）

## 1. 现象

在家里用 UU 远程连无头 Mac mini，改「被控端 → 分辨率」后，mini 的桌面在两个分辨率之间反复切换（约每 5 秒一轮），远程画面跟着不断缩放；停止操作也不会停。办公室接雷雳网桥时没有这个问题。

## 2. 证据

mini 的 `~/Library/Logs/BoltKVM.log`（2026-10-24 19:31 前后）连续出现同一组三行，显示 ID 从 259 递增到 287：

```text
app: restarting helper for new display settings
virtual display: id=259 logical=2880x1620 backing=5760x3240 hiDPI=true (2.0s)
server error: Error Domain=boltkvm Code=2002 "no Thunderbolt bridge address found; ..."
app: helper exited with 1; restarting in 3s
```

每一轮的节奏是：子进程启动 → 创建 2880×1620 虚拟屏（约 2.1 秒）→ 绑定端口失败 → 立即退出 → 3 秒后 supervisor 再拉起。虚拟屏存在约 2 秒、消失约 3 秒，系统就在它和另一块 1920×1080 的显示（远程桌面自带的虚拟屏/回退屏）之间来回切。

## 3. 根因

1. `boltkvm server` 先创建虚拟屏，再调用 `TCPListener` 绑定端口；虚拟屏的所有权在这个子进程里。
2. 默认 `--bind auto` 只找 `bridge*` 接口的 IPv4 地址。家里没有插雷雳线，`resolveBindAddress` 抛 `boltkvm 2002`。
3. 这个错误被当成致命错误：子进程 `exit(1)`，虚拟屏随进程消失，桌面回退到剩下的显示。
4. `ServerAppController` 只看到「子进程退出」，3 秒后重启；新进程又创建虚拟屏、又绑定失败。
5. 用户点「分辨率」恰好会重启子进程，于是正好在这个循环里触发；即使不点，任何一次重启也会重复。

补充：子进程被 SIGTERM 结束时不会执行 Swift deinit，虚拟屏会在系统里保留一段时间；下一次创建同 identity 的虚拟屏会被拒绝（实测在显示系统休眠时可持续到唤醒为止，日志里是 `initWithDescriptor returned nil` → 20 秒重试）。这会放大分辨率切换时的空窗，需要显式释放。

## 4. 修复

| 位置 | 改动 |
|---|---|
| `CLI.runServer` | 可自愈的绑定错误（无网桥 2002、端口仍被占用、绑定瞬间地址消失）不再退出；虚拟屏保持不动，每 2 秒重试，网桥出现后直接开始监听，不重建虚拟屏 |
| `CLI.runServer` | 注册 SIGTERM/SIGINT 与 `atexit` 清理：退出前显式释放虚拟屏，重启不再撞 identity |
| `Protocol.swift` | 抽出 `isTransientBindError`，明确哪些错误重试、哪些是配置错误（`--bind` 非法仍然退出） |
| `ServerAppController` | 菜单栏新增状态「虚拟屏就绪，等待网络」，说明当前没插雷雳线、虚拟屏仍在 |
| `Tests` | `BindRetryTests` 5 条：2002 / EADDRINUSE / EADDRNOTAVAIL 重试，2003 / EACCES 不重试 |

## 5. 验证

- `swift build -c release` 通过；`./scripts/test.sh`：61 个 XCTest 全过（新增 5 个）。
- 本机集成复现（用「端口被占用」制造同一条重试路径）：先占住 `127.0.0.1:17474`，再启动 `--bind 127.0.0.1 --virtual-display-size 2560x1600`。
  - 14 秒内 `virtual display: id=` 只出现 1 次，虚拟屏一直在线；日志为 `network: port 17474 is still in use; keeping the virtual display up and retrying every 2 s`。
  - 释放端口后 2 秒内出现 `network: network is available again; starting to listen` 与 `listening on ...`，虚拟屏没有重建。
- mini 实机（2026-10-25 部署后）：
  - 应用启动后 `system_profiler` 显示 `boltKVM 5760×3240 / UI Looks like 2880×1620` 为主显示，日志 `listening on bridge0 ...`。
  - 对子进程发 SIGTERM 模拟重启：日志先出现 `terminating: releasing the virtual display`，约 3 秒后新虚拟屏 `id=291` 创建并开始监听；没有出现 `creation refused`，之后 12 秒保持稳定。
  - 更强的同机验证：杀掉子进程后立刻用 Python 占住 `<mini 雷雳桥 IP>:7474`（模拟端口冲突/不可绑定）。新子进程创建 `id=293` 后进入等待，**虚拟屏始终保持 2880×1620**，系统没有再回退到别的分辨率；释放端口后 2 秒内出现 `network: network is available again; starting to listen`，虚拟屏仍是 `id=293`，没有重建。部署后共 3 次子进程启动 = 3 次虚拟屏创建，没有多余循环。

## 6. 未验证与剩余问题

- **【未经核实】** 真实拔掉雷雳线的瞬间：本次会话没有密码，无法临时关闭 mini 的 `bridge0` 做物理拔插复现；2002 分支由单元测试覆盖，重试循环由上面的端口占用场景覆盖。
- **【事实】** 改分辨率仍会重启采集子进程（分辨率是 argv），因此会有一次约 3 秒的回退到另一块显示，然后稳定到新尺寸。连续来回跳已消除；若要做到无感切换，需要把「虚拟屏所有权」从采集子进程里拆出来单独托管，或在子进程内原地重建并重启采集流，属于后续架构改动。
- 第三方远程桌面自身的显示管理未改动。

## 7. 复现命令

```bash
# 单元测试
./scripts/test.sh --filter BindRetryTests

# 绑定重试 + 虚拟屏不重建（本机）
python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",17474)); s.listen(1); time.sleep(60)' &
./.build/release/boltkvm server --bind 127.0.0.1 --port 17474 \
  --virtual-display-size 2560x1600 --insecure > /tmp/bindtest.log 2>&1 &
sleep 10; grep -c 'virtual display: id=' /tmp/bindtest.log   # 期望 1
kill %1; sleep 3; grep 'listening on' /tmp/bindtest.log      # 期望出现，且 id 仍为 1 次

# 实机重启后检查
ssh <mini> 'system_profiler SPDisplaysDataType | grep -A3 boltKVM'
ssh <mini> 'tail -20 ~/Library/Logs/BoltKVM.log'
```
