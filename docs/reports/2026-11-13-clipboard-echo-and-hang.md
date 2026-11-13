# 长跑后的"未响应"：剪贴板文件回声 + 采集助手假标记（2026-11-13）

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

### mini 现场复核与根因定案（11:50 sample + 11:19 lsappinfo + 11:34 对照实验）

- BoltKVM **app 进程**（UI/中转层）自始至终健康：主线程空闲 runloop、3–4 线程、CPU 时间仅数秒；真正持续吃 CPU 的是 `boltkvm-server` 采集助手（35% CPU = ProRes 编码正常水位）。
- **"未响应"根因（实锤）**：helper 的可执行文件住在 BoltKVM.app 内，`CLI.swift` 为避免第二个 Dock 图标调用 `TransformProcessType(→BackgroundApplication)`，LaunchServices 遂以 bundle 身份把 helper 注册成名为 "BoltKVM" 的应用（`lsappinfo list` 出现两条同 bundle id 记录：可执行文件分别是 `BoltKVM` 与 `boltkvm-server`）。被注册成应用就会被活动监视器周期性 ping 可响应性，而 CLI 进程没有主 runloop，**永远无法应答**——"未响应"标记自进程出生起就挂着。截图里的 36–38% CPU、13 线程、CPU 时间（2h01m / 1m10s）全部是 helper 的编码负载：11:15 新生的 helper 在 11:17 的截图中已带标记（CPU 时间 1:10 与出生时刻吻合），**"长期运行后出现"是错觉，mini 侧从未发生主线程挂死**。
- 对照实验闭环：bundle 副本里跑 `cryptotest`（不触注册路径）不产生注册；`NSPasteboard.general`、`SCShareableContent` 探针均不注册——注册点是 `TransformProcessType` 本身。

## 根因与改动

| 问题 | 定性 | 改动 |
|---|---|---|
| 文件剪贴板回声循环 | 实锤（日志 + 两侧落盘 5×80 MB） | `Clipboard.swift`：新增 `io.github.boltkvm.peer-origin` 标记。`apply()`/`receiveFile()` 把对端来的内容写上剪贴板后同时打标记；`poll()` 见到标记即跳过（`lastChangeCount` 保持更新，不影响后续真实本地拷贝的检测）。本端不回发，循环两端同时断——对旧版对端也生效。 |
| `ClipboardSync.stop()` 用 `queue.sync` | 隐患：断连/关窗（`ClientSession.disconnect`、`finish`，服务端设置面板 `server?.stop()`）都在**主线程**调它；队列若正在搬大文件，主线程被扣到传输结束 | `stop()` 改 `queue.async` 非阻塞；调用方本就先关 socket，传输中的 `send` 自行失败。`sendBundle`/`sendFiles` 分块循环加 `stopped` 检查，stop 后传输立即中止。 |
| helper 被注册成 "BoltKVM" 且永不应答 ping | 实锤（lsappinfo 双 ASN + 探针对照） | `boltkvm` 入口：`server` 模式改为在主线程同步安装 `NSApplication`（`.prohibited`，无 Dock 无菜单）并 `run()`，服务逻辑移入后台任务。runloop 应答 ping，假标记消失；`CLI.swift` 删除 `TransformProcessType` 方案。注意实现禁忌：runloop 不能包进 `MainActor.run`（首版即因此死锁虚拟显示创建——main actor 任务严格串行，`run()` 在其中永不返回，后续 `MainActor.run` 全部饿死），必须作为 async main 的同步前缀执行。 |
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

回声循环本身没有自动化测试（`poll`/`apply` 依赖真实 NSPasteboard，测试刻意不碰用户剪贴板）；修复的正确性由日志证据 + 机制推演支撑，**未在真机上复测回声场景**——建议日常使用中复制一次大文件验证 mini 侧 inbox 不再新增副本。回声标记已于 11:16 在真机对（pro→mini 58 B 测试文件）验证：单程一次传输、0 回发、0 重复副本。

## 标题修正（2026-11-13 12:00）

初版报告把 mini 侧"未响应"当成一次未定案的 app 主线程挂死；后续 `lsappinfo` 双 ASN 取证与对照实验证明 **mini 侧不存在任何挂死**——"未响应"是采集助手被 LaunchServices 以 bundle 身份注册后、因无主 runloop 永不应答可响应性 ping 的**永久假标记**。pro 侧重启前的"未响应"仍是链路劣化期多秒级画面冻结的观感（主 runloop 存活到断电，证据见取证第 3 条）。据此修正标题与结论，修复见上表第 3 行。

## 未验证 / 遗留

- mini 侧挂死已定案为假标记（helper 注册问题），修复（build 265+，`server` 模式带 `.prohibited` 主 runloop）已部署 mini；**活动监视器中的标记是否消失由用户目检确认**（CLI 侧无法直接读取 AM 判定）。
- 今早 mini 服务端反复 RST + 劣化的上游诱因未定案（与假标记无关，是真实的链路/服务端事件）；修复版本两端部署后观察下次长跑。
- helper 的 LaunchServices 身份仍是 bundle 的 "BoltKVM"（活动监视器里会出现两行同名 "BoltKVM"：app ≈0%，helper ≈30%）。若要彻底区分命名，后续可给 helper 独立嵌套 bundle（`CFBundleName = "BoltKVM Server"` + `LSBackgroundOnly`），涉及打包与 TCC 验证，单独立项。
