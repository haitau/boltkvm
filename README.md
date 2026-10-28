# BoltKVM

**简体中文** | [English](README_EN.md)

两台 macOS 设备之间的低延迟屏幕控制工具。一个应用包含两种角色：**被控端**（共享屏幕，支持无显示器的无头 Mac）和**主控端**（在窗口或全屏中操作对端屏幕）。推荐通过雷雳网桥（Thunderbolt Bridge）直连，无需中继、账号或外网连接，两端凭同一个连接密码即可完成认证与加密通信。

## 核心指标

- **像素等价**：支持按被控端虚拟屏真实像素（2× backing）传输与渲染，文字清晰不发糊。
- **低延迟交互**：解码链路（采集→解码）P95 < 33 ms；GUI 呈现（采集→上屏，不含输入反向上行）P95 < 50 ms。
- **音频隔离**：默认不采集、不传输音频，也不改动两端输出设备；按需开启转发后，被控端会暂停当前正在播放的媒体（不静音设备），同一路声音只从主控端继续播放；设备音量/静音状态始终不变。
- **单向控制**：主控端仅捕获输入与渲染画面，被控端仅采集屏幕与注入输入，从拓扑上避免双向互控回环。
- **断线自动重连**：被控端重启采集子进程（改分辨率、升级）或链路短暂中断时，主控端窗口自动重连并显示重连次数，不再停在最后一帧；错误密码仍然直接报错，不会无限重试。

## 下载与安装

最新发布包见 [Releases](https://github.com/haitau/boltkvm/releases)，每次发布附带 `BoltKVM-<版本>.zip` 与同名 `.sha256`：

```bash
V=0.12.1   # 换成实际发布版本
unzip BoltKVM-$V.zip -d BoltKVM-$V
shasum -a 256 -c BoltKVM-$V.zip.sha256
open BoltKVM-$V/BoltKVM.app
```

发布包为 ad-hoc 签名，首次打开需在「系统设置 → 隐私与安全性」中放行；需要长期稳定的 TCC 授权时，按下方「权限要求」生成并信任本地证书后自行打包。也可以按「快速开始」从源码构建。

## 实测结果（2026-10-23）

| 指标 | 目标 | 实测 | 结论 |
|---|---|---|---|
| 像素等价 | SSIM > 0.98 | SSIM 0.984 | 达标 |
| 解码吞吐 | 60 fps | **54.1–58.0 fps**（三轮） | 达标 |
| 解码链路延迟 | P95 < 33 ms | P95 **25.4–27.0 ms** | 达标（三轮解码 P95 均 < 33 ms） |
| GUI 采集→上屏延迟 | P95 < 50 ms | P50 **31.0 ms**、P95 **33.2 ms**、60.0 fps | 达标（详见 [B5 延迟报告](docs/reports/2026-10-23-b5-latency.md)） |
| 稳定性 | 8 小时不断连 | 8h00m01s：0 断连、0 解码失败、0 看门狗重建 | 达标 |
| 音频 | 默认零字节 | 默认不传；开启后 1.54 Mbps、−34 dBFS，12 分钟 RSS 134→135 MB | 达标（可选） |
| 输入连续性 | 8 小时不丢事件 | 8h 内 466 次转发、tap 失效 0（CLI 客户端；探针投递 458 次，差额未核对；GUI 客户端未做 8h 长跑） | 部分达标 |

解码链路与 GUI 呈现链路分开统计：解码链路 P95 在 27 ms 以内；GUI 渲染采用到帧即时触发 `MTKView.draw()` 的泵送模式，消除了等待显示刷新周期的排队开销，采集→上屏 P95 为 33.2 ms。详见 [B5 延迟报告](docs/reports/2026-10-23-b5-latency.md) 与 [音频与 GUI 稳定性报告](docs/reports/2026-10-23-audio-and-gui-stability.md)。

## 架构

```text
[被控端]                                          [主控端]
虚拟显示（应用默认 3008×1692 逻辑 @2x → 6016×3384 像素，可配；CLI 默认采集 3840×2160、逻辑 1920×1080）
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
./scripts/install-app.sh    # 编译 release、签名、安装到 /Applications 并启动
```

首次启动选择角色，后续可在顶部菜单「角色」中切换。只组装 `dist/BoltKVM.app`、不安装时用 `./Packaging/build-app.sh`。安装脚本会把上一版保留为 `/Applications/BoltKVM.app.bak`，签名优先使用本机稳定的 `BoltKVM Local` 证书。

单个应用包支持两种运行角色：

**被控端**（菜单栏常驻，无主窗口）

- 设置面板显示分辨率、画面质量、端口、连接密码与指纹、服务状态，并提供权限设置与日志入口；
- 屏幕采集与虚拟屏创建由应用包内的 `boltkvm-server` 子进程执行，子进程异常退出后 3 秒自动重启；
- 点击「重新生成密码…」会生成新口令并重启服务，旧密码立即失效。

**主控端**（单窗口）

- 启动后显示被控端列表，双击即可连接；点击「编辑」可按主机配置名称、地址、端口、分辨率、连接密码、色彩模式及键鼠/音频开关；
- 连接后窗口按 **1:1** 适配（一个码流像素对一个物理像素）：屏幕放得下就直接 1:1，放不下则按可见区域等比缩小，窗口副标题显示缩放百分比（仅缩放时显示）；全屏（⌃⌘F）在尺寸匹配的屏幕上就是 100%，文字最清晰；
- 工具栏右侧提供「调度中心」与「桌面」两个远端系统操作（后者按下后变成「还原窗口」，再按一次恢复原来的窗口）；窗口标题显示主机名，副标题实时显示连接状态与 `fps · Mbps`，和 macOS「屏幕共享」一样是标题在左、按钮在右；
- 全屏下工具栏作为浮层自动隐藏，指针在屏幕顶边停留片刻后浮现；远端画面整体下移一个工具栏高度，尺寸和比例不变（底部超出屏幕），与 macOS「屏幕共享」的表现一致，不再因工具栏出现而被压扁重新缩放；
- 关闭视频窗口即断开连接并返回主机列表；
- 仅当鼠标指针位于画面区域内时转发键鼠事件。指针移出画面、窗口失焦或连接断开时，已按下的按键与鼠标键会自动抬起；每次按键注入前也会按事件携带的修饰键掩码对齐远端状态，防止修饰键卡死。

### 色彩模式

主控端「编辑 → 色彩」有两种选择，改动会随 `config` 包发给服务端：

| 模式 | 采集 | 编码 | 码率（6016×3384 桌面） | 适用 |
|---|---|---|---|---|
| 标准（默认） | 8-bit 4:2:0 BT.709 | ProRes 422 | ~1.9 Gbps | 日常使用 |
| 广色域 | 10-bit 4:2:2 Display P3 | ProRes 422（P3 标记） | ~1.85 Gbps | 渐变更平滑；直接采集真实 P3 显示器时才有广色域 |

需要说清楚的是：服务端用**虚拟屏**时，虚拟屏的帧缓冲本身是 sRGB（实测：该显示空间里的纯红转换到 P3 是 `0.918 / 0.200 / 0.139`，正是 sRGB 红），所以广色域模式在这一层**不会**增加色域，只能减少一次中间量化；真正的广色域收益出现在 `--display-id` 直接采集物理 P3 显示器的场景。两者的差别在客户端窗口副标题显示为 `P3` 标识。

补充：ProRes 422 在线路上本来就是 10-bit 4:2:2，客户端对 ProRes 一律按 10-bit 解码（标准模式也不例外）；表中的 8-bit 指采集端像素格式，HEVC 路径仍是 8-bit 4:2:0。

界面支持中英双语，自动跟随系统语言（词表位于 `Packaging/Resources/{en,zh-Hans}.lproj/Localizable.strings`）。

## 权限要求

| 角色 | 所需权限 | 用途 |
|---|---|---|
| 被控端 | 屏幕录制 | ScreenCaptureKit 采集屏幕，缺失时无法启动服务 |
| 被控端 | 辅助功能 | CGEvent 注入键鼠事件，缺失时仅可看画面、无法控制 |
| 主控端 | 本地网络（macOS 15+） | 访问雷雳网桥或局域网地址；缺失时系统直接返回 `No route to host` |

主控端应用使用窗口内 `NSEvent` 本地监听捕获键鼠，无需申请「输入监控」权限（仅 CLI 全屏 `--input` 模式使用 `CGEventTap` 时需要输入监控权限）。

被控端设置面板固定显示两个独立按钮：「屏幕录制权限…」和「辅助功能权限…」，分别打开系统设置中对应的页面；菜单栏也有同样两项，并用勾选状态显示当前是否已授权。任意一项缺授权时状态点变橙，不会因为另一项已授权而隐藏入口。

打包脚本会优先使用本机稳定的 `BoltKVM Local` 证书；没有该证书时才回退 ad-hoc 签名（`-`）。ad-hoc 每次重编译都会改变二进制 `cdhash`，导致 macOS TCC 将其视为新应用并要求重新授权；稳定证书可让屏幕录制/辅助功能授权跨重编译保留。首次使用可生成并信任：

```bash
./scripts/make-signing-identity.sh                                  # 生成并信任 "BoltKVM Local"
./scripts/install-app.sh
```

`install-app.sh` 会比较新旧应用的设计要求（designated requirement）：签名身份没变时保留现有 TCC 授权；首次安装、ad-hoc 切换为稳定证书、或 `--reset-permissions` 时，只清除本应用 `ScreenCapture` / `Accessibility` 两项旧记录，再启动应用让你重新勾选。等价的命令是：

```bash
tccutil reset ScreenCapture io.github.boltkvm
tccutil reset Accessibility io.github.boltkvm
```

如果系统设置里的开关看起来是开的、但应用仍报未授权，先退出应用，在菜单栏选择「重置权限并重新授权…」，或执行上面的命令，再重新打开应用授权。TCC 授权本身不能由脚本代替用户点击，脚本只能清除不匹配的旧记录。`deploy-app.sh` 在被控端做同样的签名比较和重置。

应用图标由 `swift scripts/make-icon.swift Packaging/AppIcon.icns` 生成。

## 快速开始

### 1. 构建与部署

```bash
./scripts/install-app.sh
```

这会把最新构建直接安装到本机 `/Applications/BoltKVM.app` 并启动，旧版保留在 `/Applications/BoltKVM.app.bak`。两台 Mac 各自运行一次即可；若被控端已配置 SSH，可执行 `./scripts/deploy-app.sh <被控端地址>` 自动完成打包、上传、停旧进程与启动。

### 2. 配置被控端

首次打开选择「作为被控端」，在面板中分别点「屏幕录制权限…」和「辅助功能权限…」，授予两项权限后重开应用（两项都必须授权：屏幕录制负责采集，辅助功能负责键鼠注入）。

首次启动会在 `~/.boltkvm-key`（权限 0600）自动生成 8 位连接密码，并在面板底部展示：

```text
连接密码 abcdefgh（主控端填一次即可） 指纹 E0AF 9869 0698 8829
```

要在被控端应用模式下开启音频转发，可在被控端执行：

```bash
defaults write io.github.boltkvm server.audio -bool true
```

然后在菜单栏停止再启动服务即可生效。

开启音频转发后，服务端不会再改动本机默认输出的静音或音量。采集启动成功时，它会用 MediaRemote 暂停当前 Now Playing 应用（网易云音乐、Music 等），所以本机扬声器不会继续播放同一路声音；暂停的是播放器，不是设备，应用仍在运行。主控端断开后媒体保持暂停，不自动恢复，避免把用户后来手动播放的内容又切掉。ScreenCaptureKit 在设备音量/静音之前取音，远端仍能听到完整声音。

`--local-mute` 是显式 opt-in：只有加了这个参数才会把默认输出静音；`--no-local-mute` 仍作为兼容别名接受，效果同样是关闭设备静音。默认不再静音。若旧进程被强杀，下一次启动仍会读取 `~/Library/Application Support/BoltKVM/mute-state.json`，把显式静音过的设备恢复到原状态。

音频采集启动时就会暂停一次当前 Now Playing 应用，避免被控端和主控端同时出声。主控端正在播放转发音频时，如果默认输出设备再发生变化（蓝牙耳机开/关、有线耳机插拔），客户端会在 0.5 s 防抖后向服务端发送 `pauseMedia`，服务端用 MediaRemote 再次暂停当前 Now Playing 应用（网易云音乐、Music 等），只暂停播放、不退出应用；日志为 `audio: output route changed; asked server to pause media` 与 `media: paused the current Now Playing app`。该联动只在主控端开启音频播放时生效，录音-only 会话不会触发启动暂停之外的行为。

### 剪切板同步

两台机器连上后，剪切板默认双向同步：

- **文本与富文本**：`public.utf8-plain-text`、`public.html`、`public.rtf`；富文本同时带纯文本回退；
- **图片**：`public.png`，只有 TIFF 时先转 PNG；
- **文件与文件夹**：传内容而不是路径。接收端落到 `~/Downloads/BoltKVM Clipboard/`，同名自动加序号；文件夹用 `ditto` 打包/解包，逐个文件做 SHA-256 校验；符号链接暂不支持；
- **安全边界**：跳过 `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`（密码管理器常用这些类型）；只同步剪切板内容，不模拟 `⌘V`，也不会自动粘贴；
- **防回环**：`NSPasteboard.changeCount` 加内容 SHA-256，避免两端把同一份内容反复传；
- **开关**：主控端「编辑被控端」里的「剪切板」复选框，或 `defaults write io.github.boltkvm client.clipboard -bool false`；被控端可加 `--no-clipboard`；
- **容量**：非文件项默认单次 ≤512 MB（`client.clipboardMaxMB`），文件传输默认按「可用磁盘 − 20 GB」收紧、不设固定 2 GB 上限；需要更紧的上限时设 `client.clipboardMaxGB`，服务端对应 `server.clipboardMaxMB` / `server.clipboardMaxGB`。这些值都只是安全阀，不是链路带宽上限；
- **断线**：未完成的文件先写入接收目录下的 `.incoming-*`，失败或断线会清理，不会把半个文件留在最终位置。

### 3. 配置主控端

首次打开选择「作为主控端」，点击「添加被控端」填写名称、被控端雷雳网桥 IP、端口（默认 7474）及上述 8 位连接密码。

- **8 位连接密码**：由小写字母与数字组成（剔除易混淆的 `0/o/1/l/i`），输入时自动忽略大小写、空格与连字符；通过 PBKDF2-SHA256（12 万次迭代）拉伸为 32 字节密钥；
- **256 位静态密钥**：对安全性要求更高时，可在被控端面板点击「256 位密钥…」生成 64 个十六进制字符（256 位）的随机密钥，整段复制粘贴到主控端密码栏即可；
- **指纹核对**：两端显示的 16 位十六进制指纹（SHA-256 前 8 字节）一致即表示密钥匹配；
- **凭据存储**：主控端密码按主机保存在 `~/Library/Application Support/BoltKVM/keys/`（权限 0600），不经过系统钥匙串，避免重签名后频繁弹出钥匙串授权框。

**注意**：连接地址请填写雷雳网桥的字面 IP，不要填主机名（本机代理软件可能将主机名劫持为 fake-ip 导致连接被重置）。

### 4. 建立连接

双击列表中的被控端或点击「连接」。在主机编辑面板修改分辨率后，下次连接时服务端会自动按新尺寸重建虚拟屏；画面质量（「标准」限制最大宽度 3840，「清晰」按 2× 真实像素传输，自定义逻辑宽超过 4096 时码流宽以 8192 为上限）在被控端菜单栏或设置面板中切换。

分辨率预设由被控端菜单、设置面板和主机编辑面板共用同一份目录：前两项是本项目的两个目标尺寸 3008×1692（雷雳桥 / 32 寸显示器）与 1728×1117（MacBook Pro 内置屏），之后是 1920×1080、2560×1440、2880×1620、3840×2160；自定义尺寸会加入本机目录，服务端菜单也会列出当前自定义尺寸。自定义项只存在当前 Mac 的偏好设置里，不会自动同步到另一台机器。

## 命令行工具（CLI）

`boltkvm` 提供与 GUI 共用核心库的命令行入口，适用于脚本化验证与长跑测试：

```bash
# 启动被控端服务
.build/release/boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# 启动主控端（全屏渲染 + 键鼠转发 + 自动重连）
.build/release/boltkvm client --host <被控端地址> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect

# 运行测试套件（含全部 XCTest 单元测试；仅装 CLT 的机器会自动回退到 CLI 自测）
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
--local-mute                       # 显式静音被控端默认输出（默认不静音；仅特殊场景使用）
--no-clipboard                     # 关闭剪切板同步（默认开启）
--clipboard-max-mb 512             # 非文件项单次上限（MB）
--clipboard-max-gb 0               # 文件传输额外上限（GB）；0 表示只按磁盘空间收紧
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
git tag v0.12.1 && git push origin v0.12.1
```

只推送 `main` 不会触发发布——`release.yml` 仅在推送 `v*` 标签时运行；打标签前请确认 `main` 上的 CI 全绿。发布流程与签名说明见 [发布流程](docs/releasing.md)。

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
- **无雷雳网桥时**：被控端仍会创建并保持虚拟屏，远程桌面/屏幕共享下也能通过被控端菜单调整分辨率，但暂不监听端口，菜单栏显示「虚拟屏就绪，等待网络」；插上雷雳线后自动开始监听，虚拟屏不重建。这避免了子进程因绑定失败反复重启、桌面在两种分辨率之间来回跳。
- **残留进程冲突**：手动运行 CLI 前需确认无残留 `boltkvm server` 进程，否则新建 `SCStream` 可能挂起。
- **安全输入与锁屏限制**：系统处于锁屏或密码输入框（Secure Input）状态时，会话级事件监听会被系统拦截；锁屏解锁请使用系统自带的屏幕共享（VNC）。
- **不支持多显示器同传**：被控端仅创建并采集一块虚拟屏。
- **没有可用音频输出设备时**：开启 `--audio` 但机器没有输出设备（例如 CI runner）时，音频链路会降级为静音并记录 `audio: playback unavailable (...)`，视频与输入不受影响，服务端不再崩溃；设备稍后出现会自动重试。
- **音频输出切换/蓝牙耳机重连**：蓝牙耳机断开再连接、插拔带扬声器的显示器等导致系统默认输出变化时，客户端会自动重建音频输出图，日志出现 `audio: playing to default output (...; graph #n)`，无需重连会话；仍无声时可查 `audio: retrying output` 与 `audio: playback unavailable`。同时会通知被控端暂停当前媒体，日志出现 `media: paused the current Now Playing app`；这是预期行为，不是被控端自己停了。若某播放器不响应系统 Now Playing，暂停可能无效。
- **被控端媒体暂停**：开启音频转发后，日志出现 `media: paused the current Now Playing app` 表示当前播放器已暂停，不是设备被静音；默认不会改动系统静音/音量。只有显式加 `--local-mute` 才会出现 `audio: muted local output ...`，断开后出现 `audio: restored local output ...`。若旧版本曾被 `SIGKILL` 且留下 `~/Library/Application Support/BoltKVM/mute-state.json`，新服务端启动时会先恢复并删除该标记。
- **虚拟屏创建失败**：连续重试仍拿不到虚拟屏时，服务端以退出码 3 退出并交给守护逻辑重启，不会回退去采集本地真实桌面（避免把操作者自己的桌面推给主控端）。

## 里程碑

详细背景与指标定义见 [项目设计文档](docs/design/project-charter.md)。

- [x] **M0 前置验证**：虚拟显示与雷雳链路基线（[报告](docs/reports/2026-10-21-m0-display.md)；显示层已通过，真无头拔线、睡眠/唤醒、音频可听性与物理延迟基准仍在 [未完成事项](docs/plans/open-items.md) 跟踪）
- [x] **M1 视觉等价**：采集 → 硬编 → 直传 → 硬解 → Metal 上屏（60 fps、SSIM 0.984，[报告](docs/reports/2026-10-21-m1-pipeline.md)）
- [x] **M2 输入链路**：快捷键、修饰键同步、连续滚动相位注入（[报告](docs/reports/2026-10-21-m2-input.md)）
- [x] **M3 稳定性**：权限自检、断线重连、8 小时长稳（[soak 报告](docs/reports/2026-10-22-m3-soak-8h.md)）与 CLI 8 小时输入连续性（[夜间报告](docs/reports/2026-10-22-night-run.md)）
- [x] **应用化**：单应用双角色、内建虚拟显示、多主机连接管理、可选音频、自动发布（[报告](docs/reports/2026-10-22-app-conversion.md)）

## 文档索引

- [项目设计文档](docs/design/project-charter.md)
- [未完成事项](docs/plans/open-items.md)
- [发布流程](docs/releasing.md)
- [连接管理器设计](docs/plans/2026-10-22-connection-manager-design.md)
- [B5 帧率与延迟报告](docs/reports/2026-10-23-b5-latency.md)
- [音频与 GUI 稳定性报告](docs/reports/2026-10-23-audio-and-gui-stability.md)
- [传输加密报告](docs/reports/2026-10-22-transport-encryption.md)
- [全部验证报告索引](docs/reports/README.md)
- [架构决策记录（ADR）索引](docs/adr/README.md)、[实施计划](docs/plans/)

## 环境要求

- macOS 15+（Apple Silicon）；
- 雷雳网桥（Thunderbolt Bridge）直连，或任意可达的局域网 IP 连接；
- 从源码构建需安装 Swift 6 / Xcode Command Line Tools；
- CI 在 `macos-15` 上使用 runner 自带的 Swift 6.1.2，与本地更新版本可能行为不同；升级工具链后请以 CI 为准（踩坑记录见 [发布流程](docs/releasing.md)）。

## 贡献指南

提交代码前请阅读 [AGENTS.md](AGENTS.md)。每个可独立交付的变更单元应确保编译与测试通过，并同步更新相关文档。

## 许可证

[MIT](LICENSE)，第三方代码许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
