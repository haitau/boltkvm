# 未完成事项与已知问题

> 更新日期：2026-10-28（第 4 节追加 A-5 权限入口与 TCC 重授权修复；A-1/A-2/A-3/A-4 的记录保持不变）。本清单记录工程待办与需人工物理介入的测试项。需要人工在物理机器前操作（如合盖休眠、拔插线缆）或依赖外部硬件（如高速相机）的条目单列管理，不阻塞日常交付。

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
| P1-发布 | GitHub Actions 自动构建与发布 | **已就绪**：`ci.yml`（构建 + 全部 XCTest 单元测试（当前 80 项；无音频输出设备的 runner 会跳过音频回归）+ selftest + cryptotest + 打包）与 `release.yml`（推送 `v*` 标签自动发布） | [发布流程](../releasing.md) |
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
| **B20** v0.12 全屏工具栏点击穿透复发 | **已修并随 v0.12.1 发布**：与 B16 同源但触发面更宽——工具栏浮层事件被本地监听器当作视频事件、非 key 首击被转发。修复见 B16 与 [报告](../reports/2026-10-26-audio-route-and-fullscreen-chrome.md) 第 4 节；`swift test` 80 项通过（1 skip），172 测试包锁定指针点击工具栏无转发计数增长；Release 产物校验见 [发布记录](../reports/2026-10-26-v0.12.1-release.md) |
| **环境提示**：替换二进制时出现 `SIGKILL (Code Signature Invalid)` | **进程运行中覆盖二进制**：macOS `taskgated` 检测到磁盘签名与内存映射不一致会直接杀死进程；重新部署前需先停止正在运行的 `BoltKVM` 与 `boltkvm-server`（`scripts/deploy-app.sh` 已内置） |
| **环境提示**：GUI 客户端报 `No route to host` 而同机 CLI 正常 | **本地网络 TCC 权限未开**：macOS 15+ 将局域网/雷雳桥访问纳入「本地网络」权限，ad-hoc 重编译会重置该授权。前往「系统设置 → 隐私与安全性 → 本地网络」勾选 `BoltKVM` 即可，日常开发建议使用 `BoltKVM Local` 自签名证书 |

## 4. 待改进（2026-10-27 夜间处理）

以下条目来自 2026-10-26/27 的使用反馈。2026-10-27 19:00 后的夜间窗口已处理 A-1/A-2/A-3，A-4 改了代码但受锁屏限制未能截图复核；处理结果见 4.1 与 [夜间报告](../reports/2026-10-27-nightly-open-items.md)。

| ID | 现象 | 当前实现与影响面 | 期望 / 下一步 |
|---|---|---|---|
| A-1 | 开启音频转发后，被控端本地与主控端同时出声 | **已实现并调整语义**：最初在采集启动后设备级静音，导致用户侧“莫名其妙被静音”。2026-10-28 起默认改为 MediaRemote 暂停当前 Now Playing 应用，不动系统静音/音量；`--local-mute` 才显式设备静音。SCK 在设备静音之前取音，远端仍收到完整音频 | 默认只暂停媒体，不静音设备；旧版残留 marker 在新 helper 启动时恢复。仍待验证第三方播放器（网易云）是否都响应 MediaRemote |
| A-2 | **已实现**：音频已路由到主控端时，主控端音频设备发生变化（蓝牙耳机开关、有线耳机插拔），被控端上正在播放的应用（如网易云音乐）应自动暂停 | 客户端检测到默认输出变化后重建本地 `AVAudioEngine`，并发送 `pauseMedia`；服务端用 MediaRemote 暂停当前 Now Playing。2026-10-28 起音频采集启动时也会先暂停一次；设备静音不再是默认路径 | 真实网易云音乐、蓝牙一次切换多条通知的去重仍需实机复核；第三方播放器不响应 MediaRemote 时可能继续播放，但不会静音设备 |
| A-3 | 剪切板不互通：主控端复制的文本、富文本、截图或文件无法直接粘到被控端，反之亦然 | 协议没有剪切板包，两端也都没有监听 `NSPasteboard.general`；复制只发生在各自本机，跨端传递需借助聊天工具等外部中转 | 目标覆盖四类内容：① 纯文本 `public.utf8-plain-text`；② 富文本 `public.html` / `public.rtf`（同时带纯文本回退）；③ 图片 `public.png`（只有 TIFF 时转 PNG）；④ 文件与文件夹，传内容而不是路径。协议新增 `clipboard`（非文件项，256 KB 分块，单次总量默认 ≤512 MB）与 `fileTransfer`（1 MB 分块，总量按可用磁盘空间收紧并预留 20 GB，不设固定 2 GB 上限；逐文件 SHA-256 校验）。协议单包 `maxPayload` 16 MB 只是接收侧防爆上限，分块后总量与它无关；两个总量都可在偏好（defaults/CLI）调整。接收端写入 `~/Downloads/BoltKVM Clipboard/`，文件夹用 `ditto` 打包/解包并校验条目路径，断线清理半成品。用 `NSPasteboard.changeCount` + 内容哈希防回环；跳过 `ConcealedType` / `TransientType` / `AutoGeneratedType`；默认开启，客户端设置提供关闭开关；符号链接暂不支持，README 写明 |
| A-4 | 全屏观看时屏幕最上方有一条白线周期性闪烁；指针移到顶部弹出工具栏后消失，工具栏回收后经过固定时间又出现 | 全屏使用 `.fullSizeContentView`，工具栏隐藏时 `ChromeLayout.videoFrame` 让 `videoView` 铺满 content bounds（y=0、高度等于内容高度），工具栏显示时整体下移 52 pt；显隐由 5 Hz 的 `tickChrome` 轮询指针控制（顶部 4 pt 停留 0.2 s 显示、离开 110 pt 隐藏）。白线来源尚未定位，出现周期也未测量，属【未经核实】 | 先复现并固定证据：屏幕录制或截帧看清白线像素行、记录出现周期与是否只在全屏出现、换分辨率/窗口模式是否复现。再按三种可能排查：① 隐藏后的全屏标题栏/工具栏分隔线仍有 1 pt 残留，AppKit 的自动隐藏动画让它随轮询周期复现；② `videoView.frame` 与 content bounds/Metal drawable 顶部未做像素对齐，露出窗口或 layer 背景；③ 工具栏隐藏后 `contentLayoutRect` 变化，画面顶部被裁切或回弹。修复前不要先改画面位移逻辑，避免把 A-4 与工具栏几何回归混在一起 |
| A-5 | 被控端权限入口只显示一个；重装/重签名后系统设置里旧 BoltKVM 行仍显示已开，但应用仍报未授权，反复勾选无效 | 设置面板原本只有一个屏幕录制按钮，菜单项又按授权状态互相隐藏；TCC 记录保存旧代码要求（ad-hoc 的 cdhash 或旧证书），与新应用不匹配时旧开关不会作用于新进程。手动 `tccutil reset ScreenCapture/Accessibility io.github.boltkvm` 可恢复 | 被控端设置面板与菜单栏始终显示屏幕录制、辅助功能两个独立入口，点击分别打开对应系统设置页，并用勾选状态显示授权；新增「重置权限并重新授权…」。安装/部署脚本比较新旧 designated requirement：相同签名保留授权，首次安装、签名变化或 `--reset-permissions` 时只清除这两项旧记录。TCC 授权仍需用户手动勾选，脚本不代点 |

### 4.1 2026-10-27 夜间处理

- **A-1 已实现，2026-10-28 调整语义**：服务端在 `--audio` 采集启动后暂停当前 Now Playing 应用（MediaRemote），不再默认静音默认输出；系统静音/音量保持不变。只有显式 `--local-mute` 才走 `AudioOutputMute`（优先 `kAudioDevicePropertyMute`，退回音量 0），断开时恢复；崩溃恢复 marker 仍保留。用户报告 mini 被静音后已部署 214 验证 `output muted:false`、marker 清空、日志 `media: paused the current Now Playing app`。详见 [音频设备静音报告](../reports/2026-10-28-audio-local-mute.md)。
- **A-2 已实现**：客户端音频输出设备变化 → 0.5 s 防抖 → `pauseMedia` 命令 → 服务端 MediaRemote 暂停当前 Now Playing 应用；只在主控端播放转发音频时触发，录音-only 不触发。本机用切换默认输出设备（内置扬声器 ↔ BlackHole）实测命令到达服务端、MediaRemote 返回成功；真实播放器（网易云音乐）暂停效果因锁屏无法在夜间验证。
- **A-3 已实现（核心）**：文本、HTML/RTF、PNG、文件/文件夹双向同步；协议、分块、SHA-256、回环抑制、Concealed 过滤、客户端开关与可配置上限已落地。本机回环实测 48 B 文本、116 B 富文本、17 MB PNG（69 块）、5 MB 文件 + 文件夹（逐文件校验）通过；1 MB 上限会按预期拒绝 17 MB 图片。跨机、GUI 实机、真实 `~/Downloads` 路径与超大文件长跑仍待验证；同机回环因两端共享粘贴板会各落一份，属测试环境现象。
- **A-4 已修复工具栏回归、待最终视觉确认**：第一版在关闭分隔线的同时把标题栏设为透明、窗口背景设为黑色，浅色外观下工具栏文字/图标变成黑上黑，调度中心/桌面等按钮全部不可见。现改为只设 `titlebarSeparatorStyle = .none`，显式 `titlebarAppearsTransparent = false`，保留原生标题栏材质；窗口模式与全屏工具栏显示时截图中按钮均可见，全屏工具栏隐藏时顶部 4 px 连续 3 轮显隐采样无白色整行。A-4 的画面位移逻辑与 `ChromeLayout` 未改。

记录边界：

- A-1 的“被控端应静音”已定为设备级静音：优先 CoreAudio mute、退回音量 0；实测 SCK 采集在音量/静音之前，远端不受影响；
- A-2 的“停止”语义已定为“暂停当前 Now Playing 应用”，不退出应用；只在主控端播放转发音频时触发，录音-only 不触发；
- A-3 的范围：纯文本、富文本（HTML/RTF）、图片（PNG/TIFF）、文件与文件夹（传内容）；非文件项默认 ≤512 MB，文件传输默认不设固定总量上限、按“可用磁盘 − 20 GB 预留”收紧（也可再加 GB 上限）；符号链接暂不支持；默认开启，可在客户端设置关闭；跳过 `ConcealedType`/`TransientType`/`AutoGeneratedType` 内容；接收目录为 `~/Downloads/BoltKVM Clipboard/`；只同步剪切板内容，不模拟 `⌘V` 自动粘贴；
- A-4 是视觉问题，和已修的 B19/B20（全屏画面变形、工具栏点击穿透）不是同一处回归；它不影响输入转发，但会干扰观看。若最终改动 `ChromeLayout` 的位移，需同时跑 `ClientChromeLayoutTests`，并用实机截帧复核顶部不再出现残留；
- A-1/A-2 涉及音频链路，A-3 是新增跨端能力：音频侧保持“默认不转发、默认不双端出声”的边界；剪切板默认开启但提供关闭开关；实现时同步更新 README 与协议说明（A-4 只改本地渲染，更新 README 即可）。

### 4.2 2026-10-28 权限入口与 TCC 重授权修复

- **A-5 已实现**：被控端菜单栏固定显示「屏幕录制权限…」「辅助功能权限…」「重置权限并重新授权…」，设置面板固定显示前两个按钮；点击分别打开对应系统设置页，菜单项带授权勾选状态。应用内重置只清除本 bundle 的 `ScreenCapture` / `Accessibility` 两项。
- **安装流程**：`scripts/install-app.sh` 比较旧应用与新应用的 designated requirement。相同稳定证书重新编译时保留 TCC 授权；首次安装、ad-hoc 切换稳定证书、旧应用缺失或传 `--reset-permissions` 时自动执行两项 `tccutil reset`，再启动应用等待用户授权。`scripts/deploy-app.sh` 在被控端做同样处理，并改用精确进程名停止旧进程。
- **本机验证**：menu / 面板实际读到两个权限入口与重置项；屏幕录制按钮打开 `录屏与系统录音`，辅助功能按钮切到对应页面；同一签名重装输出「签名身份未变，保留现有 TCC 授权。」；强制 `--reset-permissions` 输出清除提示且退出码 0（测试时两项本来都未授权）。mini 已部署 212，日志为 `screen recording: true, accessibility: false`，采集恢复但辅助功能仍需用户点「辅助功能权限…」授权。
- **边界**：TCC 授权不能由脚本代替用户勾选；跨机「旧签名升级 → 自动清旧记录 → 重新授权 → 采集/注入恢复」仍未完整实机验证。详见 [权限与 TCC 报告](../reports/2026-10-28-permissions-and-tcc.md)。

### 4.3 2026-10-28 全屏工具栏首次弹出无按钮

- **最终实现**：回到原生 `NSToolbar`，但把动作项改为标准 `NSToolbarItem`（系统绘制图标、文字和按压态），不再使用首次布局会空白的 view-based 自定义项。全屏第一次显隐额外做一次“显示→隐藏→显示”预热，让 `NSToolbarFullScreenWindow` 完成首次布局；之后直接显示。画面按全屏工具栏窗口的实际下沿下移：菜单栏显示时 98 pt，菜单栏自动隐藏时为 68 pt；不再写死 52/98。
- **验证**：窗口模式截图可见原生「调度中心」「桌面」图标与文字；首次全屏顶边停留日志出现 `toolbar shown ... shifted down by 68/98 pt`（随菜单栏是否显示），全屏工具栏子窗口 3008×68；`swift test` 92 项通过（1 项跳过）。
- **边界**：SCK/系统截图不采集 `NSToolbarFullScreenWindow` 子窗口，无法用静态截图直接证明全屏按钮像素；本机以窗口模式截图、子窗口尺寸与日志推断。未做旧版 macOS、多显示器、深浅色切换的逐一验证；A-4 的长周期闪烁仍需单独录屏确认。
