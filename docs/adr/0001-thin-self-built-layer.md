# ADR 0001：采用自研薄层作为主路径

- 状态：已接受
- 日期：2026-10-21

## 背景

项目需要在主控端显示器上以 3008×1692 HiDPI 像素等价、低延迟、音频默认隔离、单向控制的方式操作无头被控端 Mac，且工具需免费、离线可用、不依赖外部账号。

已评估的现成方案均存在硬伤：

- **macOS 高性能屏幕共享**：分辨率上限为 4K / 1080p HiDPI，不支持 3008×1692 HiDPI，且强制回传音频；
- **Sunshine / Moonlight**：macOS 宿主端支持薄弱，客户端在 HiDPI 缩放下存在二次重采样模糊（`moonlight-qt #1185`）；
- **Deskflow**：仅共享键鼠、不传输画面，按屏幕边缘切换的交互与窗口化远控不兼容；
- **RustDesk**：客户端 Retina 缩放同样存在重采样模糊问题；
- **商业软件（Jump Desktop、Parsec）**：依赖外部账号或付费订阅。

## 决策

基于 Apple 原生框架构建自研薄层：

- **虚拟显示**：`CGVirtualDisplay`（复用开源 `vdscreen` 核心逻辑）；
- **采集**：ScreenCaptureKit；
- **编解码**：VideoToolbox 硬件加速（初始验证 HEVC，后在 [ADR-0003](0003-prores-422-primary.md) 切换主路径为 ProRes 422）；
- **传输**：Thunderbolt Bridge 上的裸 TCP（`TCP_NODELAY`），不引入 WebRTC；
- **呈现**：Metal 等比与 1:1 渲染；
- **输入**：主控端捕获（App 内 `NSEvent` / CLI `CGEventTap`）+ 被控端 `CGEvent` 注入；
- **语言**：Swift + 少量 Objective-C（虚拟显示私有接口桥接）。

## 后果

- **正面**：完全掌控像素路径、音频开关、输入修饰键同步与端到端延迟预算；无账号、无中继依赖。
- **负面**：依赖 `CGVirtualDisplay` 私有接口与 macOS TCC 权限体系，系统大版本升级时需回归验证；因使用私有 API 且不支持 Hardened Runtime，仅能通过 GitHub Releases（ZIP）或源码构建分发，无法上架 App Store。
