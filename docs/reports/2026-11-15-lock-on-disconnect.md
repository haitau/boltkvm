# 结束远程会话时被控端自动锁屏（A-6，2026-11-15，v0.14.0）

## 背景与决策

- 现象：结束对 mini 的远程控制后它不自动锁屏，每次都要在主控端手工锁。
- 领导拍板（本轮已生效）：锁定时机=**仅主动断开**（关窗、客户端退出）；掉线、崩溃不锁。GUI 默认开启、面板开关可关；CLI 默认不发锁屏命令，仅 `--lock-on-exit` 时发。锁实现只走 `SACLockScreenImmediate`，不做 pmset 熄屏兜底。E2E 锁完不解锁（解锁=人回来走系统 VNC）。版本 0.14.0。

## 实现

- 协议：`RemoteAction.lockScreen = 10`，追加不重编号；未知字节服务端忽略，先部署新服务端即可兼容旧客户端。
- 服务端：`Server.handleCommand(_:)`（原读循环内联 switch 抽出，便于测试注入）`.command` 派发；`.lockScreen` 执行 init 注入的锁闭包，默认实现 `lockScreenImmediate()`：dlopen `/System/Library/PrivateFrameworks/login.framework/login` + dlsym `SACLockScreenImmediate`，失败仅记日志。
- 客户端 GUI：`Prefs.lockOnDisconnect`（默认 true）+ 主机面板勾选框「断开时锁定被控端屏幕」；`ClientController.disconnectRemote()` 在 `windowWillClose`（关窗）与 `shutdown`（退出/换角色）两个主动断开点、断开**前**发命令。刻意不挂 `ClientSession.disconnect()`：`connect()` 复用会话前也调它，挂那里重连前会误锁。
- CLI：`boltkvm client --lock-on-exit`，握手成功（authOk）后才在退出前发送；不带 flag 全程不发。
- 决策函数 `lockCommandOnDisconnect(enabled:)`：GUI 传面板开关、CLI 传 flag；返回 nil 即不构造锁命令。

## 验证（开发机，代码级）

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
# Build complete! (9.81秒)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# Executed 112 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.379 (0.384) seconds
```

- 基线（改前）：`Executed 107 tests, with 1 test skipped and 0 failures`；改后 112/1/0——新增 5 条且 skip 不增，全绿。
- 新增钉死用例：`RemoteAction.lockScreen.rawValue == 10`（含 `.command` 包首字节往返）；`Server.handleCommand` 假闭包计数（发 1 次调 1 次、发 2 次调 2 次）；未知字节 `0xFF`/`0x00`/空 payload 均不动作（0 次调用）；`lockCommandOnDisconnect` 开=发、关=nil。单测全部注入假闭包，**永不真锁**。

## 验证（E2E，mini 实机，部署后回填）

【E2E 于任务 6 部署后回填本节：版本核对、CLI `--lock-on-exit` 退出前后锁态查询两次读数、无 flag 重连。】

## 结论

【事实】
- 协议命令通道追加了 `lockScreen = 10`，两端以假闭包/假包单测覆盖，112 tests / 1 skip / 0 failures。
- `CGSession -suspend` 路线已死：mini 上二进制不存在（实测）。
- 本机与 mini 的 dlopen+dlsym `SACLockScreenImmediate` 均解析成功（RESOLVED）。
- 锁态查询 `ssh mini "ioreg -w0 -l | grep -c CGSSessionScreenIsLocked"` 未锁读数 0。

【推断】
- 「锁得真」由 SACLockScreenImmediate 保证（与 ⌃⌘Q 同源），熄屏断言被 caffeinate/boltkvm-server 占用不影响它——最终以任务 6 锁后查询读数变化与屏幕状态闭环。
- 掉线/崩溃不锁：它们不经过 `ClientController` 的两个主动断开点，也没有 CLI flag 通路；这是设计选择（代价：掉线不锁回到现状）。
- 回环/自测不误锁：CLI 默认不发命令；GUI 单测不构造真连接。

【未验证/遗留】
- GUI 勾选框的实际点击路径（开关关→关窗不锁）未在真机 GUI 上逐项点验，代码级以 `lockCommandOnDisconnect` 单测+派发计数覆盖。
- 锁屏对 SCK 采集/虚拟显示的具体影响（帧流是否继续、重连恢复耗时）未专项测量。
- 自动解锁不做（R3，Secure Input），锁屏后恢复只能人工走系统 VNC。
