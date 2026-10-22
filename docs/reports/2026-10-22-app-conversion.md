# 单 app 化与内建虚拟显示（阶段 1–6）

日期：2026-10-22
范围：把「CLI + vdscreen 外挂」的部署方式收成一个 `BoltKVM.app`，两个角色共用一套采集/传输/渲染代码。

## 一句话结论

mini 已从「CLI 守护循环 + vdscreen 虚拟屏」切换为「`/Applications/BoltKVM.app` + SMAppService 登录项」，重启后无人干预自动起服务；Pro 的 app 作为主控端连上后 57 fps / 977 Mbps，服务端 58–60 fps。vdscreen 已从 mini 移走。

## 做了什么

| 阶段 | 内容 |
|---|---|
| 1 | vendored `CVirtualDisplay`（vdscreen MIT 代码，固定 commit），`--virtual-display builtin` 由进程自己建屏 |
| 2 | 默认改 builtin，采集按 displayID 精确锁定，mini 移除 vdscreen（app 与 LaunchAgent/登录项） |
| 3 | 抽出 `BoltKVMCore`，CLI 变成 40 行调度器，app 与 CLI 共用实现 |
| 4 | 单 app 骨架：首启选角色、主控端窗口（连接面板 + Metal 画面 + 全屏） |
| 5 | 被控端：菜单栏状态项、非模态权限引导、`SMAppService.mainApp` 自启、单实例锁 |
| 6 | `Packaging/build-app.sh`、代码生成的图标、自签名代码签名证书 |

## 实测

| 项目 | 结果 |
|---|---|
| CLI 服务端（单块内建屏） | `captured=480 encoded=480 dropped=0 fps=59.8 bitrate=522.7Mbps encLat=7.50ms` |
| 客户端（CLI，同一次） | 588 帧 / 10 s |
| app 主控端窗口渲染 | `decode 60.5 fps` / `render 447 帧 55.4 fps drawable=2400x1448 latency p50=27.2ms p95=29.3ms` |
| app 服务端（子进程） | `fps=58.3 bitrate=703.2Mbps dropped=0` |
| app → app 全链路 | 客户端 `57 fps · 977 Mbps`，服务端 `58.2 fps / 1004 Mbps` |
| 重启恢复（无人工步骤） | 开机 → app 自启 → 子进程建屏 `id=5 3008x1692 / 6016x3384 HiDPI` → `listening`，客户端随即连上（434 帧 / 8 s） |

## 输入链路（app 部署）

主控端不需要任何 TCC：`NSEvent.addLocalMonitorForEvents` 只监听本窗口，再用 `contentView.hitTest` 判断指针是否在画面视图内，在画面里才转发并吞掉，连接栏/菜单/快捷键照常本地可用。被控端需要「屏幕录制 + 辅助功能」两项。

| 项目 | 结果 |
|---|---|
| 坐标映射 | 客户端视图内 (600,372)/1200×724 → 归一化 (0.5,0.486) → 远端 (1504,822)，mini 光标实测停在 1504,822 |
| 鼠标注入 | 连续移动/点击，mini 光标跟随，停止后停在最后一个映射点 |
| 键盘注入 | 140 次按键 → 服务端 `input events=120 keys=120`（走同一条 `CGEvent.post` 注入路径） |
| 事件分流 | 指针在连接栏时事件不进服务端；在画面内才计数 |
| 全屏 | 按钮点击：`AXFullScreen true`、窗口 3008×1692；再点回 `false`、1200×788 |

**未能独立取证的一项**：合成 ⌘⇧3 在本机注入也不触发截图，说明 macOS 限制合成系统快捷键；因此键盘注入只能证明到「事件到达服务端注入函数」这一层，键盘在远端产生的实际效果没有独立观察。

## 关键发现

1. **两块虚拟屏会互相拖垮**：两块 3008×1692 虚拟屏同时在线时 ScreenCaptureKit 掉到 3–8 fps，两块都慢；只留一块立刻回到 57–60 fps。今天上午所有「帧率崩塌」的观测都是这个原因（残留的 vdscreen 屏）。
2. **GUI 进程建虚拟屏不可靠**：同样的 C 代码 CLI 次次成功，放进 app 里要么被拒绝、要么掉成 LoDPI。服务端角色改为监督 bundle 内的 `boltkvm-server` 子进程（vdscreen 也是这么做的），TCC 由责任进程继承。
3. **macOS 15 起「本地网络」是独立 TCC 项**：Info.plist 缺 `NSLocalNetworkUsageDescription` 时连接只报 `No route to host`。
4. **ad-hoc 签名会重置所有 TCC**：每次构建 cdhash 都变。改用自签名证书（`scripts/make-signing-identity.sh`）后授权可跨构建保留。
5. **APFS 大小写不敏感**：`Contents/MacOS/boltkvm` 会覆盖主程序 `BoltKVM`，helper 必须叫别的名字（现为 `boltkvm-server`）。

## 帧率：45 fps 之谜与一个真 bug

关掉 mini 的屏幕共享后重测，帧率先是 23 fps、随后归零，`boltkvm displays` 显示

```
id=25  inactive online ASLEEP main 3008x1692
```

也就是说：**无头机器的虚拟屏在没有外部刺激时会自己睡过去**，一旦 ASLEEP，ScreenCaptureKit 不再出帧，远端画面就冻住。之前看到的 45 fps 是屏幕共享会话一直在给这块屏制造重绘，掩盖了问题；上午 59.8 fps 时也没有这个休眠窗口。

修复三处：

1. 服务端进程生命周期内持有 `PreventUserIdleDisplaySleep` 断言（原来只在每次建 capture 时短暂声明一次用户活动）；
2. 建屏后 `IOPMAssertionDeclareUserActivity` 主动唤醒；
3. 建屏失败的重试窗口从 3 秒延长到 20 秒——上一个 helper 被 kill 后，它的虚拟屏会残留（inactive/ASLEEP）几秒，占着同一个 identity，重试太短就会掉到 1920×1080 占位屏，客户端于是串流了错误的屏幕。

修复后（无屏幕共享、Pro 端 app 客户端）：

| 场景 | 服务端 | 客户端 |
|---|---|---|
| 持续有输入/画面变化 | 55–60 fps，`dropped=0`，~790 Mbps，encLat 7.9–8.8 ms | 60 fps · 771–793 Mbps |
| 静止 50 秒后 | 58.0 fps，显示器仍 `active online awake`，断言在 `pmset -g assertions` 里可见 | 画面不冻 |

顺带修了两件小事：主控端窗口关掉后没有入口再打开（加了「显示主控端窗口」菜单项和 reopen 处理）；app 刚启动时第一次连接偶尔报 `No route to host`（本地网络检查未就绪），改成 3 次重试后稳定一次成功。

## 分辨率与画质（2026-10-22 下午）

用户反馈「mini 分辨率不太对、字体宽、整体模糊」。实测两台机器都是
`3008x1692 logical / 6016x3384 pixel / 2.0x backing / 60Hz`，虚拟屏模式本身没问题，
问题出在两处：

| 现象 | 原因 | 处理 |
|---|---|---|
| 字体发宽/发扁 | 16:9 码流被拉满视频区（1200×724 ≈ 1.66:1），横向压缩约 7%；全屏时反过来被拉宽 | 着色器改成等比缩放 + 黑边，输入映射按画面矩形取坐标，点黑边放行给本地 |
| 整体模糊 | 码流固定 3840×2160，全屏（6016×3384 像素）时被放大 1.57 倍 | 新增「画面质量」：清晰 = 码流等于虚拟屏真实像素 |

服务端菜单新增（持久化，改完自动重启 helper）：

- **分辨率**：1920×1080 / 2560×1440 / 2880×1620 / 3008×1692 / 3840×2160 / 5120×2880 / 6016×3384，以及**自定义**（宽x高，640–8192）；
- **画面质量**：清晰（默认，码流 = 2× 逻辑尺寸）／标准（码流最宽 3840，给慢链路用；2× 超过 8192 宽时也自动退回按比例缩放）。

实测（雷雳桥，清晰 6016×3384）：

| | 数值 |
|---|---|
| 服务端 | 60.0 fps，1380 Mbps，`dropped=0`，encLat 12.2 ms |
| 客户端 | 60 fps，窗口视频区 1200×724，画面 1200×675（上下各 24.5pt 黑边） |
| 映射 | (1504,641)→(1504,795)、(1504,340)→(1504,41)、(1504,985)→(1504,1658)、(1000,641)→(240,795) |

清晰模式的 1.38 Gbps 只在雷雳桥（10Gbps）上验证过；Wi-Fi 下应该退回「标准」。默认值已改成「清晰」，清掉 preferences 后验证：helper 参数 `--width 6016 --height 3384`，客户端 60 fps / 1381 Mbps / dropped=0。

## 远程系统操作（调度中心 / 显示桌面 / App 窗口）

参照屏幕共享加了「远程」菜单：调度中心（多桌面）、显示 App 窗口、显示桌面。

一开始把它们实现成"注入 `⌃↑` / `⌃↓` / `F11`"，实测**不生效**：按键确实到达并被注入
（服务端 `input events=360 keys=6`），但系统级热键无视合成事件。同一条链路里
`⌘Space` 能打开远端 Spotlight（画面 79 → 188），说明注入本身没问题——被吃掉的是
`RegisterEventHotKey` 一类热键（和之前 `⌘⇧3` 截图不生效是同一个原因）。

所以改成**命令通道**：客户端发 `PacketType.command = 10` + 一个动作字节，服务端自己执行。
菜单项名称按用户口径改为 **App / 调度中心 / 桌面**。

| 动作 | 服务端实现 | 实测 |
|---|---|---|
| 调度中心 | `NSWorkspace.open("/System/Applications/Mission Control.app")` | ✅ 服务端日志 `command: missionControl`，画面结构变化（相关性 0.41）、亮度 188 → 81 |
| App（App 窗口） | System Events `key code 125 using control down` | ❌ 需要「自动化」授权，当前返回 -1743 `未获得授权将Apple事件发送给 System Events` |
| 桌面（显示桌面） | System Events `key code 103` | ❌ 同上，需要授权 |

也试过给合成事件换 event tap（hid / session / annotated）和用 `flagsChanged` 发修饰键，
都不影响系统热键的行为——这条路走不通，命令通道才是对的。

## 未验证 / 下一步

- app 部署下 >10 分钟的稳定性（今天只做了分钟级）；
- 音频在 app 里未实测（CLI 下已验）；
- 8 小时输入连续性测试仍按用户要求搁置。
