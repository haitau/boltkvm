# boltkvm 项目架构与工程红线

> 项目完整背景、边界与演进阶段以 `docs/design/project-charter.md` 为单一真相源（SSOT）。本规则只钉死编码、架构与仓库协作红线，不复制设计论证。

## 1. 技术栈与实现红线

- **唯一实现语言**：全 Swift（Swift Package Manager / Xcode）。私有 ObjC 接口 `CGVirtualDisplay` 通过 bridging header 暴露，严禁引入 Rust / C++ 等跨语言 FFI 桥接层。
- **核心管线固定**：
  - **显示层**：无头被控端使用 `CGVirtualDisplay`（优先复用开源 `vdscreen` 或内置同等逻辑）暴露 `3008×1692 @ 60Hz HiDPI`；
  - **采集与编解码**：`ScreenCaptureKit` 采集 + `VideoToolbox` HEVC 硬件低延迟编解码（`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`）；
  - **传输层**：基于 Thunderbolt Bridge（`bridge0`）直连的 `TCP_NODELAY` 或 UDP/QUIC + 轻量分帧；**严禁引入 WebRTC / libwebrtc**；
  - **呈现层**：主控端 `Metal` 1:1 像素级上屏，严禁触发客户端二次非整数重采样导致发糊；
  - **输入层**：主控端 `CGEventTap` 捕获 + 被控端 `CGEvent` 注入。

## 2. 严禁实现的冗余功能（YAGNI）

- **不碰音频**：传输链路不含任何音轨，不采集、不传输、不切换系统默认输出、不占麦克风（被控端声音由本机物理输出）。
- **不写单写者令牌与心跳仲裁**：被控机（Mac mini）始终无头且无本地键鼠，主控机（MacBook）绝不运行被控端服务，从拓扑上根除控制回环。
- **不做公网与跨网段穿透**：仅面向雷雳直连点对点场景，不做账号体系、中继或 NAT 穿透。
- **不新增硬件假设**：严禁围绕采集卡或物理切换器编写逻辑。
- **不让 GUI 通道成为自动化的控制面**：被控端常驻任务由 SSH/launchd 管理；GUI 链路故障不得影响自动化任务的运行与恢复。

## 3. 推进与验收纪律

- **里程碑门控（M0 → M1 → M2 → M3）**：必须严格按 `docs/design/project-charter.md` 第 9 节退出条件逐级推进，未通过当前阶段硬指标前，严禁提前编写下一阶段代码。
- **硬验收底线**：`3008×1692 HiDPI` 像素等价（并排截图 diff 验证）、60fps、端到端延迟 `<33ms`（慢动作视频实测）。
- **公开仓保密纪律**：本仓为 PUBLIC，严禁在代码、配置、测试或文档中硬编码私人主机名、内网真实凭证或内部代号。

## 4. 文档与仓库纪律

- **文档分层**：公开设计文档在 `docs/design/`，可复现计划在 `docs/plans/`，决策记录在 `docs/adr/`，验证报告在 `docs/reports/`；`docs/README.md` 是索引。
- **草稿不入库**：原始 agent 对话、任务提示词、`PROGRESS.md`、`BLOCKED.md` 放 `docs/_scratch/` 或仓根，由 `.gitignore` 排除；需要公开时蒸馏成 ADR / plan / report。
- **公开语气**：公开文档写给贡献者，禁止个人语气、内部代号、私人主机名、SSH 别名、内网地址、机器专属安全配置；必要信息用占位符，事实/推断/未核实必须标注。
- **单一真相源**：目标、约束、事实与里程碑以 `docs/design/project-charter.md` 为准；本文件只钉红线。
- **提交边界**：入库 `docs/design/`、`docs/plans/`、`docs/adr/`、`docs/reports/`；不入库 `.agents/skills/`、agent 运行时产物、密钥与渲染配置，具体以 `.gitignore` 为准。
