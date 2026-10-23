# 单应用化与内建虚拟显示验证报告（2026-10-22）

- 范围：将「CLI + 外置 `vdscreen`」收敛为单一 `BoltKVM.app`，被控端与主控端共用 `BoltKVMCore` 核心库。

## 1. 核心成果

被控端 Mac mini 已从早期的「CLI 脚本守护 + 外置 `vdscreen`」全面切换为 `/Applications/BoltKVM.app`（通过 `SMAppService.mainApp` 注册登录项自启），重启后无需人工干预即可自动建屏并监听；主控端 MacBook Pro 运行同一个 `BoltKVM.app` 连接后稳定在 58–60 fps。

| 阶段 | 完成内容 |
|---|---|
| 1 | 封装 `CVirtualDisplay`（源自 `vdscreen` MIT 核心代码），支持 `--virtual-display builtin` 进程内建屏 |
| 2 | 默认切换为 `builtin`，采集按 `displayID` 精确锁定，移除被控端外置 `vdscreen` |
| 3 | 抽取 `BoltKVMCore` 公共模块，CLI 精简为薄入口，App 与 CLI 共用全部核心实现 |
| 4 | 完成单 App 双角色骨架：首次启动角色选择、主控端主机列表与 Metal 渲染窗口 |
| 5 | 完成被控端菜单栏状态项、设置面板、权限引导、`SMAppService` 开机自启与 `flock` 单实例锁 |
| 6 | 完成 `Packaging/build-app.sh`、代码生成图标与 `BoltKVM Local` 本地自签名脚本 |

## 2. 端到端实测数据

| 测试项 | 实测结果 |
|---|---|
| CLI 服务端（内建虚拟屏） | `captured=480 encoded=480 dropped=0 fps=59.8 bitrate=522.7Mbps encLat=7.50ms` |
| App 主控端窗口渲染 | `decode 60.5 fps` / `render 55.4–60.0 fps`，`dropped=0` |
| App 被控端 ↔ App 主控端（清晰 6016×3384） | 服务端 `60.0 fps / 1380 Mbps / dropped=0 / encLat=12.2ms`；客户端 `60 fps` |
| 整机重启无人值守恢复 | 开机 → 自动登录 → App 自启 → 子进程建屏 `3008×1692 (6016×3384 HiDPI)` → `listening`，客户端直连出流 |

## 3. 实施中解决的关键问题

### 3.1 两块虚拟屏并存导致采集帧率暴跌

当系统同时存在两块 `3008×1692` 虚拟屏（内建屏与残留的外置 `vdscreen` 屏）时，ScreenCaptureKit 采集帧率会跌至 **3–8 fps**。移除外置 `vdscreen` 并通过 `SingleInstance` 文件锁保证单实例后，采集帧率立即恢复至 **58–60 fps**。

### 3.2 GUI 主进程建屏限制与子进程托管架构

在 GUI 应用主进程内直接调用 `BKVVirtualDisplayCreate` 会被系统拒绝或退化为 LoDPI，而在普通命令行进程中则完全稳定。因此被控端采用「GUI 主进程管菜单与面板 + 包内 `boltkvm-server` 子进程建屏与采集」的架构（子进程名设为 `boltkvm-server` 以免在大小写不敏感的 APFS 上覆盖主程序 `BoltKVM`）。

父进程通过未写入的 `stdin` 管道与子进程绑定生命周期：父进程退出时子进程检测到 `stdin EOF` 立即退出并销毁虚拟屏；同时 `log()` 底层改用忽略 `SIGPIPE` 的 `write(2)` 系统调用，消除父进程先退出时子进程写日志触发 `NSFileHandle` 异常崩溃的问题。

### 3.3 无头虚拟屏自动休眠冻屏修复

无头 Mac mini 上的虚拟屏在没有外部重绘刺激时会被系统标记为 `ASLEEP`，导致 ScreenCaptureKit 停止出帧。修复措施：

1. 服务端进程全生命周期持有 `PreventUserIdleDisplaySleep` 电源断言（`DisplaySleepAssertion`）；
2. 每次创建或重建虚拟屏后调用 `IOPMAssertionDeclareUserActivity` 主动唤醒；
3. 将建屏重试窗口延长至 20 秒，等待旧进程退出的虚拟屏身份彻底释放。

修复后静止桌面连续观察 50 秒以上，显示器始终保持 `active online awake`，帧率稳定在 58–60 fps。

### 3.4 `SCShareableContent` 首次枚举超时重试

虚拟屏刚创建完成时，首次调用 `SCShareableContent.excludingDesktopWindows` 偶发挂起不返回。通过 `withThrowingTaskGroup` 为该异步调用加上 5 秒超时与自动重试后，消除了刚启动时首次连接停滞在「正在连接…」的问题。

### 3.5 分辨率等比缩放与画质档位

- **等比缩放与黑边隔离**：Metal 顶点着色器按远端画面长宽比计算等比缩放系数，窗口比例不一致时自动留出对称黑边；窗口内 `NSEvent` 输入捕获仅在鼠标命中画面矩形时转发坐标，点击黑边或工具栏时正常交还本地处理；
- **分辨率与画质设置**：被控端支持 `1920×1080` 至 `6016×3384` 预设及自定义分辨率（偶数宽高 `640–7680` × `480–4320`），并提供「清晰」（默认，2× 真实像素原画传输）与「标准」（最大宽度限制为 3840，适合慢速链路）两档画面质量。

### 3.6 客户端工具栏与全屏自动隐藏

- 主控端窗口采用 macOS 原生 `NSToolbar`：居中放置「调度中心」与「桌面」按钮，最右侧实时显示 `fps · Mbps`；
- 全屏状态下默认隐藏工具栏与标题栏，当鼠标指针移至屏幕顶边 4 pt 以内时自动浮现工具栏，离开顶边 110 pt 以外时再次隐藏，避免工具栏展开下推指针引发闪烁抖动。

### 3.7 单实例进程锁（`flock`）

在 `~/Library/Application Support/BoltKVM/` 下使用内核级 `flock(LOCK_EX | LOCK_NB)` 维护两把锁：

- `app.pid`：保证同一台机器只运行一个 `BoltKVM.app` 实例，重复打开时自动激活已有窗口并退出；
- `server.pid`：保证同一台机器只运行一个 `boltkvm-server` 采集服务（退出码 `9` 时宿主 App 自动清理孤儿进程后重拉，避免死循环重启）。
