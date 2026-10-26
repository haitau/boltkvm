# M0 前置验证计划

- 状态：**显示层验证通过**（2026-10-21，实测结果见 [M0 显示层报告](../reports/2026-10-21-m0-display.md)）；M0 整体尚未关闭——真无头拔线复测、睡眠/唤醒恢复、音频可听性与物理延迟基准仍开放，见[报告结论](../reports/2026-10-21-m0-display.md#9-结论)与[未完成事项](open-items.md)

## 1. 前置条件

- 被控端：Apple Silicon Mac mini，安装 Homebrew（`/opt/homebrew/bin/brew`）；
- 主控端：Apple Silicon MacBook Pro，可通过 SSH 访问被控端（记为 `<mini-host>`）；
- 两台设备通过雷雳线直连，Thunderbolt Bridge 配置独立子网。

## 2. 验证步骤

### 2.1 记录初始显示状态

```bash
ssh <mini-host> 'system_profiler SPDisplaysDataType'
```

记录被控端当前连接的显示器、主显示器归属、分辨率与刷新率。

### 2.2 验证虚拟显示创建（3008×1692 HiDPI）

早期验证使用开源 `vdscreen`（后续已在阶段 1 内建为 `CVirtualDisplay` 模块）：

```bash
ssh <mini-host> 'eval "$(/opt/homebrew/bin/brew shellenv)" && vdscreen on 3008x1692 && vdscreen status'
```

验收标准：

- `system_profiler SPDisplaysDataType` 显示逻辑分辨率 `3008 × 1692 @ 60.00Hz`、背板像素 `6016 × 3384`（HiDPI）；
- 连续运行 10 分钟不掉线；
- 执行 `off` 与 `on` 可正常销毁与恢复。

### 2.3 捕获面像素尺寸探针

在被控端 GUI 会话内编译并运行 [`tools/probe-capture.swift`](../../tools/probe-capture.swift)，枚举 `SCDisplay` 并抓取单帧 PNG：

```bash
xcrun swiftc -O -parse-as-library tools/probe-capture.swift -o /tmp/probe-capture
/tmp/probe-capture /tmp/probe-capture.png
```

验收标准：

- 明确 `SCDisplay` 报告的逻辑尺寸（points）与 `SCScreenshotManager` 抓出的真实背板像素尺寸（`6016×3384`）；
- 确认截图中菜单栏文字锐利，无二次缩放发虚。

### 2.4 雷雳网桥吞吐与救援通道检查

```bash
ping -c 10 <mini-bridge-ip>
/usr/bin/python3 tools/netbench.py client <mini-bridge-ip> 5201 4096
ssh <mini-host> 'launchctl print system | grep -i screensharing'
```

验收标准：

- 雷雳网桥 RTT < 1 ms，裸 TCP 吞吐远高于视频码率需求；
- 系统 Screen Sharing（VNC 5900 端口）处于可用状态，可作为带外救援通道。
