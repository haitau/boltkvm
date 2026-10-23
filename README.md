# boltkvm

两台 macOS 设备之间的低延迟屏幕控制工具。一个 app，两个角色：**被控端**（共享自己的屏幕，
可以是一台没有显示器的 Mac）和**主控端**（在窗口里操作对方的屏幕）。优先走雷雳
（Thunderbolt Bridge）直连：没有交换机、没有 Wi-Fi，链路开销接近背板总线。

它不做 SaaS 远程桌面：没有中继、没有账号、没有云端。两台机器拿着同一个连接密码就能连，
不外网也一样用。

## 核心目标

- **像素等价**：按被控端的真实像素尺寸 1:1 上屏，主控端不做二次缩放，文字不发糊。
- **低延迟交互**：端到端（输入到上屏）以 33 ms 为产品 SLO，按帧大小分档告警。
- **音频不打扰**：默认不传音频，不劫持主控端系统输出；需要时再开。
- **单向无回环**：主控端只捕获输入与渲染，被控端只采集屏幕与注入输入，拓扑上不可能形成
  两台机器互相控制的死循环。

## 实测（2026-10-23）

| 指标 | 目标 | 实测 | 结论 |
|---|---|---|---|
| 像素等价 | SSIM > 0.98 | SSIM 0.984 | 达标 |
| 解码吞吐 | 60 fps | **57.6–58.0 fps** | 达标 |
| 采集→解码延迟 | P95 < 33 ms | P95 **25.4–27.0 ms** | 达标（20 个窗口全部命中 SLO33） |
| GUI 端到端 | P95 < 33 ms | P50 39–40 ms、P95 40–42 ms（帧间隔采样，含呈现管线） | **未达标**，见 [B5](docs/reports/2026-10-23-b5-latency.md) |
| 稳定性 | 8 小时不断连 | 8h00m01s：0 断连、0 解码失败、0 看门狗重建 | 达标 |
| 音频 | 默认零字节 | 默认不传；开启后 1.54 Mbps、−34 dBFS，12 分钟 RSS 134→135 MB | 达标（可选） |
| 输入连续性 | 长时间可用 | 长稳期间无人操作，只验证了 tap 存活 | 未验证 |

解码链路能进 33 ms，但 app 的呈现管线（MTKView 呈现 + 合成器）还多约 14 ms，所以 GUI 的
端到端延迟是 40 ms 量级。两条路径分开统计，别混着看：报告
[B5 延迟](docs/reports/2026-10-23-b5-latency.md)、
[音频与 GUI 稳定性](docs/reports/2026-10-23-audio-and-gui-stability.md)。

## 架构

```text
[被控端]                                          [主控端]
虚拟显示（默认 3008×1692 逻辑 @2x → 6016×3384 像素，可配）
        │
ScreenCaptureKit 采集
        │
VideoToolbox 硬编（ProRes 422 / HEVC）── TCP ──► VideoToolbox 硬解
                                (雷雳桥直连)              │
CGEvent 注入              ◄── 输入与音频 ──────── CGEvent/NSEvent 捕获 + Metal 1:1 上屏
```

- 传输层是裸 TCP + 20 字节大端头（`TCP_NODELAY`）；认证后整条链路 ChaCha20-Poly1305 加密；
- 默认编码 ProRes 422（[ADR-0003](docs/adr/0003-prores-422-primary.md)），`--codec hevc` 可切；
- UDP / QUIC 未实现（[ADR](docs/adr/)）。

## app（推荐用法）

```bash
./Packaging/build-app.sh    # 产出 dist/BoltKVM.app
open dist/BoltKVM.app       # 首次启动选角色，之后菜单「角色」随时切换
```

一个 bundle，两种角色：

**被控端**（菜单栏常驻，没有主窗口）

- 面板显示：分辨率、画面质量、端口、连接密码与指纹、服务状态；可打开权限设置、看日志；
- 采集由 bundle 内的 `boltkvm-server` 子进程完成——GUI 进程自己建虚拟显示不稳定，子进程可以；
- 子进程异常退出 3 秒后自动拉起；
- 「重新生成密码…」会换一把新口令并重启服务，旧密码立即失效。

**主控端**（一个窗口）

- 启动是每台被控端一行的列表，双击连接；「编辑」里配名称、主机、端口、分辨率、连接密码、
  是否转发键鼠/音频；
- 连接后画面填满窗口，窗口比例跟着远端走（16:9 的远端不会留黑边）；
- 工具栏正中是「调度中心」和「桌面」两个远端动作，右侧实时显示 `fps · Mbps`；全屏时自动
  隐藏，鼠标移到顶部才出现（和系统屏幕共享一致）；
- 关掉窗口就是断开连接。

界面中英双语，跟随系统语言（`Packaging/Resources/{en,zh-Hans}.lproj/Localizable.strings`，
代码里没有硬编码文案）。

## 权限

| 角色 | 需要 | 为什么 |
|---|---|---|
| 被控端 | 屏幕录制 | ScreenCaptureKit 采集；缺了服务起不来 |
| 被控端 | 辅助功能 | 把键鼠注入系统；缺了只告警，画面照常 |
| 主控端 | 无 TCC | 键鼠用窗口内本地事件监听，只有指针在画面上时才转发；连接时系统会弹「本地网络」提示，允许即可 |

`Info.plist` 里的 `NSLocalNetworkUsageDescription` 是硬要求：macOS 15 起连内网地址属于
「本地网络」权限，缺了直接 `No route to host`。

签名：ad-hoc（默认 `-`）每次构建 cdhash 都变，TCC 会当成新 app，权限要重新给。想稳定：

```bash
./scripts/make-signing-identity.sh                                  # 生成并信任 "BoltKVM Local"
BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local" ./Packaging/build-app.sh   # 之后都这样构建
```

图标由 `swift scripts/make-icon.swift Packaging/AppIcon.icns` 生成，仓库不放二进制素材。

## 快速开始

### 1. 构建并安装

```bash
swift build -c release
./Packaging/build-app.sh
```

把 `dist/BoltKVM.app` 拷到两台机器。被控端想脚本化部署：`scripts/deploy-app.sh <被控端地址>`
（装到 `/Applications`、停掉旧的 CLI 守护、启动 app）。

### 2. 被控端：选角色、给权限

首次打开选「被控端」。面板会提示缺哪项权限，点按钮跳到系统设置授予，然后重开 app。

被控端首次启动会自动生成 **8 位连接密码**，写进 `~/.boltkvm-key`（0600），面板底部显示：

```
连接密码 abcdefgh（主控端填一次即可） 指纹 E0AF 9869 0698 8829
```

### 3. 主控端：选角色、填一次密码

首次打开选「主控端」，点「添加被控端」建一条：名称随意、主机填被控端的雷雳地址、端口默认
7474、连接密码粘贴上面那 8 位。

- 口令是 **8 位、小写字母 + 数字**（去掉 `0/o/1/l/i`，没有连字符），输入时大小写、空格、
  连字符都会被忽略；被控端面板有「复制连接密码」；
- 8 位约 40 位熵，所以生成后先经 PBKDF2-SHA256（12 万次）拉伸成 32 字节再当密钥；
- 两端指纹（SHA-256 前 8 字节）一致就说明口令一致；
- 密码按台存进 `~/Library/Application Support/BoltKVM/keys/`（0600），不是钥匙串——钥匙串在
  重签名后会弹"想使用您储存的密钥"，把界面卡住。

**用字面 IP，不要用主机名**：本机代理可能把主机名解析成 fake-ip，TCP 建连后立刻被 RST。

### 4. 连接

双击列表项或按「连接」。换分辨率/画质在编辑面板里改，下一帧生效（服务端重建虚拟屏并重启
服务约 2 秒）。

## CLI（无 GUI、脚本化、长跑验收）

`boltkvm` 是同一份核心逻辑的命令行入口，app 只是它的外壳。

```bash
# 被控端
boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# 主控端
boltkvm client --host <被控端地址> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect

# 自测（不需要任何权限，CI 也跑这两个）
boltkvm selftest      # 协议编解码、边界
boltkvm cryptotest    # 加密往返 + 篡改检测
boltkvm displays      # 当前显示：active/awake/Main、像素与逻辑尺寸
boltkvm keygen        # 打印/生成连接密码与指纹
```

服务端参数要点：

```bash
--virtual-display builtin          # 自己创建虚拟屏（默认）；external 用现成的
--virtual-display-size 3008x1692   # 逻辑尺寸；app 里的「清晰」= 2× 逻辑尺寸
--bind auto                        # 默认只监听雷雳桥地址；同机测试用 127.0.0.1
--audio                            # 转发音频（48 kHz 立体声，约 1.5 Mbps）
--codec hevc                       # 默认 prores422
```

客户端每 60 秒输出三行：`render.win`（fps/p50/p95）、`input.win`（事件数/tap 失效次数）、
`loop.win`（包数/重连/Mbps），退出时输出 `SLO33 windows hit=N/M`。

长跑配套脚本：

```bash
scripts/soak-preflight.sh --host <地址>       # 起跑自检：caffeinate、电源断言、TCP、残留进程
scripts/soak-monitor.sh --client-log <日志>   # 5 分钟粒度采样到 monitor.tsv
scripts/rescue.sh --host <地址>               # 三条救援通道体检（ssh / vnc / boltkvm）
```

## 发布

打 tag 即发布，构建与打包由 GitHub Actions 完成：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

产物是 zip + sha256，附在 Release 上。为什么不做公证、安装时要右键打开，见
[发布流程](docs/releasing.md)。

## 故障恢复（被控端重启后）

```
reboot ──► ssh 可用 ──► 自动登录进桌面会话
                            ├─ 登录项 BoltKVM.app 自动启动
                            ├─ app 拉起 boltkvm-server，建虚拟屏并监听
                            └─ 若停在锁屏 → 屏幕共享 vnc://<地址> 解锁
```

- 一条命令体检三条通道：`scripts/rescue.sh --host <地址>`；
- 服务端由 app 守护，**不要用 launchd 直接托管 CLI**：屏幕录制的 TCC 记在责任进程名下，
  LaunchAgent 启动会报 `Screen Recording permission missing`；
- 解锁走系统屏幕共享，不依赖 boltkvm 自己。

## 已知限制

- **GUI 端到端约 40 ms**：解码路径能进 33 ms，但呈现管线多约 14 ms；想压下去要换呈现方式，
  见 [B5](docs/reports/2026-10-23-b5-latency.md)。
- **认证只有预共享口令，没有前向保密**：口令泄露等于机器泄露；`--insecure` 是明文逃生口，
  会打警告。
- **只能有一块虚拟屏**：两块同时在线时 ScreenCaptureKit 会掉到 3–8 fps。`boltkvm displays`
  检查，看到两块就杀掉旧进程。
- **残留服务端会让采集静默挂死**：`startCapture()` 不返回也不报错，客户端只收到心跳；起跑前
  `pkill -f 'boltkvm server'`。
- **锁屏会掐输入 tap**：secure input 下系统禁用会话级 tap；CLI `--input` 期间本机键鼠被吞掉，
  只有 ⌃⌥⌘Q 能退出（app 只在指针位于画面时转发，不受影响）。
- **显示器休眠会断采集**：服务端已加唤醒重试，仍建议被控端常驻 `caffeinate -disu`。
- **跨机更新二进制可能被 AMFI 杀掉**：启动即 137、无输出，就跑一次
  `codesign --force -s - ~/boltkvm`。
- **未验证**：睡眠唤醒、雷雳拔插、锁屏解锁后的注入、长时间持续输入、多显示器。

## 里程碑

细节与验收指标见[设计文档](docs/design/project-charter.md)。

- [x] **M0 前置验证**：显示层与雷雳链路（[报告](docs/reports/2026-10-21-m0-display.md)）
- [x] **M1 视觉等价**：采集 → 硬编 → 直传 → 硬解 → Metal 1:1（60 fps、P95 27.6 ms、SSIM 0.984）
- [x] **M2 输入链路**：系统级快捷键、修饰键、滚动相位注入（⌘Tab/⌘Space/文字/点击/滚动已验）
- [x] **M3 稳定性**：虚拟显示看门狗、TCC 自检、断线重连、8 小时长稳（0 断连）
- [x] **应用化**：单 bundle 双角色、连接管理、虚拟屏内建、音频可选、自动发布

## 文档

- [设计文档](docs/design/project-charter.md)：目标、约束、已验证事实、方案空间
- [未完成事项](docs/plans/open-items.md)：按优先级列的缺口与技术债
- [发布流程](docs/releasing.md)：tag → Release，以及公证为什么做不了
- [连接管理器设计](docs/plans/2026-10-22-connection-manager-design.md)
- [延迟分析 B5](docs/reports/2026-10-23-b5-latency.md)
- [音频与 GUI 稳定性](docs/reports/2026-10-23-audio-and-gui-stability.md)
- [传输加密](docs/reports/2026-10-22-transport-encryption.md)
- [8 小时长稳](docs/reports/2026-10-22-m3-soak-8h.md)
- [架构决策记录](docs/adr/)、[全部报告](docs/reports/)、[计划](docs/plans/)

## 环境要求

- macOS 15+，Apple Silicon；
- 两台机器之间的雷雳连接（雷雳网桥），或任意可达的 IP 网络（`--bind 0.0.0.0`，不推荐）；
- Swift 6 / Xcode Command Line Tools（只有从源码构建才需要，装 release 的用户不需要）；
- 被控端：屏幕录制（必需）、辅助功能（输入注入）。

## 贡献

提交前读 [AGENTS.md](AGENTS.md)：完成一个可交付的变更就 commit，push 需显式声明；提交要能
独立编译、带验证、文档同提交。

## License

[MIT](LICENSE)
