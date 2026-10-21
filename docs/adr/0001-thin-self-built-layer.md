# ADR 0001：以自研薄层作为主路径

- 状态：已接受
- 日期：2026-10-21

## 背景

项目要求在主控端 4K 显示器上，以 3008×1692 HiDPI 像素等价、< 33ms、音频完全隔离、单向控制的方式操作无头被控端，且现成工具必须免费、离线、无需账号。

已评估的现成方案：

- macOS 高性能屏幕共享：分辨率上限 4K / 1080p HiDPI，音频回传主控端；
- Sunshine / Moonlight：macOS 宿主成熟度低，客户端 HiDPI 二次重采样（moonlight-qt #1185）；
- Deskflow：只传键鼠，不传视频；按屏幕边缘切换，与“远程画面是窗口”不匹配；
- RustDesk：可直连，但客户端 Retina 缩放大概率同属二次重采样；
- 付费工具（Jump Desktop、Parsec）：违反“完全免费”约束。

## 决策

采用自研薄层作为主路径：

- 显示：`CGVirtualDisplay`（优先复用开源 `vdscreen`）；
- 采集：ScreenCaptureKit；
- 编码：VideoToolbox HEVC 低延迟；
- 传输：Thunderbolt Bridge 上的 TCP（`TCP_NODELAY`）或 UDP/QUIC，不引入 WebRTC；
- 呈现：Metal，1:1 上屏；
- 输入：CGEventTap（主控端）+ CGEvent（被控端）；
- 语言：Swift。

## 后果

正面：

- 可以控制像素路径、音频隔离、输入注入与延迟预算；
- 不依赖付费或云服务；
- 具备开源产品化的基础。

负面：

- 需要周级业余时间；
- 依赖 `CGVirtualDisplay` 私有 API 与 TCC 权限，macOS 升级可能返工；
- 开源分发只能走源码构建/自签，无法进 App Store。

## 备选

- 若自研在 6 周评审时未达 MVP，回退到现成方案 + 4K 降级；
- 若显示层无法成立，项目暂停，重新评估 4K 原生或物理方案。
