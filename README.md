# boltkvm

基于雷雳（Thunderbolt Bridge）直连的 macOS 极低延迟桌面控制工具，面向“主控 MacBook 外接 4K 显示器 + 无头 Mac mini”双机开发场景。

## 核心目标

- **像素等价**：在主控端 4K 显示器上以 `3008×1692 @ 60Hz HiDPI` 操作无头被控端，画面与本地直连逐像素一致，消除客户端 HiDPI 二次重采样导致的文字发糊。
- **低延迟交互**：针对编码、终端、浏览器负载优化，60fps 帧率，端到端（输入到上屏）延迟 `<33ms`。
- **音频零干扰**：控制与视频链路完全剥离音频，不劫持主控端系统默认输出，不交叉占用麦克风。
- **单向无回环**：主控端仅做输入捕获与渲染，无头被控端仅做虚拟显示采集与输入注入，从拓扑上消除双向控制死循环。

## 架构概览（Swift 原生管线）

```text
[被控端 Mac mini (Headless)]                       [主控端 MacBook Pro]
CGVirtualDisplay (3008×1692 HiDPI)                 
        │                                          
ScreenCaptureKit 采集                              
        │                                          
VideoToolbox HEVC 低延迟硬编 ── TCP_NODELAY / UDP ──► VideoToolbox 硬解
                                (Thunderbolt Bridge)        │
CGEvent 输入注入             ◄── 输入事件流 ───────── CGEventTap 捕获 + Metal 1:1 上屏
```

## 里程碑进度

项目按阶段门控推进，详细背景、技术边界与验收指标见 [设计文档](docs/design/project-charter.md)：

- [ ] **M0 前置验证**：无头 `3008×1692 HiDPI` 虚拟显示稳定性、雷雳网桥吞吐/RTT 基线、现成方案最后排除（显示层与链路已验证，见 [报告](docs/reports/2026-10-21-m0-display.md)；真无头/重启/音频待亲验）
- [x] **M1 视觉等价 Spike**：采集 → 硬编 → 雷雳直传 → 硬解 → Metal 1:1 上屏（α′ + ProRes 422：60fps、capture→present P95 27.6ms、SSIM 0.984；glass-to-glass 相机作为后续验证）
- [x] **M2 输入链路**：全屏系统级快捷键截获（`CGEventTap`）、修饰键与连续滚动相位（`CGEvent`）注入（⌘Tab/⌘Space/文字/点击/滚动 phase/退出热键已验证；⌃↑ 受前台 app 冲突，Secure Input/触控板为已知限制）
- [ ] **M3 稳定性加固**：虚拟显示看门狗、TCC 权限自检、睡眠唤醒与断线自愈（看门狗/TCC 医生/服务端与客户端重连/心跳已落地并短测；8 小时长稳待夜间执行）

## 文档

- [设计文档](docs/design/project-charter.md)：目标、约束、已验证事实、方案空间与里程碑
- [M0 前置验证计划](docs/plans/m0-verification.md)
- [M0 显示层验证报告](docs/reports/2026-10-21-m0-display.md)
- [M1 编码可行性探针](docs/reports/2026-10-21-m1-encoder-probe.md)
- [M1 α′ 管线报告](docs/reports/2026-10-21-m1-pipeline.md)
- [M2 输入链路报告](docs/reports/2026-10-21-m2-input.md)
- [M3 稳定性报告](docs/reports/2026-10-21-m3-stability.md)
- [架构决策记录](docs/adr/)
- [验证报告](docs/reports/)

## 环境要求

- macOS 15+（Apple Silicon）
- Thunderbolt 4 / 5 线缆直连（Thunderbolt Bridge）
- Swift 6 / Xcode Command Line Tools

## License

[MIT](LICENSE)
