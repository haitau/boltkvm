# boltkvm

基于雷雳（Thunderbolt Bridge）直连的 macOS 极低延迟桌面控制工具，面向“主控 MacBook 外接 4K 显示器 + 无头 Mac mini”双机开发场景。

## 核心目标

- **像素等价**：在主控端 4K 显示器上以 1:1 呈现被控端画面，消除客户端 HiDPI 二次重采样导致的文字发糊。
- **低延迟交互**：针对编码、终端、浏览器负载优化，端到端（输入到上屏）SLO `< 33ms`。
- **音频零干扰**：控制与视频链路完全剥离音频，不劫持主控端系统默认输出，不交叉占用麦克风。
- **单向无回环**：主控端仅做输入捕获与渲染，被控端仅做虚拟显示采集与输入注入，从拓扑上消除双向控制死循环。

## 当前实测（2026-10-22）

| 指标 | 目标 | 实测 | 结论 |
|---|---|---|---|
| 像素等价 | 1:1 4K、SSIM > 0.98 | SSIM 0.984 | 达标 |
| 帧率 | 60 fps | 服务端编码 59.9 fps，客户端上屏 **59.5 fps** | 达标（2026-10-22 修 displaySync） |
| 端到端延迟 | P95 < 33 ms | P95 **17.0 ms**，P50 16.7 ms（60s 窗口） | 达标（同上修正） |
| 稳定性 | 连续 8 小时无断连 | 8h00m01s：0 断连、0 解码失败、0 watchdog 重建 | 达标 |
| 音频隔离 | 默认不传音频 | 默认链路零音频字节；`--audio` 可选转发，440 Hz 测试音频率无偏移 | 达标（默认），可选功能可用 |
| 输入连续性 | 8 小时内持续可用 | 长稳期间无人操作，仅验证 tap 存活 | 未验证 |

上屏帧率此前的 51 fps 不是硬件上限，而是客户端 `CAMetalLayer.displaySyncEnabled=false` 导致合成器合并帧；2026-10-22 修正为开启同步后实测 59.5 fps、P95 17.0 ms（60 秒窗口，8 小时长稳待重跑确认）。延迟告警线仍按帧大小分三档（33/40/55 ms），33 ms 作为产品 SLO 单独统计命中率。详见 [present 同步修复](docs/reports/2026-10-22-present-sync-fix.md) 与 [8 小时长稳结论](docs/reports/2026-10-22-m3-soak-8h.md)。

## 架构概览（Swift 原生管线）

```text
[被控端 Mac mini (Headless)]                       [主控端 MacBook Pro]
CGVirtualDisplay (3008×1692 HiDPI)
        │
ScreenCaptureKit 采集（6K 源缩放至 4K）
        │
VideoToolbox ProRes 422 硬编 ── TCP (TCP_NODELAY) ──► VideoToolbox 硬解
                                (Thunderbolt Bridge)        │
CGEvent 输入注入             ◄── 输入事件流 ───────── CGEventTap 捕获 + Metal 1:1 上屏
```

默认编码为 ProRes 422（[ADR-0003](docs/adr/0003-prores-422-primary.md)），服务端可用 `--codec hevc` 切换；传输层目前只有 TCP，UDP/QUIC 未实现。

## 快速开始

### 0. 构建

```bash
swift build -c release        # 产物：.build/release/boltkvm
```

被控端通常把该二进制拷到 `~/boltkvm` 后用 LaunchAgent/watchdog 托管。

### 1. 配对密钥（一次性）

服务端带密钥启动、客户端带同一密钥连接；没有密钥时服务端拒绝启动（`--insecure` 可强制关闭）。

```bash
openssl rand -hex 32 > ~/.boltkvm-key && chmod 600 ~/.boltkvm-key
scp ~/.boltkvm-key <被控端>:~/.boltkvm-key     # 两端各存一份，权限 600
```

密钥也可用 `--key <psk>` 或环境变量 `BOLTKVM_KEY` 传入，优先级 `--key` > 环境变量 > `~/.boltkvm-key`。

### 2. 被控端准备

```bash
# 虚拟显示（vdscreen 或其他 CGVirtualDisplay 实现），确认 3008×1692 HiDPI 生效
vdscreen on 3008x1692

# 保持显示器唤醒：显示休眠时 ScreenCaptureKit 会直接报 "no display"
caffeinate -disu &

# 权限：屏幕录制（必需）、辅助功能（输入注入，缺失只告警）
# 服务端必须从 GUI 会话启动（Terminal.app），不要用 ssh —— TCC 会把责任方记成 sshd
```

### 3. 起服务端（被控端）

```bash
boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0
# 观察：出现 "capture started; waiting for frames" 才算 capture 正常
# 绑定：默认 --bind auto，只监听雷雳桥（bridge*）地址；同机测试用 --bind 127.0.0.1
# 音频：默认不传。需要转发时加 --audio（48 kHz 立体声，约 1.5 Mbps）
# 虚拟屏：默认 external，假定 vdscreen/物理屏已经提供；加 --virtual-display builtin
#         由本进程自己创建（--virtual-display-size 3008x1692 指定逻辑尺寸）
```

### 4. 起客户端（主控端）

```bash
boltkvm client --host <被控端雷雳 IP> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect
  # 需要听被控端声音：加 --audio；只想落盘检查：--audio-record /tmp/a.caf
```

注意用**雷雳网桥的字面 IP**，不要用主机名：本机代理可能把主机名解析成 fake-ip，TCP 建连后立即被 RST。

### 5. 观察与验收

客户端每 60 秒输出三行：`render.win`（fps/p50/p95/档位预算）、`input.win`（输入事件数/tap 失效次数）、`loop.win`（包数/重连数/Mbps/帧大小）。退出时额外输出 `SLO33 windows hit=N/M`。

长跑请配套脚本：

```bash
scripts/soak-preflight.sh --host <IP>        # 起跑自检：caffeinate、pmset 断言、TCP、残留进程
scripts/soak-monitor.sh --client-log <log>   # 5 分钟粒度采样到 monitor.tsv
scripts/rescue.sh --host <IP>                # 三条救援通道体检（ssh / vnc / boltkvm）
```

## 故障恢复（被控端重启后）

```
reboot ──25s──► ssh 可用 ──► 自动登录进桌面会话
                                ├─ vdscreen / watchdog  LaunchAgent 自动拉起
                                ├─ 登录项 soak-start.command → Terminal 里起服务端（守护循环）
                                └─ 若停在锁屏 → 屏幕共享 vnc://<ip> 输入密码解锁
```

- 一条命令体检三条通道：`scripts/rescue.sh --host <ip>`（SSH banner / VNC banner / boltkvm 端口）
- 服务端由 Terminal 里的 `while` 循环守护，被杀后 3 秒内自动重启；**不能用 launchd 直接托管**——Screen Recording 权限记在 Terminal 名下，LaunchAgent 启动会报 `permission missing`
- 解锁走系统屏幕共享，不依赖 boltkvm 自身

## 已知限制与坑

- **认证 + 加密**：预共享密钥 + HMAC-SHA256 挑战应答，握手后整条链路用 ChaCha20-Poly1305 密封（帧头作为 AAD 参与认证）。`--insecure` 是明文逃生口，会打警告；默认只绑雷雳桥，`--bind 0.0.0.0` 会监听所有网卡。密钥仍等于一台机器——没有前向保密。
- **跨机更新二进制后可能被 AMFI 杀掉**：`scp` 过去的新二进制若启动即 137、无任何输出，在被控端跑一次 `codesign --force -s - ~/boltkvm` 即可。
- **残留服务端会让 capture 静默挂死**：`startCapture()` 不返回、不报错，客户端只收到心跳。起跑前必须 `pkill -f 'boltkvm server'`。
- **`--seconds` 只结束会话，不结束进程**：到期后打 `session ended; accepting next client` 继续监听。
- **锁屏会掐输入 tap**：会话级 `CGEventTap` 在 secure input 下被系统禁用，`tapEnable` 无效；`--input` 生效期间本机键鼠被全部吞掉，只有 ⌃⌥⌘Q 能退出。
- **上屏 51 fps 天花板**：4K drawable 下每帧 draw+present 约 19.6 ms，够不到 60 Hz。
- **重启后可能停在锁屏**：自动登录、虚拟显示、看门狗、服务端都能自动恢复（实测 ssh 25 s 回来、服务端自启后直接出帧），但会话可能锁定，解锁走屏幕共享；能否用注入事件在锁屏上打字未验证。
- **服务端不能由 launchd 托管**：Screen Recording 的 TCC 归属是 Terminal，LaunchAgent 直接跑二进制会报 `Screen Recording permission missing`（实测），只能由登录项经 Terminal 启动。
- **显示器休眠会断采集**：`SCShareableContent` 返回 0 个屏，服务端报 `no display`。服务端已加唤醒+重试，但仍建议被控端常驻 `caffeinate -disu`。
- **音频隔离、输入连续性、睡眠唤醒、雷雳拔插、锁屏解锁均未验证**。

## 里程碑进度

项目按阶段门控推进，详细背景、技术边界与验收指标见 [设计文档](docs/design/project-charter.md)：

- [ ] **M0 前置验证**：显示层与雷雳链路已验证（[报告](docs/reports/2026-10-21-m0-display.md)）；**待亲验**：真无头重启后的 GUI 会话恢复、VNC 预登录救援、音频隔离、A′ 限时排除
- [x] **M1 视觉等价 Spike**：采集 → 硬编 → 雷雳直传 → 硬解 → Metal 1:1 上屏（α′ + ProRes 422：60fps、capture→present P95 27.6ms、SSIM 0.984；glass-to-glass 相机基准未做）
- [x] **M2 输入链路**：全屏系统级快捷键截获（`CGEventTap`）、修饰键与连续滚动相位（`CGEvent`）注入（⌘Tab/⌘Space/文字/点击/滚动 phase/退出热键已验证；⌃↑ 受前台 app 冲突，Secure Input/触控板为已知限制）
- [x] **M3 稳定性加固**：虚拟显示看门狗、TCC 权限自检、断线重连与心跳；8 小时长稳已执行（0 断连/0 解码失败/0 watchdog 重建，P95 48.4ms，输入连续性未验证）

## 文档

- [设计文档](docs/design/project-charter.md)：目标、约束、已验证事实、方案空间与里程碑
- [M0 前置验证计划](docs/plans/m0-verification.md)
- [输入连续性长跑计划](docs/plans/input-continuity.md)
- [未完成事项（P0/P1/P2）](docs/plans/open-items.md)
- [内建虚拟显示与应用化方案](docs/plans/2026-10-22-app-and-vdscreen-integration.md)
- [音频可选与默认隔离](docs/reports/2026-10-22-audio-option.md)
- [上屏 51 fps 的真因](docs/reports/2026-10-22-present-sync-fix.md)
- [传输加密（ChaCha20-Poly1305）](docs/reports/2026-10-22-transport-encryption.md)
- [M0 显示层验证报告](docs/reports/2026-10-21-m0-display.md)
- [M1 编码可行性探针](docs/reports/2026-10-21-m1-encoder-probe.md)
- [M1 α′ 管线报告](docs/reports/2026-10-21-m1-pipeline.md)
- [M2 输入链路报告](docs/reports/2026-10-21-m2-input.md)
- [M3 稳定性报告](docs/reports/2026-10-21-m3-stability.md)
- [M3 8 小时长稳结论](docs/reports/2026-10-22-m3-soak-8h.md)
- [架构决策记录](docs/adr/)
- [验证报告](docs/reports/)

## 环境要求

- macOS 15+（Apple Silicon）
- Thunderbolt 4 / 5 线缆直连（Thunderbolt Bridge）
- Swift 6 / Xcode Command Line Tools
- 服务端：屏幕录制权限（必需）、辅助功能（输入注入）、预共享密钥（`~/.boltkvm-key`）
- 客户端：输入监控权限（`--input` 时必需）

## 贡献

提交前请读 [AGENTS.md](AGENTS.md)：**完成一个可交付的变更单元就 commit，push 需显式声明**。提交要能独立编译、带对应验证、文档与代码同一提交。

## License

[MIT](LICENSE)
