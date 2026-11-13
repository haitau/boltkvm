# 长跑后的"未响应"：剪贴板文件回声 + 一次未定案的 app 挂死（2026-11-13）

## 现象

- mini（被控端）长期运行后，活动监视器里 BoltKVM 标记**未响应**，38% CPU、13 线程、累计 CPU 时间 2:01:39；用户按电源强制重启 mini（11-12 16:51）。
- 重启前 pro（主控端）的活动监视器也出现过未响应；用户 11-13 09:59 按电源强制重启 pro，之后两端恢复正常（10:33 手动拉起 app，画面、延迟全部回到正常水位）。

## 取证

### pro 侧日志（~/Library/Logs/BoltKVM.log 跨重启保留，78k 行 ≈ 11-08 至今）

1. **剪贴板文件回声循环（实锤，11-08 20:33）**：同一个 80769307 B 的 `Clash.Verge_2.5.10_aarch64.dmg` 在同 4 分钟内**整文件发送 5 次**，文件名逐跳滚雪球：
   `…aarch64.dmg` → `… 2.dmg` → `… 2 2.dmg` → `… 2 2 2.dmg`（`Clash.Verge_2.5.10_aarch64 2 2 2 2.dmg`）。
   mini 的 `~/Downloads/BoltKVM Clipboard/` 里至今躺着**同分钟写入的 5 个 80 MB 副本（393 MB）**，数量与日志完全吻合。
   机制：`poll()` 把"剪贴板上的文件 URL"当成新的本地拷贝发给对端 → 对端收下放进 inbox 并把 URL 写回它的剪贴板 → 0.5 s 后对端的 `poll()` 又把它当新拷贝发回来。`sendFiles()` **没有任何回声抑制**（文本/图片有 `lastSentHash`/`lastAppliedHash` 哈希闸门，文件没有；且名字每跳一跳都变，哈希闸门对文件也天然无效）。图片路径的哈希闸门也只能算运气：日志里 220657 B 发出 → 220675 B 回来（平台重编码 +18 B，哈希变了，闸门失效一次）。
2. **pro 的主 runloop 到断电前都是活的**：`render.win`（由主线程 60 s Timer 打印）在重启前最后一个窗口仍按时出现（`frames=1432 fps=23.9`）。"未响应"的直接观感来自链路劣化期的多秒级冻结：decode 失败 69 次、`decodeLatency max=9225.9ms`、窗口 `p95=1449.8ms max=5139.7ms`、time-sync RTT 从 0.4ms 抖到 2861ms——画面等效冻住数秒，活动监视器在此期间会间歇判未响应。
3. **今早 09:29–09:59 的链条**：3.7 h 会话被对端 RST（`连接被对方还原`）→ 30 s 后再次 RST → 一个 `decoded=0 elapsed=0.000s` 的空会话 → 重连后 6 分钟严重劣化（fps 2.6–21，P95 0.2–1.4 s）→ pro 断电。全部 RST 来自 mini 侧，即 mini 侧先行出问题。
4. **昨晚 16:50 mini 挂死前链路完全干净**：30.3 h 会话最后 10 小时内 time-sync RTT>200 ms 仅 1 次、0 解码失败、剪贴板只有几十字节的文本——mini 的 app 主线程挂死时视频链路毫无异样，随后 RST、`连接被拒绝`×2（mini app 不再 accept）、`无到主机的路由`（mini 断电）。

### mini 侧取证为何缺失（本身是个 bug）

`AppLog.redirect()`（ServerAppController.swift）在启动时发现日志 >5 MB 就**直接删除**。mini 的日志当时已超限，16:52 重启 app 时整个事发历史被删——这就是 mini 侧只有截图、没有日志的原因。pro 的 4.2 MB 侥幸低于阈值而幸存。本次已改为轮转保留一代（`BoltKVM.log.1`）。

### mini 现场复核（11-13 10:50，`sample` PID 2909）

- 当前 app 进程（0.13.2 build 263，11-12 16:52 启动）**完全健康**：主线程在 `mach_msg2_trap` 空等 runloop，仅 3 线程、CPU 时间 3.07 s。
- 真正持续吃 CPU 的是 `boltkvm-server` 采集助手（35% CPU，ProRes 编码属正常水位）。
- 截图里挂死的 38% CPU 实例是重启前的旧实例；app 进程本身（UI/中转层）按设计不该有这个负载，且事发日志已被上面第 2 条的日志删除行为销毁——**这次挂死的精确堆栈无法追认**。系统侧线索：mini 当时 kernel_task 745 线程、16:53 有 JetsamEvent，怀疑内存压力参与，但无直接证据。

## 根因与改动

| 问题 | 定性 | 改动 |
|---|---|---|
| 文件剪贴板回声循环 | 实锤（日志 + 两侧落盘 5×80 MB） | `Clipboard.swift`：新增 `io.github.boltkvm.peer-origin` 标记。`apply()`/`receiveFile()` 把对端来的内容写上剪贴板后同时打标记；`poll()` 见到标记即跳过（`lastChangeCount` 保持更新，不影响后续真实本地拷贝的检测）。本端不回发，循环两端同时断——对旧版对端也生效。 |
| `ClipboardSync.stop()` 用 `queue.sync` | 隐患：断连/关窗（`ClientSession.disconnect`、`finish`，服务端设置面板 `server?.stop()`）都在**主线程**调它；队列若正在搬大文件，主线程被扣到传输结束 | `stop()` 改 `queue.async` 非阻塞；调用方本就先关 socket，传输中的 `send` 自行失败。`sendBundle`/`sendFiles` 分块循环加 `stopped` 检查，stop 后传输立即中止。 |
| 日志超限即删除 | 实锤（本次事故取证失败直接原因） | `AppLog.redirect()`：>5 MB 时改名轮转为 `.log.1` 保留一代，不再删除。 |

## 验证

```bash
swift build -c release   # 通过
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardTests
# Executed 10 tests, with 0 failures
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# Executed 107 tests, with 1 test skipped and 0 failures
.build/release/boltkvm selftest   # SELFTEST OK
.build/release/boltkvm cryptotest # PASS (1000 frames, 3 tamper cases)
```

回声循环本身没有自动化测试（`poll`/`apply` 依赖真实 NSPasteboard，测试刻意不碰用户剪贴板）；修复的正确性由日志证据 + 机制推演支撑，**未在真机上复测回声场景**——建议日常使用中复制一次大文件验证 mini 侧 inbox 不再新增副本。

## 未验证 / 遗留

- 昨晚 mini app 主线程挂死的精确根因**未定案**（堆栈与日志均不可追认）。已部署的两个修复覆盖了其中可证的类（剪贴板风暴、断连主线程阻塞）；若再次出现未响应，**先 `sample <pid> 2` 抓主线程栈、再重启 app**，日志现在会保留一代不再丢失。
- mini inbox 里的 5 个重复 dmg（393 MB）待用户确认后手动清理（代码不自动删用户文件）。
- 今早 mini 服务端反复 RST + 劣化的上游诱因未定案（与昨晚事件可能同源）；修复版本两端部署后观察下次长跑。
