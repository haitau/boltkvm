# 改分辨率后主控端像死机：自动重连的修复与原地切模式的边界（2026-10-26）

## 1. 现象

在 mini 的 BoltKVM 菜单里改分辨率后，主控端窗口停在最后一帧，键盘鼠标没有反应，看起来像死机；过很久也不会自己恢复。用户担心以后在互联网/非直连场景（家里通过 UU 看 mini）改分辨率也会这样。

## 2. 证据

- mini 的 `~/Library/Logs/BoltKVM.log`：`app: helper <pid> exited as requested`，随后新 helper 创建了新的虚拟屏（`id=301 logical=3008x1692 backing=6016x3384`），`listening on bridge0 ...` 正常；没有崩溃、没有循环重启。
- `<laptop>` 的主控端日志：上一次会话 `render frames=2513 elapsed=41.89s fps=60.0 drawable=6016x3384`，随后是 `session: ...`，此后**没有任何重连记录**，直到用户手动退出应用。
- mini 上 app、helper、虚拟屏都活着，端口在监听；客户端没有回来。所以不是 macOS 死机，也不是网络断了，而是 **GUI 客户端在连接结束后没有重连**。

## 3. 根因

1. 被控端的「分辨率 / 画质」是采集子进程的 argv（`--width/--height/--virtual-display-size`）。菜单改分辨率必须停掉旧 helper、拉起新 helper。
2. 虚拟屏的所有权在这个 helper 里：helper 退出 → 虚拟屏被释放；新 helper 创建新虚拟屏（实测约 2.0–2.3 秒）→ 重新监听。
3. 旧版 `ClientSession.connect` 只做一次连接：`pump.run()` 结束或抛错后设置 `.failed` 并 `finish`，**没有重试循环**；`ClientController.onEnd` 又只刷新工具栏，不关窗口。于是窗口保留最后一帧，输入失效，看起来就是「死机」。
4. 这与直连/互联网无关：UU 是另一条远程桌面通道，BoltKVM 客户端是否重连只取决于客户端自己的逻辑。

## 4. 修复

| 位置 | 改动 |
|---|---|
| `ClientSession.State` | 新增 `.reconnecting(attempt)`，工具栏显示「连接中断，正在重连…（第 n 次）」 |
| `ClientSession.connect` | 外层重连循环：连接失败/会话结束/服务端正常关闭都重试；退避 0.5 / 1 / 2 / 4 / 5 秒封顶；取消或切换主机时立即退出 |
| `ClientSession.connect` | 每次重试保留 `requestedConfig`（主机分辨率/画质），重新走认证、加密、`config`、输入与音频初始化；重连成功后自动恢复 60fps |
| `ClientSession.connect` | 错误密码（发出认证响应后立刻被重置）不再重试，仍然显示 `.failed`，避免锁死在一个必然失败的循环里 |
| `ServerAppController.restartHelper` | 旧 helper 退出后不再额外等 2 秒；SIGTERM 处理器已经同步释放虚拟屏，新 helper 立即启动，缩短空窗 |
| `Localizable.strings` | 中英文 `client.state.reconnecting` |

## 5. 验证

- `swift build -c release` 通过；`./scripts/test.sh`：67 个 XCTest 全过。
- 端到端（2026-10-26，`<laptop>` 主控端 + mini 被控端，雷雳桥直连）：
  - 主控端以 6016×3384 / 60fps 流式播放时，对 mini 的采集 helper 发 `SIGTERM`。
  - 主控端日志依次出现：`session: ...连接被对方还原; reconnecting` → `connect: attempt 1 failed (...连接被拒绝)` → `connect: attempt 2 failed` → 重新 `auth`、`sending config 3008x1692`、`decoder ready 6016x3384`、`input: window monitor started`。
  - mini 日志：新 helper 创建虚拟屏并 `listening`，随后 `client connected`、`auth ok`、`capture started`，恢复 60fps。
  - 结论：窗口不再永久停住，状态栏会显示重连次数；空窗约数秒（虚拟屏重建 2.1 秒 + 客户端退避）。

## 6. 原地切模式：试过，但不能上线

为了连 UU 这种「不经过 BoltKVM 客户端」的场景也做到无感，做过一版 `CGVirtualDisplay applySettings:` 的原地切换原型（不销毁显示，只换 mode）：

- 在**测试用 display identity**（笔记本，独立 identity）上：`3008×1692 → 1728×1117 → 3008×1692` 两步都成功，显示 ID 始终不变（`id=7`），背板 `6016×3384 ↔ 3456×2234`。说明私有的 `applySettings:` 在合适条件下确实能原地换 mode。
- 在 **mini 的生产 identity** 上，同样的调用失败了：日志为 `virtual display: mode switch to 1728x1117 did not stick`，显示被留在了 `logical=3456x2234 pixel=3456x2234` 的 1× 模式（不是请求的 1728×1117 HiDPI），桌面会变成超大逻辑分辨率。随后通过重启 helper 恢复为 3008×1692。
- 失败原因与生产 identity 的模式缓存/WindowServer 对 2× mode 的解释有关；只换个 id 并不能保证用户已有窗口布局，不能作为修复。相关代码（`BKVVirtualDisplayApplyMode`、`--resize` 信号、app 侧 `SIGUSR1` 请求）已经全部回退，mini 上重新部署了安全版本；当前只保留客户端自动重连。

因此**目前的取舍**：

- BoltKVM 主控端：断线自动重连，几秒恢复，不会「死机」。
- UU/其它远程桌面：改分辨率仍会重建虚拟屏，画面可能短暂黑屏或缩放；mini 本身没有死机。要做到 UU 也完全无感，需要更可靠的原地 mode 切换（或把虚拟屏所有权从 helper 拆出来由 app 托管），并先在真实 identity 上验证，不能直接用原型上线。

## 7. 复现与检查

```bash
# 主控端重连：流式播放时杀掉被控端采集进程
ssh <mini> 'pkill -TERM -f "boltkvm-server server"'
tail -f <laptop>:~/Library/Logs/BoltKVM.log
# 期望：session: ... reconnecting -> auth -> decoder ready -> 恢复

# 单元测试
./scripts/test.sh
```

## 8. 未验证

- UU 画面在改分辨率瞬间的具体表现：本次只从服务端日志确认虚拟屏被释放/重建，没有在 UU 客户端上录屏确认；「短暂黑屏/缩放」是机制推断，不是实测结论。
- 不同 macOS/显示缓存状态下 `applySettings:` 的行为：生产 identity 已证实不可靠；未找到稳定可用的调用顺序。
