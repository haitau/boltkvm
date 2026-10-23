# BoltKVM

**简体中文** | [English](README_EN.md)

两台 macOS 设备之间的低延迟屏幕控制工具。一个应用包含两种角色：**被控端**（共享屏幕，支持无显示器的无头 Mac）和**主控端**（在窗口或全屏中操作对端屏幕）。推荐通过雷雳网桥（Thunderbolt Bridge）直连，无需中继、账号或外网连接，两端凭同一个连接密码即可完成认证与加密通信。

## 核心指标

- **像素等价**：支持按被控端虚拟屏真实像素（2× backing）传输与渲染，文字清晰不发糊。
- **低延迟交互**：解码链路（采集→解码）P95 < 33 ms；GUI 呈现（采集→上屏，不含输入反向上行）P95 < 50 ms。
- **音频隔离**：默认不采集、不传输音频，不改动主控端系统输出设备；按需开启。
- **单向控制**：主控端仅捕获输入与渲染画面，被控端仅采集屏幕与注入输入，从拓扑上避免双向互控回环。

## 实测结果（2026-10-23）

| 指标 | 目标 | 实测 | 结论 |
|---|---|---|---|
| 像素等价 | SSIM > 0.98 | SSIM 0.984 | 达标 |
| 解码吞吐 | 60 fps | **57.6–58.0 fps** | 达标 |
| 解码链路延迟 | P95 < 33 ms | P95 **25.4–27.0 ms** | 达标（20 个窗口全部命中 33 ms 预算） |
| GUI 采集→上屏延迟 | P95 < 50 ms | P50 **31.0 ms**、P95 **33.2 ms**、60.0 fps | 达标（详见 [B5 延迟报告](docs/reports/2026-10-23-b5-latency.md)） |
| 稳定性 | 8 小时不断连 | 8h00m01s：0 断连、0 解码失败、0 看门狗重建 | 达标 |
| 音频 | 默认零字节 | 默认不传；开启后 1.54 Mbps、−34 dBFS，12 分钟 RSS 134→135 MB | 达标（可选） |
| 输入连续性 | 8 小时不丢事件 | 8h 内 466 次转发、tap 失效 0（CLI 客户端；GUI 客户端未做 8h 长跑） | 部分达标 |

解码链路与 GUI 呈现链路分开统计：解码链路 P95 在 27 ms 以内；GUI 渲染采用到帧即时触发 `MTKView.draw()` 的泵送模式，消除了等待显示刷新周期的排队开销，采集→上屏 P95 为 33.2 ms。详见 [B5 延迟报告](docs/reports/2026-10-23-b5-latency.md) 与 [音频与 GUI 稳定性报告](docs/reports/2026-10-23-audio-and-gui-stability.md)。

## 架构

```text
[被控端]                                          [主控端]
虚拟显示（默认 3008×1692 逻辑 @2x → 6016×3384 像素，可配）
        │
ScreenCaptureKit 采集
        │
VideoToolbox 硬编（ProRes 422 / HEVC）── TCP ──► VideoToolbox 硬解
                                (雷雳桥直连)              │
CGEvent 注入              ◄── 输入与音频 ──────── CGEvent/NSEvent 捕获 + Metal 上屏
```

- **传输与安全**：裸 TCP + 20 字节大端帧头（启用 `TCP_NODELAY`）。挑战-应答认证通过后，双方通过 X25519 交换临时公钥，结合预共享密钥经 HKDF-SHA256 派生会话密钥，全链路使用 ChaCha20-Poly1305 密封（帧头作为 AAD），具备前向保密能力。
- **视频编码**：默认使用 ProRes 422（[ADR-0003](docs/adr/0003-prores-422-primary.md)），可通过 `--codec hevc` 切换为 HEVC。

## 应用模式（推荐）

```bash
./Packaging/build-app.sh    # 编译 release 并组装 dist/BoltKVM.app
open dist/BoltKVM.app       # 首次启动选择角色，后续可在顶部菜单「角色」中切换
```

单个应用包支持两种运行角色：

**被控端**（菜单栏常驻，无主窗口）

- 设置面板显示分辨率、画面质量、端口、连接密码与指纹、服务状态，并提供权限设置与日志入口；
- 屏幕采集与虚拟屏创建由应用包内的 `boltkvm-server` 子进程执行，子进程异常退出后 3 秒自动重启；
- 点击「重新生成密码…」会生成新口令并重启服务，旧密码立即失效。

**主控端**（单窗口）

- 启动后显示被控端列表，双击即可连接；点击「编辑」可按主机配置名称、地址、端口、分辨率、连接密码及键鼠/音频开关；
- 连接后窗口长宽比自动匹配远端画面；
- 工具栏居中提供「调度中心」与「桌面」两个远端系统操作，最右侧实时显示 `fps · Mbps`；全屏下工具栏自动隐藏，指针移至屏幕顶边时浮现；
- 关闭视频窗口即断开连接并返回主机列表；
- 仅当鼠标指针位于画面区域内时转发键鼠事件。指针移出画面、窗口失焦或连接断开时，已按下的按键与鼠标键会自动抬起；每次按键注入前也会按事件携带的修饰键掩码对齐远端状态，防止修饰键卡死。

界面支持中英双语，自动跟随系统语言（词表位于 `Packaging/Resources/{en,zh-Hans}.lproj/Localizable.strings`）。

## 权限要求

| 角色 | 所需权限 | 用途 |
|---|---|---|
| 被控端 | 屏幕录制 | ScreenCaptureKit 采集屏幕，缺失时无法启动服务 |
| 被控端 | 辅助功能 | CGEvent 注入键鼠事件，缺失时仅可看画面、无法控制 |
| 主控端 | 本地网络（macOS 15+） | 访问雷雳网桥或局域网地址；缺失时系统直接返回 `No route to host` |

主控端应用使用窗口内 `NSEvent` 本地监听捕获键鼠，无需申请「输入监控」权限（仅 CLI 全屏 `--input` 模式使用 `CGEventTap` 时需要输入监控权限）。

默认打包使用 ad-hoc 签名（`-`），每次重编译都会改变二进制 `cdhash`，导致 macOS TCC 将其视为新应用并要求重新授权。日常开发建议生成并信任本地自签名证书：

```bash
./scripts/make-signing-identity.sh                                  # 生成并信任 "BoltKVM Local"
BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local" ./Packaging/build-app.sh
```

应用图标由 `swift scripts/make-icon.swift Packaging/AppIcon.icns` 生成。

## 快速开始

### 1. 构建与部署

```bash
./Packaging/build-app.sh
```

将生成的 `dist/BoltKVM.app` 拷贝到两台 Mac 的 `/Applications`。若被控端已配置 SSH，可执行 `./scripts/deploy-app.sh <被控端地址>` 自动完成打包、上传、停旧进程与启动。

### 2. 配置被控端

首次打开选择「作为被控端」，按面板提示授予「屏幕录制」与「辅助功能」权限后重开应用。

首次启动会在 `~/.boltkvm-key`（权限 0600）自动生成 8 位连接密码，并在面板底部展示：

```text
连接密码 abcdefgh（主控端填一次即可） 指纹 E0AF 9869 0698 8829
```

要在被控端应用模式下开启音频转发，可在被控端执行：

```bash
defaults write io.github.boltkvm server.audio -bool true
```

然后在菜单栏停止再启动服务即可生效。

### 3. 配置主控端

首次打开选择「作为主控端」，点击「添加被控端」填写名称、被控端雷雳网桥 IP、端口（默认 7474）及上述 8 位连接密码。

- **8 位连接密码**：由小写字母与数字组成（剔除易混淆的 `0/o/1/l/i`），输入时自动忽略大小写、空格与连字符；通过 PBKDF2-SHA256（12 万次迭代）拉伸为 32 字节密钥；
- **256 位静态密钥**：对安全性要求更高时，可在被控端面板点击「256 位密钥…」生成 64 位十六进制随机密钥，整段复制粘贴到主控端密码栏即可；
- **指纹核对**：两端显示的 16 位十六进制指纹（SHA-256 前 8 字节）一致即表示密钥匹配；
- **凭据存储**：主控端密码按主机保存在 `~/Library/Application Support/BoltKVM/keys/`（权限 0600），不经过系统钥匙串，避免重签名后频繁弹出钥匙串授权框。

**注意**：连接地址请填写雷雳网桥的字面 IP，不要填主机名（本机代理软件可能将主机名劫持为 fake-ip 导致连接被重置）。

### 4. 建立连接

双击列表中的被控端或点击「连接」。在主机编辑面板修改分辨率后，下次连接时服务端会自动按新尺寸重建虚拟屏；画面质量（「标准」限制最大宽度 3840，「清晰」按 2× 真实像素传输）在被控端菜单栏或设置面板中切换。

## 命令行工具（CLI）

`boltkvm` 提供与 GUI 共用核心库的命令行入口，适用于脚本化验证与长跑测试：

```bash
# 启动被控端服务
.build/release/boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# 启动主控端（全屏渲染 + 键鼠转发 + 自动重连）
.build/release/boltkvm client --host <被控端地址> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect

# 运行测试套件（含 49 个 XCTest 单元测试；仅装 CLT 的机器会自动回退到 CLI 自测）
./scripts/test.sh

# 协议与加密自测（无需任何系统权限）
.build/release/boltkvm selftest
.build/release/boltkvm cryptotest

# 本地诊断工具
.build/release/boltkvm displays      # 查看当前显示器状态、逻辑与像素尺寸
.build/release/boltkvm doctor        # 检查 TCC 权限状态
.build/release/boltkvm keygen        # 生成连接密码并打印指纹
```

常用服务端参数：

```bash
--virtual-display builtin          # 内建虚拟屏（默认）；external 使用外部已有显示器
--virtual-display-size 3008x1692   # 虚拟屏逻辑尺寸
--bind auto                        # 默认仅绑定 bridge* 雷雳接口；本机回环测试传 127.0.0.1
--audio                            # 开启系统音频采集与转发（48 kHz 双声道 PCM，约 1.5 Mbps）
--codec hevc                       # 切换编码器为 HEVC（默认 prores）
```

长跑辅助脚本：

```bash
./scripts/soak-preflight.sh --host <地址>       # 起跑前检查 caffeinate、电源断言、端口与残留进程
./scripts/soak-monitor.sh --client-log <日志>   # 每 5 分钟采样客户端存活与延迟指标到 monitor.tsv
./scripts/rescue.sh --host <地址>               # 检查 SSH / VNC / BoltKVM 三条通道连通性
```

## 发布流程

推送 `v*` 标签即可触发 GitHub Actions 自动编译、自测、打包签名并创建 GitHub Release：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

签名与公证机制说明见 [发布流程](docs/releasing.md)。

## 故障恢复（被控端重启后）

```text
重启 ──► SSH 就绪 ──► 自动登录进入桌面会话
                          ├─ 登录项启动 BoltKVM.app
                          ├─ 应用拉起 boltkvm-server，创建虚拟屏并监听端口
                          └─ 若停留在锁屏界面 → 通过系统屏幕共享 vnc://<地址> 解锁
```

- 执行 `./scripts/rescue.sh --host <地址>` 可一键检查 SSH（22）、VNC（5900）与 BoltKVM（7474）三条通道；
- 请通过 `BoltKVM.app` 的「开机自动启动」托管服务端，不要用 `launchd` 直接运行 CLI 二进制（`launchd` 无 GUI 责任进程身份，无法获取屏幕录制权限）。

## 已知限制

- **预共享口令权限**：持有口令即可主动连接并控制被控端（历史录制的加密流量受 X25519 前向保密保护无法解密）；口令泄露时请在被控端面板点击「重新生成密码…」。技术取舍见 [ADR-0004](docs/adr/0004-psk-over-pairing-code.md)。
- **单虚拟屏限制**：同时存在两块高分虚拟屏会导致 ScreenCaptureKit 采集帧率跌至 3–8 fps。若帧率异常，请用 `boltkvm displays` 检查并清理多余的虚拟屏进程。
- **残留进程冲突**：手动运行 CLI 前需确认无残留 `boltkvm server` 进程，否则新建 `SCStream` 可能挂起。
- **安全输入与锁屏限制**：系统处于锁屏或密码输入框（Secure Input）状态时，会话级事件监听会被系统拦截；锁屏解锁请使用系统自带的屏幕共享（VNC）。
- **不支持多显示器同传**：被控端仅创建并采集一块虚拟屏。

## 里程碑

详细背景与指标定义见 [项目设计文档](docs/design/project-charter.md)。

- [x] **M0 前置验证**：虚拟显示与雷雳链路基线（[报告](docs/reports/2026-10-21-m0-display.md)）
- [x] **M1 视觉等价**：采集 → 硬编 → 直传 → 硬解 → Metal 上屏（60 fps、SSIM 0.984，[报告](docs/reports/2026-10-21-m1-pipeline.md)）
- [x] **M2 输入链路**：快捷键、修饰键同步、连续滚动相位注入（[报告](docs/reports/2026-10-21-m2-input.md)）
- [x] **M3 稳定性**：权限自检、断线重连、8 小时长稳与输入连续性验证（[报告](docs/reports/2026-10-22-m3-soak-8h.md)）
- [x] **应用化**：单应用双角色、内建虚拟显示、多主机连接管理、可选音频、自动发布（[报告](docs/reports/2026-10-22-app-conversion.md)）

## 文档索引

- [项目设计文档](docs/design/project-charter.md)
- [未完成事项](docs/plans/open-items.md)
- [发布流程](docs/releasing.md)
- [连接管理器设计](docs/plans/2026-10-22-connection-manager-design.md)
- [B5 帧率与延迟报告](docs/reports/2026-10-23-b5-latency.md)
- [音频与 GUI 稳定性报告](docs/reports/2026-10-23-audio-and-gui-stability.md)
- [传输加密报告](docs/reports/2026-10-22-transport-encryption.md)
- [架构决策记录（ADR）](docs/adr/)、[全部验证报告](docs/reports/)、[实施计划](docs/plans/)

## 环境要求

- macOS 15+（Apple Silicon）；
- 雷雳网桥（Thunderbolt Bridge）直连，或任意可达的局域网 IP 连接；
- 从源码构建需安装 Swift 6 / Xcode Command Line Tools。

## 贡献指南

提交代码前请阅读 [AGENTS.md](AGENTS.md)。每个可独立交付的变更单元应确保编译与测试通过，并同步更新相关文档。

## 许可证

[MIT](LICENSE)，第三方代码许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
