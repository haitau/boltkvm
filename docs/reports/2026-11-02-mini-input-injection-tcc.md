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
