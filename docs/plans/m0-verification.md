# M0 前置验证计划

> 状态：草稿，未执行。目标是在投入视频管线之前，证明无头被控端能提供并采集 3008×1692 HiDPI 虚拟显示，并为 α′ / β 像素路径提供实测依据。

## 前置条件

- 被控端：Apple silicon Mac mini，macOS 27，Homebrew 位于 `/opt/homebrew/bin/brew`；
- 主控端：Apple silicon MacBook Pro，macOS 27，可通过 SSH 访问被控端（下文记为 `<mini-host>`）；
- 两台机器通过雷雳 5 直连，Thunderbolt Bridge 已配置独立子网；
- 目标运行状态为无头；开发机可能临时连接显示器用于配置，验证时需记录该状态。

## 步骤

### 1. 记录当前显示状态

```bash
ssh <mini-host> 'system_profiler SPDisplaysDataType'
```

记录被控端当前是否有物理显示器、主显示器、分辨率、刷新率。开发机若临时接了显示器，不要拔线；在报告中标注该干扰。

### 2. 安装开源虚拟显示实现

被控端已有 Homebrew，但非交互 SSH 不会加载 `.zprofile`，需显式初始化环境：

```bash
ssh <mini-host> 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew tap lyonDan/tap && brew install --cask lyonDan/tap/vdscreen'
```

安装后确认 CLI：

```bash
ssh <mini-host> 'eval "$(/opt/homebrew/bin/brew shellenv)" && command -v vdscreen && vdscreen --help'
```

若 cask 安装失败，按 `vdscreen` README 从源码构建；仍失败则用 Swift + `CGVirtualDisplay` 写最小探针（参考 `KhaosT/CGVirtualDisplay`）。

### 3. 创建虚拟显示

```bash
ssh <mini-host> 'eval "$(/opt/homebrew/bin/brew shellenv)" && vdscreen on 3008x1692 && vdscreen status'
```

验收：

- `system_profiler SPDisplaysDataType` 出现 3008×1692，HiDPI/“UI Looks like”标记正确；
- 刷新率 60Hz；
- 连续 10 分钟不消失。

反向验证：`vdscreen off` 后虚拟显示消失，再 `on` 恢复；两次输出都记录。

### 4. 捕获面探针

写一个最小 Swift 程序，用 ScreenCaptureKit 枚举显示，打印 `SCDisplay` 的 `width`/`height`，并抓一帧打印实际像素尺寸；必须在被控端运行。

验收：

- 捕获宽高明确（3840×2160 或 6016×3384）；
- 与步骤 3 的虚拟显示尺寸对照；
- 同一程序枚举物理显示器时尺寸不同，排除硬编码。

### 5. 链路与救援

```bash
ping -c 10 <mini-bridge-ip>
dd if=/dev/zero bs=1m count=512 2>/dev/null | ssh <mini-host> 'cat > /dev/null'
ssh <mini-host> 'launchctl print system | grep -i screensharing'
```

记录 RTT、SSH 管道吞吐（下限，不是裸链路）与 Screen Sharing 状态。重启后、登录前测试一次 VNC 连接，确认 GUI 救援通道可用。

## 验收条件

1. 被控端存在 3008×1692 HiDPI @ 60Hz 虚拟显示，连续 10 分钟不消失；
2. 捕获面有实测宽高（3840×2160 或 6016×3384），并据此给出 α′ / β 初判；
3. 记录本地直连显示器的 glass-to-glass 延迟基准；
4. 记录音频输出是否在可听范围内。

## 失败处理

- 虚拟显示创建失败：按 cask → 源码构建 → Swift + `CGVirtualDisplay` 探针逐级回退；全部失败则记录原始错误，暂停后续管线。
- 捕获面与预期不符：以实测为准重定 α′ / β，不按假设继续。
- TCC/VNC 救援不可用：先解决预登录救援，再进入 M1。
- 同一路径连续失败 3 次：停止，记录证据，不自行切换方案。

## 已知坑

- 非交互 SSH 不加载 `.zprofile`，`command -v brew` 会误报缺失；必须用绝对路径或 `zsh -lic`。
- 无头运行依赖已登录的 GUI 会话；关闭 FileVault + 自动登录有物理安全代价，需配合可信环境、固件密码与物理锁。
- 开发机临时物理显示器会影响捕获面与显示模式判断，报告中必须标注。
