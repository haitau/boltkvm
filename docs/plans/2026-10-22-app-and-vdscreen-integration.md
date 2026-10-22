# 内建虚拟显示与应用化：方案与实施计划

- 状态：待决策
- 日期：2026-10-22
- 关联：[ADR 0001](../adr/0001-thin-self-built-layer.md)（自研薄层主路径）

## 0. 结论先行

| 问题 | 建议 |
|---|---|
| 要不要把 vdscreen 合进来 | **要**，但不是把它当包依赖——它没有库；把它的 **402 行 ObjC 核心**中约 70 行（创建 + HiDPI 核对）vendor 成一个 SPM C target |
| 能不能做成标准 app | **能**，两个 `.app`（Server 菜单栏、Client 全屏）共享一个 Core 库，SPM + 打包脚本产出，不用 Xcode 工程 |
| 最大收益是什么 | **TCC 归属从 Terminal 转到 app 本体**，现在"必须从 GUI Terminal 启动服务端"这条最别扭的运维约束直接消失 |

两周到三周可以到"双击即用"的形态，分 5 个阶段，每阶段都能单独验收、单独回退。

## 1. 事实盘点（2026-10-22 核实）

上游 `lyonDan/vdscreen`：MIT，默认分支 `main`，最后更新 2026-10-18，**没有 SPM 包，没有库产物**。

| 文件 | 内容 | 对我们的价值 |
|---|---|---|
| `vdscreen.m` (402 行) | ObjC 核心：创建虚拟屏、HiDPI 核对与回退、布局恢复、主屏切换 | **创建 + 核对约 70 行**是要的，其余不要 |
| `CGVirtualDisplayShim.h` (45 行) | 私有类声明 | 直接用 |
| `vdscreen` (zsh) | CLI 包装 | 不要 |
| `vdscreen-bar.swift` (26KB) | 菜单栏 App、URL scheme、快捷键 | 不要，但可参考 LSUIElement 写法 |
| `build.sh` | `clang -fobjc-arc ...` + `swiftc` + 手写 Info.plist | **打包方式的直接参考**：不用 Xcode 工程也能出签名 .app |

本机现状（mini）：`/Applications/VDScreenBar.app` v1.3.4，LaunchAgent `io.github.lyondan.vdscreen` 托管 `vdscreen-core`，显示器与进程同生命周期。

现在一次完整部署要维护 **6 个东西**：boltkvm 二进制、supervisor 脚本、登录项 `.command`、vdscreen.app、vdscreen 的 LaunchAgent、以及"必须从 Terminal 启动"这条人工约束。

## 2. 问题一：vdscreen 怎么进来

### 2.1 四个选项

| | A 上游做成 SPM 包 | B vendor 核心为 SPM target | C Swift 重写（objc runtime） | D 维持外部依赖 |
|---|---|---|---|---|
| 需要上游配合 | 是（无库产物，得提 PR） | 否 | 否 | 否 |
| 单一部署 | 是 | 是 | 是 | 否 |
| 私有 API 风险 | 与现状相同 | 相同 | 相同（还得自己趟 HiDPI 坑） | 相同 |
| 工作量 | 不可控（等 PR） | 1–2 天 | 3–5 天 | 0 |
| 许可合规 | 干净 | 需保留 LICENSE + NOTICE | 干净 | 干净 |
| 能否修上游 bug | 要等 | 本地可改 | 自家代码 | 要等 |

**推荐 B。** 理由：

1. vdscreen 的知识价值集中在两处「非显然」的实现——HiDPI 需要同时满足 `maxPixels=2×`、`sizeInMillimeters=逻辑×0.254`、modes 同时声明逻辑与 2× 模式；以及**macOS 会按显示器身份记住上次模式**，所以必须显式 `CGConfigureDisplayWithDisplayMode` 切到 HiDPI 变体（失败再试 `CGDisplaySetDisplayMode`，各等 0.8s）。重写等于重新踩这些坑。
2. A 不可控：上游是 CLI + 菜单栏 App 的形态，没有拆库的动机，不能把计划押在别人的 PR 上。
3. B 只 vendor 我们要的部分，不是整个仓库。

### 2.2 落法

```
Sources/
  CVirtualDisplay/            ← 新增 SPM target（C 家族）
    include/
      BKVVirtualDisplay.h     ← 对外 C API：create/apply/destroy/displayID/modeIsHiDPI
      CGVirtualDisplayShim.h  ← 上游原样（保留版权头）
    BKVVirtualDisplay.m       ← 从 vdscreen.m 抽 ~70 行
    THIRD_PARTY_NOTICES.md    ← 上游 LICENSE 全文 + 来源 commit
  BoltKVMCore/                ← 现有代码搬进来（阶段 3）
  boltkvm/                    ← CLI，继续存在
```

Swift 侧通过 `import CVirtualDisplay` 调用。SPM 对 C 家族 target 会自动生成 module map，不需要手写。

对外只暴露一个窄接口：

```c
typedef struct BKVVirtualDisplay BKVVirtualDisplay;
BKVVirtualDisplay *BKVVirtualDisplayCreate(const char *name, int w, int h, int hiDPI);
int  BKVVirtualDisplayDisplayID(BKVVirtualDisplay *d);
int  BKVVirtualDisplayIsHiDPI(BKVVirtualDisplay *d, int w, int h);
void BKVVirtualDisplayDestroy(BKVVirtualDisplay *d);
```

生命周期归 Swift 的 `VirtualDisplayService` 管：创建 → 校验模式 → 拿 `displayID` 给 ScreenCaptureKit → 进程内 watchdog 监听 `terminationHandler`（上游只 `fprintf`，我们改成回调）→ 掉了就重建。

### 2.3 迁移安全

先加一层协议，双实现并存：

```swift
protocol VirtualDisplayProviding {
    func start(width: Int, height: Int, name: String, hiDPI: Bool) throws -> CGDirectDisplayID
    func stop()
    var onLost: (() -> Void)? { get set }
}
final class ExternalVDScreen: VirtualDisplayProviding { }   // 调 vdscreen-core，现状
final class BuiltinVirtualDisplay: VirtualDisplayProviding { }  // 新
```

`--virtual-display=external|builtin` 切换，跑同一套验收（`vdscreen status` 等价物、SCK 能抓到、客户端出画面、拔掉重建）。两边都过再删 `ExternalVDScreen`。

### 2.4 一个已知的构建坑

私有类在头文件里只有 `@interface`，链接时 `_OBJC_CLASS_$_CGVirtualDisplayDescriptor` 这类符号要么被 CoreGraphics 导出，要么得放开未定义符号。vdscreen 的 `clang` 命令行能直接过，说明当前系统是导出的；但 SPM 链接参数不同，若报 undefined symbol，加：

```swift
linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]
```

`unsafeFlags` 会让这个 target 不能被别的包依赖，但我们本来就是应用不是库，可以接受。

## 3. 问题二：能不能做成标准 app

能，而且这是解决 TCC 那条死结的正路。

### 3.1 目标形态

```
BoltKVM.app (Server)     LSUIElement 菜单栏，无 Dock 图标
  ├─ 内建虚拟显示（替换 vdscreen.app + LaunchAgent）
  ├─ ScreenCaptureKit 采集 + VideoToolbox 编码
  ├─ 监听 7474，状态菜单：客户端连接数 / 分辨率 / 帧率 / 最近错误
  └─ SMAppService 注册开机自启（替换登录项 + .command）

BoltKVM Client.app       全屏窗口 + 输入捕获 + 连接面板
  ├─ Metal 1:1 呈现
  ├─ CGEventTap 输入（TCC 授予本 app，不再授予 Terminal）
  └─ ⌃⌥⌘Q 退出

BoltKVMCore.framework    两端共享：Protocol / Server / Renderer / Audio / VirtualDisplay
```

一个二进制带子命令也可以（`BoltKVM.app/Contents/MacOS/BoltKVM --mode=server`），但**两个 bundle 更干净**：TCC 按 bundle 授权，服务端只需要"屏幕录制"，客户端只需要"辅助功能/输入监控"，混在一个 bundle 里会让客户端莫名要求屏幕录制权限。

### 3.2 打包方式：SPM + 脚本，不引入 Xcode 工程

`build.sh` 的办法已经被上游验证过：`clang`/`swiftc` 出二进制 + 手写 Info.plist + `codesign`，不需要 `.xcodeproj`。

对我们的好处：
- 仓库保持纯 SPM，CI 一条命令可复现；
- 避免 `project.pbxproj` 的合并冲突（本项目一直单文件、小步提交）；
- 需要资源（图标、nib）时再考虑 Xcode，目前不需要 nib。

`Packaging/` 目录：

```
Packaging/
  build-app.sh          # swift build -c release → 组装 .app → codesign → 可选 notarize
  Server-Info.plist     # LSUIElement, NSScreenCaptureUsageDescription
  Client-Info.plist
  Server.entitlements   # 目前不需要额外权限，先留空模板
  AppIcon.icns
```

关键 Info.plist 键：`LSUIElement=1`（服务端无 Dock）、`NSScreenCaptureUsageDescription`（首次采集弹窗文案）、`LSMinimumSystemVersion=13.0`、`CFBundleIdentifier` 用 `io.github.<user>.boltkvm.server` / `.client`。

### 3.3 TCC 的变化（这是重点）

| | 现在 | app 化之后 |
|---|---|---|
| 屏幕录制 | 授予 **Terminal.app**，launchd 启动必失败 | 授予 BoltKVM Server.app，系统弹窗一次，之后任何启动方式都有效 |
| 输入监控 | 授予 Terminal（客户端也跑在 Terminal 里） | 授予 BoltKVM Client.app |
| 自启 | 登录项 + `.command` + Terminal 窗口常驻 | `SMAppService.mainApp.register()`，无窗口 |
| 权限丢失 | 升级 macOS 后静默失败，靠 doctor 事后发现 | 同样会丢，但 `CGPreflightScreenCaptureAccess()` 可在启动时检测并引导 |

这一条把"服务端必须从 GUI Terminal 启动"彻底消灭——那是本项目最反直觉的运维约束，也是重启恢复链里最脆的一环。

### 3.4 分发

| 方式 | 前提 | 结果 |
|---|---|---|
| 本地构建（ad-hoc 签名） | 无 | 能双击运行，首次要右键打开 / `xattr -d`，**不能给别人** |
| Developer ID + 公证 | 付费开发者账号（$99/年） | 可分发 DMG，别人双击即用 |
| App Store | — | **不可行**：私有 API + 监听端口，两条都违反审核规则 |

公证不是技术问题而是账号问题，先按 ad-hoc 做，脚本里留 `SIGN_IDENTITY` / `NOTARY_PROFILE` 两个变量，有账号时改一行。

## 4. 分阶段计划

| 阶段 | 内容 | 验收 | 估时 |
|---|---|---|---|
| 0 | 核对上游 LICENSE 与 `vdscreen.m` 的抽取边界（只需创建 + 核对 + terminationHandler） | 确定 vendor 范围，写出 NOTICE | 0.5 天 |
| 1 | `CVirtualDisplay` target + `VirtualDisplayService` + 协议双实现 | `--virtual-display=builtin` 起服务端，客户端出画面；`vdscreen status` 不再需要；杀掉服务端后显示器消失、重启后重建 | 2–3 天 |
| 2 | 删掉 `ExternalVDScreen`，mini 上卸 vdscreen.app 与它的 LaunchAgent | 部署件从 6 件降到 4 件；重启恢复仍通过 | 0.5 天 |
| 3 | 抽出 `BoltKVMCore`（Protocol/Server/Renderer/Audio/VirtualDisplay 移入），CLI 变薄壳 | CLI 全功能不回退，`swift build` 通过，8h 冒烟 | 1–2 天 |
| 4 | `BoltKVM Client.app`：全屏窗口、输入、连接面板、退出快捷键 | 双击即连；TCC 弹出的是 Client.app；输入延迟与 CLI 版一致 | 2–3 天 |
| 5 | `BoltKVM Server.app`：菜单栏、状态项、SMAppService 自启、权限引导 | 冷启动到可连 < 10s；重启后无人工步骤；`doctor` 三项全绿 | 3–4 天 |
| 6 | `Packaging/build-app.sh` + 图标 + 签名 | 一条命令产出两个 .app；`codesign -dv` 正常；断开 Terminal 也能跑 | 1–2 天 |

合计约 **10–16 个工作日**。阶段 1–2 是纯收益（少一个进程、少一个 LaunchAgent），阶段 4–6 才是"像个 app"。

## 5. 收益量化

| 指标 | 现在 | 之后 |
|---|---|---|
| 部署件 | 6（二进制、supervisor、登录项、vdscreen.app、vdscreen LaunchAgent、Terminal 约束） | 2（两个 .app） |
| 启动前提 | 必须 GUI Terminal | 双击 / 开机自启 |
| 显示器生命周期 | 外部进程，靠轮询发现丢失 | 进程内回调，立即重建 |
| 权限归属 | Terminal（脆弱，重装/升级易丢） | app bundle（稳定） |
| 升级 | 手动 scp + codesign + 重启 | 替换 .app |

## 6. 风险与未决

1. **私有 API**：`CGVirtualDisplay` 不属于任何兼容性承诺，macOS 更新可能改行为或移除。风险现在就有，整合不新增；但 app 化之后如果它失效，退路是"回到外接物理屏"或换 DeskPad 同类实现。
2. **公证账号**：没有付费账号就只能自用。**这是唯一需要你拍板的外部依赖**。
3. **双 bundle 的代码签名一致性**：两个 app 用同一个 Team ID 签，否则 SMAppService 与 keychain 访问会有意外。
4. **迁移期双轨**：阶段 1–2 需要同时保留旧路径，`--virtual-display` 开关是回退阀门。
5. **输入捕获的 TCC 差异**：`CGEventTap` 在 app 里需要"输入监控"授权，用户可能只给了辅助功能；需要在启动时检测并提示。

## 7. 不做什么

- 不做 App Store 分发（私有 API + 监听端口，必被拒）。
- 不做 iOS/iPadOS 客户端（不在 charter 范围）。
- 不为了一次性打包引入 `.xcodeproj`；真需要 nib/资源目录时再评估。
- 不 fork 整个 vdscreen 仓库（只取 70 行 + 头文件，保留版权与许可）。
