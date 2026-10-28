# 被控端双权限入口与 TCC 重授权修复（2026-10-28）

## 问题

1. 被控端设置面板只有「打开系统设置（屏幕录制）…」一个权限按钮；菜单栏也按当前授权状态隐藏条目，辅助功能已授权时只剩屏幕录制一项（或反过来）。用户看不到另一项，容易误以为只需要一个权限。
2. 重装或重签名后，系统设置里旧 `BoltKVM` 的开关可能仍显示为开，但应用启动时 `CGPreflightScreenCaptureAccess()` / `AXIsProcessTrusted()` 仍返回 false。根因是 TCC 记录里保存的是旧的代码要求（旧 cdhash 或旧证书），与新应用不匹配；用户反复勾选旧行不会生效。
3. 用户手动执行 `tccutil reset ScreenCapture io.github.boltkvm` 与 `tccutil reset Accessibility io.github.boltkvm` 后可以恢复，说明需要在安装/修复流程里自动做这件事，而不是让用户每次猜。

## 改动

### 1. 两个权限入口始终可见

- 菜单栏固定显示：
  - `屏幕录制权限…`
  - `辅助功能权限…`
  - `重置权限并重新授权…`
- 前两项用菜单勾选状态表示当前是否已授权；点击分别调用 `CGRequestScreenCaptureAccess()` / `AXIsProcessTrustedWithOptions(prompt: true)`，再打开对应的系统设置页。
- 被控端设置面板固定显示两个按钮，不再因为一项已授权而隐藏另一项；任意一项缺失时状态点为橙色。
- `ServerSettingsController` 读取 `ServerAppController.needsAccessibility`，与屏幕录制状态一起决定状态点颜色。

### 2. 应用内重置入口

菜单栏新增 `重置权限并重新授权…`，确认后只对本 bundle 执行：

```bash
tccutil reset ScreenCapture io.github.boltkvm
tccutil reset Accessibility io.github.boltkvm
```

随后重新触发两项授权请求并打开屏幕录制设置页。提示用户授权后退出重开应用。此操作会丢弃有效授权，因此有确认框，且只用于“开关看起来开着但仍未授权”的场景。

### 3. 安装脚本按签名要求决定是否重置

`scripts/install-app.sh` 在替换 bundle 前读取旧应用的 designated requirement，与 staging 中的新应用比较：

- 相同（例如同一 `BoltKVM Local` 证书重新编译）：保留 TCC 授权，不重置；
- 首次安装、旧应用缺失、ad-hoc ↔ 稳定证书切换、或指定 `--reset-permissions`：只清除 `ScreenCapture` / `Accessibility` 两项，再启动应用；
- 新增 `--reset-permissions` 用于手动强制清一次。

`scripts/deploy-app.sh` 在远端做同样的比较与重置；同时把远端按路径 `pkill -f` 改为精确进程名 `pgrep -x BoltKVM` / `pgrep -x boltkvm-server`，避免误杀执行脚本的 shell。

## 验证

- `swift build -c release --disable-sandbox --scratch-path .build` 通过。
- 本机以 server 角色启动后，菜单栏实际读取到：
  - `屏幕录制权限…`
  - `辅助功能权限…`
  - `重置权限并重新授权…`
- 设置面板实际读取到两个按钮：`屏幕录制权限…`、`辅助功能权限…`。
- 点击 `屏幕录制权限…` 后前台切到系统设置，窗口标题为 `录屏与系统录音`；点击 `辅助功能权限…` 后系统设置窗口切到辅助功能相关页面（macOS 27.0.1 上标题为 `设备控制和数据访问`）。
- 同一稳定签名重新构建安装时，脚本输出 `签名身份未变，保留现有 TCC 授权。`，未清空授权。
- `--reset-permissions --no-build` 实测输出 `已按 --reset-permissions 清除旧 TCC 条目；请重新授予屏幕录制与辅助功能。`，退出码 0。测试时本机 server 的两项权限本来都是 false，因此没有破坏有效授权。
- mini 已部署同一 0.12.2 (212) 构建。部署后日志为 `app: server role starting (screen recording: true, accessibility: false)`，随后 helper 正常出帧；说明同一稳定签名的屏幕录制授权被保留，而辅助功能仍缺。mini 上需要在新的设置面板点「辅助功能权限…」并授权，键鼠注入才能生效。

## 未验证 / 边界

- TCC 授权本身不能脚本代替；脚本只能清除不匹配的旧记录，最终仍需用户在系统设置里勾选。
- 未做“在 mini 上从旧签名升级 → 自动重置 → 用户重新授权 → 采集/注入恢复”的完整跨机验证；本机已验证两个分支的输出与入口 UI。mini 当前屏幕录制为 true、辅助功能为 false，尚不能据此声称键鼠注入已恢复。
- 设置面板两个按钮的点击已在 macOS 27.0.1 本机验证；英文界面未逐项实机点击。
- 重置后建议退出重开应用；当前进程可能仍持有旧 TCC 结果。

## 相关文件

- `Sources/BoltKVMCore/App/ServerAppController.swift`
- `Sources/BoltKVMCore/App/ServerSettingsController.swift`
- `Packaging/Resources/{zh-Hans,en}.lproj/Localizable.strings`
- `scripts/install-app.sh`
- `scripts/deploy-app.sh`
- `README.md`
