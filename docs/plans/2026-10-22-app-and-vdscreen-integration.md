# 内建虚拟显示与应用化：方案与实施记录

- 状态：已完成（阶段 1–9 全部落地并实测，2026-10-22；阶段 7–9 的逐项证据见第 4 节与后续的音频/GUI、B5 报告）
- 日期：2026-10-22
- 关联：[ADR 0001](../adr/0001-thin-self-built-layer.md)、[应用化验证报告](../reports/2026-10-22-app-conversion.md)

## 1. 核心决策

| 议题 | 决策 |
|---|---|
| 虚拟显示器如何集成 | 从开源 `lyonDan/vdscreen`（MIT）抽取约 70 行 Objective-C 核心逻辑（创建虚拟屏、HiDPI 模式核对与切换、移除回调）与私有头文件 `CGVirtualDisplayShim.h`，封装为 `Sources/CVirtualDisplay` C Target |
| 应用形态 | 单一 `BoltKVM.app` 包含「被控端」与「主控端」两种角色，首次启动选择角色并保存在 `UserDefaults` 中，随时可通过菜单切换；使用 SwiftPM + `Packaging/build-app.sh` 组装打包，不引入 `.xcodeproj` |
| 核心收益 | 将 TCC 权限归属从 `Terminal.app` 转移到独立的 `BoltKVM.app`，消除「必须从 GUI 终端启动服务端」的运维限制，将 6 个分散部署件收敛为 1 个 `.app` |

## 2. 虚拟显示模块（`CVirtualDisplay`）设计

### 2.1 为什么采用源码精简引入（Vendor）

1. `vdscreen` 上游为 CLI + 菜单栏应用形态，未提供 SwiftPM 库产物；
2. 虚拟显示最关键的经验在于两处非直观实现：
   - HiDPI 需要同时满足 `maxPixels = 2×`、`sizeInMillimeters = 逻辑尺寸 × 0.254` 且同时声明 1× 与 2× 模式；
   - macOS 会按显示器身份记住上次模式，创建后必须显式调用 `CGConfigureDisplayWithDisplayMode`（失败回退 `CGDisplaySetDisplayMode`）切到 HiDPI 模式；
3. 只引入创建、核对与 `terminationHandler` 回调约 70 行代码，保留上游 MIT 许可声明（见根目录 `THIRD_PARTY_NOTICES.md`）。

### 2.2 目录与接口

```text
Sources/
  CVirtualDisplay/            # SwiftPM Objective-C target
    include/
      BKVVirtualDisplay.h     # C 接口：Create / DisplayID / IsHiDPI / Destroy
      CGVirtualDisplayShim.h  # CoreGraphics 私有类声明
    BKVVirtualDisplay.m       # 虚拟屏创建与 HiDPI 切换实现
  BoltKVMCore/                # 核心库（协议、采集、编解码、渲染、UI 控制器）
  boltkvm/                    # CLI 可执行入口
  BoltKVMApp/                 # GUI 应用入口
```

对外暴露最小 C 接口：

```c
typedef struct BKVVirtualDisplay BKVVirtualDisplay;

BKVVirtualDisplay *BKVVirtualDisplayCreate(const char *name, int width, int height, int hiDPI);
uint32_t BKVVirtualDisplayID(const BKVVirtualDisplay *display);
int      BKVVirtualDisplayIsHiDPI(const BKVVirtualDisplay *display);
int      BKVVirtualDisplayBackingPixels(const BKVVirtualDisplay *display, int *outWidth, int *outHeight);
void     BKVVirtualDisplaySetLostHandler(BKVVirtualDisplay *display,
                                         void (*handler)(void *context), void *context);
void     BKVVirtualDisplayDestroy(BKVVirtualDisplay *display);
```

`BKVVirtualDisplayCreate` 只在主线程调用：私有 API 会把工作交给主队列，函数内部泵主 run loop 等待模式生效（HiDPI 协商时最长约 4 秒）；系统拒绝创建时返回 `NULL`，服务端据此以退出码 `3` 退出，由父进程重启。

## 3. 单应用双角色架构

### 3.1 角色分工

| 维度 | 被控端（`server` 角色） | 主控端（`client` 角色） |
|---|---|---|
| 界面形态 | 菜单栏图标常驻 + 被控端设置面板 | 被控端列表窗口 + 远端桌面渲染窗口 |
| 激活策略 | `.accessory`（无主窗口时隐藏 Dock 图标） | `.regular` |
| 所需 TCC 权限 | 屏幕录制 + 辅助功能（注入事件） | 本地网络（macOS 15+；窗口内输入监听无需 TCC） |
| 开机自启 | 支持（`SMAppService.mainApp`） | 不注册 |
| 子进程托管 | 监督应用包内 `Contents/MacOS/boltkvm-server` 子进程 | 无子进程，进程内直接解码与 Metal 渲染 |

### 3.2 为什么被控端采用「GUI 主进程 + `boltkvm-server` 子进程」

实测表明，在 GUI 应用主进程内直接调用 `BKVVirtualDisplayCreate` 会被系统拒绝或退化为 LoDPI（3008×1692 像素而非 6016×3384），而在普通命令行进程中则完全稳定。因此被控端采用与 `vdscreen` 相同的父子进程分工：

- `BoltKVM.app` 主进程负责菜单栏、设置面板、开机自启与权限检查；
- 虚拟屏创建、ScreenCaptureKit 采集与网络监听由包内的 `boltkvm-server`（即 CLI 二进制，避免在大小写不敏感的 APFS 上与主程序 `BoltKVM` 重名）子进程执行；
- 父子进程通过未写入的 `stdin` 管道绑定生命周期：父进程退出时子进程收到 `EOF` 立即退出并释放虚拟屏；虚拟屏被系统移除或创建失败时子进程以退出码 `3` 退出，由父进程在 3 秒后自动重启重建；
- macOS TCC 权限遵循「责任进程（Responsible Process）」机制，授予 `BoltKVM.app` 的屏幕录制与辅助功能权限自动覆盖 `boltkvm-server` 子进程。

### 3.3 打包与签名

打包脚本 `Packaging/build-app.sh` 直接从 SwiftPM Release 产物组装 `dist/BoltKVM.app`，包含：

- `Packaging/Info.plist`：`LSMinimumSystemVersion = 15.0`、`NSLocalNetworkUsageDescription`（macOS 15+ 访问局域网/雷雳网桥必需）、中英双语本地化声明；
- `Packaging/AppIcon.icns`：由 `swift scripts/make-icon.swift` 代码生成；
- 本地稳定签名：`./scripts/make-signing-identity.sh` 在用户钥匙串创建 `BoltKVM Local` 自签名证书，配合 `BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local"` 构建可避免重编译后 TCC 权限失效。

## 4. 实施阶段与验收记录

| 阶段 | 内容 | 验收结果（2026-10-22） |
|---|---|---|
| 0 | 核对上游 MIT 许可与抽取边界 | 完成根目录 `THIRD_PARTY_NOTICES.md` |
| 1 | `CVirtualDisplay` Target + `--virtual-display builtin` | 虚拟屏 `3008×1692 / 6016×3384 HiDPI` 创建成功，客户端 60.4 fps、`failed=0` |
| 2 | 默认切换为 `builtin`，移除外置 `vdscreen` | 单块内建虚拟屏稳定 59.8 fps；确认两块虚拟屏并存会导致 SCK 跌至 3–8 fps |
| 3 | 抽取 `BoltKVMCore` 公共库 | CLI 精简为薄入口，`swift build`、`selftest`、`cryptotest`、`doctor` 全部通过 |
| 4 | 主控端 GUI 窗口与 Metal 渲染 | 首次启动角色选择、连接管理、全屏与等比缩放正常 |
| 5 | 被控端菜单栏、设置面板与开机自启 | 重启被控端后自动登录并拉起服务，主控端直连出流 58.3 fps |
| 6 | 打包脚本、生成图标与本地自签名证书 | `dist/BoltKVM.app` 签名校验通过，重编译不丢失 TCC 授权 |
| 7 | 中英双语本地化 | `Localizable.strings` 覆盖全部界面文案，并由 `LocalizationTests` 校验键值完整性 |
| 8 | 主控端免 TCC 窗口输入捕获 | `NSEvent` 本地监听 + 画面区域 `hitTest` 分流，移出画面或失焦自动释放修饰键 |
| 9 | 无头虚拟屏防休眠 | 服务端常驻持有 `PreventUserIdleDisplaySleep` 断言，消除静止桌面休眠冻屏问题 |

阶段 7–9 的原始验收数据不在本文件，分别见 [应用化报告](../reports/2026-10-22-app-conversion.md)、[音频与 GUI 稳定性报告](../reports/2026-10-23-audio-and-gui-stability.md) 与 [B5 延迟报告](../reports/2026-10-23-b5-latency.md)。
