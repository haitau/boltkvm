# 全屏下远程点击/按键全部失效：mini 端辅助功能授权被重置（2026-11-02）

## 现象

用户在主控端全屏远程 mini：访达里点击无效、按键无反应；被控端 Finder 前焦正常，按键被本地消费。光标移动正常。与全屏工具条问题（见同日另一报告）相互独立。

## 定位（全部实证，无推测）

1. **主控端输入链路正常**：临时诊断日志（255，提交 3ded0b1）证实 keyDown 到达 monitor、路由主窗口、`isKey=true`、`active=true`、gate 全绿（inVideo/fitOK/非 chrome）、已转发。排除焦点被工具条窗口吞掉、gate 误拦两种假设。
2. **mini 端服务器日志**：`warning: Accessibility/post-event permission missing; input injection will fail`——注入权限缺失时服务器明确告警。
3. **mini 端 TCC 数据库**：`kTCCServiceAccessibility | io.github.boltkvm | auth_value=2 | last_modified=2026-11-02 11:51:38`——辅助功能授权当天 11:51 才被重新允许；用户此前测试（11:44 前后）时授权处于缺失/陈旧状态。当天 mini 日志中有 5 次 `permission reset: cleared ScreenCapture and Accessibility`（Oct-28 部署扰动遗留的多次重置，Screen Recording 被重新授予所以视频正常，Accessibility 漏了）。
4. **运行中的服务器进程是 Oct 28 17:05 启动的**：TCC 授权变更后进程未重启，CGEventPost 拿不到新授权 → 点击/按键注入持续失败。

## 处置

- `ssh mini`（仓库约定之外的细节略去）重启 mini 端 BoltKVM（应用整体退出重开，`boltkvm-server` 由应用以原参数重新拉起）。
- 重启后启动日志**不再出现** Accessibility 告警，注入权限就位。用户重连复测。

## 后续改进（未实施）

- 服务器只在启动时做一次 Accessibility 预检；TCC 运行中被撤权后注入静默失败，仅 stderr 一行告警（GUI 下用户不可见）。应在会话内周期性复检，并通过控制通道把"注入失效"上屏提示给用户。
- 主控端 255 的输入诊断日志（route/gate，提交 3ded0b1）确认为临时性质，问题关闭后移除。

## 结局（同日 12:00 双端重启后）

- 双端重启后一切正常：mini 端辅助功能授权重新生效（新进程拿到授权）、输入注入恢复。
- 重启前 mini 还存在**系统级 UI 假死**：连系统"重新启动"对话框都点击无效，用户长按电源强制关机。重启前 mini 已连续运行 5 天以上；开机后 3-5 分钟内出现负载风暴（load 峰值 128：fileproviderd/bird/Google Drive/mds_stores/corespotlightd 索引与云同步），约 7 分钟回落到 12 以下。
- 经验：headless 被控端长期运行会积累两类故障——①授权被重置后进程不重启就拿不到（且无人察觉）；②索引/同步风暴与残留状态导致 UI 假死。远程"全面失灵"时先查 mini 负载与 TCC 授权，再怀疑链路。
- 待办（未实施）：服务器运行中周期性复检注入权限并上屏提示；主控端 255 的诊断日志已随本结论移除（3ded0b1 引入，本次移除）。

## 后续改进实施（同日，提交 7c101ba）

- 新增 `.notice(15)` server→client 文本包：老客户端 decode 为 `.unknown` 跳过，无需能力协商。
- 服务器新增权限监视器：会话内存活期间每 60s 复检 `CGPreflightPostEventAccess()`，OK→失效/失效→恢复的转变都会发 `.notice` 并记日志；启动时缺权也直接通知。
- 客户端 GUI 把通知显示在状态行；CLI 记日志。mini 与主控端均已部署 0.13 (258)。
- 待用户执行：mini 每周一 04:00 自动重启的 LaunchDaemon 已预置在 mini:/tmp/com.boltkvm.weekly-restart.plist，安装需 sudo（一次性命令见对话记录）。
