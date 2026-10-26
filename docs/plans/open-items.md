# 未完成事项与已知问题

> 更新日期：2026-10-26（覆盖到 v0.12 发布与音频路线/全屏工具栏修复 `4f41335`）。本清单记录工程待办与需人工物理介入的测试项。需要人工在物理机器前操作（如合盖休眠、拔插线缆）或依赖外部硬件（如高速相机）的条目单列管理，不阻塞日常交付。

## 1. 核心工程事项（均已完成）

| ID | 事项 | 状态与结论 | 相关文档 |
|---|---|---|---|
| P0-1 | 传输认证与默认绑定雷雳网桥 | **已完成**：PSK + HMAC-SHA256 挑战应答，默认仅绑定 `bridge*` 接口 | [M3 稳定性报告](../reports/2026-10-21-m3-stability.md) |
| P0-2 | 重启恢复与自愈 | **已完成**：自动登录 + `BoltKVM.app` 登录项自启 + 子进程守护 + VNC 救援通道 | [应用化报告](../reports/2026-10-22-app-conversion.md) |
| P0-3 | 8 小时输入连续性验证 | **CLI 客户端已通过**：466 次转发、tap 失效 0、重连 0、96/96 采样点存活、0 丢帧（探针投递 458 次，与转发计数差 8 次，原始日志未入库，差额待核对）；**GUI 客户端尚未做 8 小时长跑**，README 因此记为「部分达标」 | [夜间执行报告](../reports/2026-10-22-night-run.md) |
| P0-4 | 音频默认隔离与可选转发 | **已完成**：默认零音频字节；开启后传输 48 kHz 双声道 PCM（约 1.54 Mbps） | [音频报告](../reports/2026-10-22-audio-option.md) |
| P1-应用化 | 单应用双角色 + 内建虚拟显示 | **已完成**：阶段 1–9 全部落地，实测 GUI 12 分钟稳定运行与音频转发 | [应用化方案](2026-10-22-app-and-vdscreen-integration.md)、[音频与 GUI 稳定性报告](../reports/2026-10-23-audio-and-gui-stability.md) |
| P1-连接管理 | 被控端列表（R1）与按主机配置分辨率（R2） | **已完成**：启动展示主机列表，连接时通过 `config` 包动态调整服务端虚拟屏尺寸 | [连接管理设计](2026-10-22-connection-manager-design.md) |
| P1-密码 | 8 位连接密码、256 位静态密钥与前向保密 | **已完成**：首次启动自动生成 8 位口令（PBKDF2 拉伸），支持切换 64 个十六进制字符（256 位）的静态密钥，每会话 X25519 密钥交换 | [ADR-0004](../adr/0004-psk-over-pairing-code.md) |
| P1-发布 | GitHub Actions 自动构建与发布 | **已就绪**：`ci.yml`（构建 + 全部 XCTest 单元测试（当前 77 项；无音频输出设备的 runner 会跳过音频回归）+ selftest + cryptotest + 打包）与 `release.yml`（推送 `v*` 标签自动发布） | [发布流程](../releasing.md) |
| 版本号 | 本地与发布构建版本盖章 | **已完成**：`build-app.sh` 默认用 `git describe`/`git rev-list` 写入 `CFBundleShortVersionString`/`CFBundleVersion`，CI 用 `BOLTKVM_VERSION`/`BOLTKVM_BUILD` 覆盖；v0.12 起生效 | [发布流程](../releasing.md) |
| B5 | 解码与 GUI 呈现延迟 SLO 核定 | **已完成**：解码链路 P95 25.4–27.0 ms（< 33 ms）；GUI 采集→上屏 P95 33.2 ms（< 50 ms） | [B5 延迟报告](../reports/2026-10-23-b5-latency.md) |
| B6 | 服务端慢客户端防堆积与超时保护 | **已完成**：发送队列限制 4 帧 / 8 MB 上限并配合 `SO_SNDTIMEO` 2 秒超时，防止慢客户端拖垮服务端内存 | — |
| B7 | GUI 呈现排队消除 | **已完成**：`Renderer` 改为到帧即时泵送 `view.draw()`，消除 60Hz 显示链路平均 8 ms 等待 | [B5 延迟报告](../reports/2026-10-23-b5-latency.md) |
| B8 | 客户端收流循环合并 | **已完成**：抽取共用 `SessionPump`，统一 CLI（含 `--render`）与 GUI 客户端收流、握手与统计逻辑 | — |

## 2. 暂不实现或受限于外部条件的事项

| 事项 | 当前状态 | 原因与触发条件 |
|---|---|---|
| R3 远端锁屏自动输入登录密码 | 暂不实现 | `loginwindow` 处于 Secure Input 保护下，普通用户态进程的 `CGEventPost` 会被系统丢弃；自动解锁需引入 root 特权 helper 与私有认证接口，超出当前无公证单应用边界。当前锁屏解锁统一走系统 VNC |
| 多显示器同时采集与传输 | 不支持 | 被控端仅创建并采集单块虚拟屏；多屏需扩展多路 `SCStream` 与选屏 UI，当前无使用需求 |
| 睡眠/唤醒、物理拔插雷雳线、网络切换恢复 | 待人工实测 | 需人工在物理设备前执行合盖与拔插操作 |
| Glass-to-glass 高速相机延迟基准 | 待外部设备实测 | 需使用外部高速相机同时拍摄本地与远端显示器测量含面板响应的物理延迟 |
| macOS 大版本升级后 TCC 回归 | 按需执行 | 待系统升级时使用 `boltkvm doctor` 验证 |
| 蓝牙耳机物理断电/重连后音频恢复 | 修复后已用「默认输出来回切换」验证 | 需用户按原始步骤实际关闭耳机再连接复核；等价触发见 [B18 报告](../reports/2026-10-26-audio-route-and-fullscreen-chrome.md) |

## 3. 历史问题与排查备忘

| 编号 / 现象 | 根因与当前状态 |
|---|---|
| **B1** 远端「调度中心 / 桌面」触发方式 | **已解决**：合成快捷键与未授权 AppleScript 均被系统拦截；现由服务端直接调用 `CoreDockSendNotification` 触发，无需 Automation 授权：桌面切换用 `com.apple.showdesktop.set`（带 1/0 参数，幂等，2026-10-23 起的主路径），调度中心仍用 `com.apple.expose.*.awake`，旧版 Dock 不认识 `set` 时回退到 `showdesktop.awake`。`App Exposé` 因无免授权路径已移除。点击调度中心前需已开启「转发键鼠」，否则客户端会弹窗提示 |
| **B2** 客户端窗口偶发不可见 | **已加诊断并收敛**：现改为关闭视频窗口即断开连接并回到主机列表（无列表时退出进程），消除了「窗口关闭但后台连接仍在」的状态；同时保留了 `windowWillClose` 与可见性诊断日志 |
| **B3** 服务端刚启动首次连接偶发停留在「正在连接…」 | **已缓解**：`SCShareableContent` 在虚拟屏刚就绪时偶发挂起不回调，已套 5 秒超时重试，客户端建连也增加了 3 次自动重试 |
| **B4** 窗口缩放时右上角出现黑色三角缺口 | **已修复**：原全屏单三角形顶点在缩放时斜边内缩裁切了右上角，已改为 4 顶点 Triangle Strip |
| **B9** 无雷雳网桥时分辨率在两种尺寸间来回跳 | **已修复**：子进程不再因绑定失败退出，虚拟屏保持并以 2 秒间隔重试绑定，插线后直接监听；退出时显式释放虚拟屏，重启不再撞 identity。详见 [报告](../reports/2026-10-25-headless-resolution-loop.md) |
| **B10** 分辨率预设顺序与内容 | **已调整**：前两项固定为 3008×1692（公司 HKC 32 寸 / 雷雳桥）与 1728×1117（MacBook Pro 内置屏），后接 1920×1080 / 2560×1440 / 2880×1620 / 3840×2160；被控端菜单、设置面板与客户端主机编辑统一读 `Prefs.displayOptions`（预设 + 本机自定义，去重），标题统一为 `×`，服务端菜单也列出当前自定义尺寸。自定义项只存当前 Mac 的偏好设置，不跨机器同步。1728×1117 的逻辑高度为奇数，2× 背板 3456×2234 仍为偶数，1× 码流在 `Server` 内向下取偶 |
| **B11** 改分辨率后主控端停在最后一帧、UU 短暂黑屏 | **客户端已修复，UU 仍受虚拟屏重建影响**：`ClientSession` 增加自动重连与 `.reconnecting` 状态，断线后按 0.5–5 秒退避重连，错误密码仍直接失败；被控端 helper 退出后的额外 2 秒等待已去掉。实测杀掉 mini 的 helper 后主控端自动恢复到 60fps。UU 不经过 BoltKVM 客户端，改分辨率仍会释放/重建虚拟屏，可能短暂黑屏；原地 `applySettings` 原型在生产 identity 上失败并已全部回退。详见 [报告](../reports/2026-10-26-client-reconnect-resolution.md) |
| **B12** server Dock 图标 / 双击转发 | **已修**：helper 用 `TransformProcessType` 转 background，app 在 `run()` 前按 server/accessory 设策略；`InputEvent` padding 字节改 `clickCount`，客户端转发 `NSEvent.clickCount` / `mouseEventClickState`，服务端注入 `mouseEventClickState=clickCount`。`lsappinfo` 验证 app=UIElement、helper=BackgroundOnly；客户端日志实测双击 `n=2` 已到服务端。远端窗口 zoom 待实机复核；server 设置面板固定尺寸，双击其标题栏不会 zoom |
| **B13** 无音频输出设备时 `--audio` 崩溃 | **已修**：输出设备不可用（CI runner 即如此）时不再抛 `-10868`，改为降级静音并记录 `audio: playback unavailable (...)`；`AudioFinishTests` 在 `isPlaybackActive == false` 时 `XCTSkip`。涉及 ObjC `@try/@catch` 兜底（`BKVTrying`）、CoreAudio 设备探测与启动失败清理，见 [报告](../reports/2026-10-26-audio-no-output-device.md) 与 CI run 40266047475 |
| **B14** Swift 6.1.2 对事件掩码表达式报「type-check 超时」 | **已修**：`InputCapture.start()` 里 14 项 `(1 << CGEventType…)` 的或链在 CI 的 Swift 6.1.2 上触发 `unable to type-check this expression in reasonable time`；改为事件类型列表 + `reduce` 折叠，掩码值仍是 `0x0E401CFE`，并加 `InputCaptureMaskTests` 钉住。本地 6.4 编译不复现该问题，只能用 CI 验证，见 [报告](../reports/2026-10-26-input-event-mask.md) |
| **B15** 键鼠发送阻塞主线程导致 UI 卡顿与 tap 被禁用 | **已修**：新增 `InputSender`，发送移到独立串行队列，队列上限 64，拥塞时丢弃过时输入；按键/鼠标释放包绕过上限，避免远端卡住按键或鼠标键。发送不再占用主线程，全局 tap 不会因回调超时被系统禁用 |
| **B16** 全屏下工具栏点击被当成画面点击转发远端 | **v0.12 复发后已再修**：全屏时工具栏是独立浮层，本地监听器会收到工具栏窗口的事件；仅按屏幕坐标命中视频仍可能把工具栏下沿/非 key 首击转发出去。现增加事件窗口归属检查、非 key 首击本地激活、画面上沿以上按屏幕坐标排除三层防护，并用 `InputChromeRoutingTests` 钉住边界。v0.12 旧验证只点了按钮中心，未覆盖下沿/首击，见 [报告](../reports/2026-10-26-audio-route-and-fullscreen-chrome.md) |
| **B17** ProRes 一律按 10-bit 解码 | **已修**：ProRes 422 线路上是 10-bit 4:2:2，原实现标准模式让 VideoToolbox 解成 8-bit YUV，量化发生在解码步；现 ProRes 统一解到 `422YpCbCr10`，标准模式也不再降 8-bit，GPU 实测 1.8 ms |
| **B18** 蓝牙耳机断开重连后音频不再播放 | **已修**：旧输出图在路线变化后仍报 `running/playing`，但缓冲区只进不出（`scheduled` 涨到 256）。现每次默认输出变化都重建 `AVAudioEngine` + `AVAudioPlayerNode`，CoreAudio 监听 + 2 秒健康检查兜底，150 ms 去重；实测来回切换输出 graph #1→#2→#3，见 [报告](../reports/2026-10-26-audio-route-and-fullscreen-chrome.md) |
| **B19** 全屏工具栏浮现时远端画面变形/显示不全 | **已修**：普通窗口样式下 AppKit 会把全屏窗口从 1692 pt 缩到 1640 pt，Metal drawable 比例变化导致画面重缩放。现改用 `.fullSizeContentView`，工具栏只作浮层，画面保持原尺寸整体下移 52 pt；点击工具栏仍由本地消费，见 [报告](../reports/2026-10-26-audio-route-and-fullscreen-chrome.md) |
| **B20** v0.12 全屏工具栏点击穿透复发 | **已修（待最终包复验）**：与 B16 同源但触发面更宽——工具栏浮层事件被本地监听器当作视频事件、非 key 首击被转发。修复见 B16 与 [报告](../reports/2026-10-26-audio-route-and-fullscreen-chrome.md) 第 4 节；`swift test` 80 项通过（1 skip），172 测试包锁定指针点击工具栏无转发计数增长 |
| **环境提示**：替换二进制时出现 `SIGKILL (Code Signature Invalid)` | **进程运行中覆盖二进制**：macOS `taskgated` 检测到磁盘签名与内存映射不一致会直接杀死进程；重新部署前需先停止正在运行的 `BoltKVM` 与 `boltkvm-server`（`scripts/deploy-app.sh` 已内置） |
| **环境提示**：GUI 客户端报 `No route to host` 而同机 CLI 正常 | **本地网络 TCC 权限未开**：macOS 15+ 将局域网/雷雳桥访问纳入「本地网络」权限，ad-hoc 重编译会重置该授权。前往「系统设置 → 隐私与安全性 → 本地网络」勾选 `BoltKVM` 即可，日常开发建议使用 `BoltKVM Local` 自签名证书 |
