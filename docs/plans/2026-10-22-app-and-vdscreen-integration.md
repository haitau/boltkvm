# 内建虚拟显示与应用化：方案与实施计划

- 状态：待决策
- 日期：2026-10-22
- 关联：[ADR 0001](../adr/0001-thin-self-built-layer.md)（自研薄层主路径）

## 0. 结论先行

| 问题 | 建议 |
|---|---|
| 要不要把 vdscreen 合进来 | **要**，但不是把它当包依赖——它没有库；把它的 **402 行 ObjC 核心**中约 70 行（创建 + HiDPI 核对）vendor 成一个 SPM C target |
| 能不能做成标准 app | **能**，而且应该是**一个 app**：首次启动选"被控"还是"主控"，角色存在偏好里，随时可切。SPM + 打包脚本产出，不用 Xcode 工程 |
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

### 3.1 目标形态：一个 app，两个角色

```
BoltKVM.app
  首次启动：这台 Mac 要做什么？
    ○ 被控（共享这台屏幕）   → 角色 server
    ○ 主控（连接另一台 Mac） → 角色 client
  菜单栏常驻，随时可切；角色写进 UserDefaults
```

| | server 角色 | client 角色 |
|---|---|---|
| 窗口 | 无窗口，菜单栏图标 | 全屏渲染窗口 + 连接面板 |
| 激活策略 | `.accessory`（无 Dock 图标） | `.regular` |
| TCC | 屏幕录制 + 辅助功能（注入事件） | 输入监控（捕获事件） |
| 自启 | `SMAppService.mainApp` 注册 | 不注册 |
| 单实例 | 必须（端口独占，已有 PID 文件逻辑） | 不要求 |

两台机器各装同一个 app、各选一个角色；它们几乎不会同时需要跑在同一台机器上，所以"一个进程同时做两端"的复杂度其实不必付出。

**为什么改掉了原来的两个 app**：最初的理由是"最小权限"和"生命周期不同"。但 macOS 的 TCC 是**懒弹窗**——只有在第一次真正调用时才请求：

- 只有 server 角色第一次开采集时才会弹"屏幕录制"；
- 只有 client 角色第一次 `CGEventTap` 时才会弹"输入监控"。

所以单个 bundle 并不会让纯客端的用户被要求授权屏幕录制。权限论据不成立，那就没有理由拆成两个包、两份签名、两次公证。

而且两端的权限需求本来就不同（server 是屏幕录制 + 辅助功能，client 是输入监控），同一份代码在两个角色下只申请各自那几项。

剩下的差异都能在运行时处理：`NSApp.setActivationPolicy()` 切 Dock 图标，菜单栏切换角色，server 角色启动时加单实例锁。

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
  Info.plist            # 一份，两个角色共用
  AppIcon.icns
```

关键 Info.plist 键：`NSScreenCaptureUsageDescription`（首次采集弹窗文案）、`LSMinimumSystemVersion=13.0`、`CFBundleIdentifier=io.github.<user>.boltkvm`。**不要**写死 `LSUIElement`——启动后按角色调用 `setActivationPolicy`，写死在 plist 里反而会让 client 角色没有 Dock 图标。

### 3.3 TCC 的变化（这是重点）

| 权限 | 哪个角色要 | 现在授予谁 | app 化之后 |
|---|---|---|---|
| 屏幕录制 | server | **Terminal.app**，launchd 启动必失败 | BoltKVM.app（只在切到 server 角色、首次采集时弹） |
| 辅助功能（post events） | server | Terminal | 同上 |
| 输入监控（listen events） | client | Terminal | BoltKVM.app（只有 client 角色会弹） |
| 自启 | server | 登录项 + `.command` + Terminal 窗口常驻 | `SMAppService.mainApp.register()`，无窗口 |

| 权限丢失 | 升级 macOS 后静默失败，靠 doctor 事后发现 | 同样会丢，但 `CGPreflightScreenCaptureAccess()` 可在启动时检测并引导 |

这一条把"服务端必须从 GUI Terminal 启动"彻底消灭——那是本项目最反直觉的运维约束，也是重启恢复链里最脆的一环。

### 3.4 分发

| 方式 | 前提 | 结果 |
|---|---|---|
| 本地构建（ad-hoc 签名） | 无 | 能双击运行，首次要右键打开 / `xattr -d`，**不能给别人** |
| Developer ID + 公证 | 付费开发者账号（$99/年） | 可分发 DMG，别人双击即用 |
| App Store | — | **不可行**：私有 API + 监听端口，两条都违反审核规则 |

公证不是技术问题而是账号问题，先按 ad-hoc 做，脚本里留 `SIGN_IDENTITY` / `NOTARY_PROFILE` 两个变量，有账号时改一行。

**ad-hoc 有个坑**：TCC 记录的签名身份对 ad-hoc 是 cdhash，重新构建一次 cdhash 就变，权限全要重授。解决成本很低——在钥匙串里建一个自签名的代码签名证书（如 "BoltKVM Local"），用 `codesign -s "BoltKVM Local"` 签名，TCC 就按这个稳定身份记，重编译不用重授。这个证书不需要开发者账号。

## 4. 分阶段计划

| 阶段 | 内容 | 验收 | 估时 |
|---|---|---|---|
| 0 | 核对上游 LICENSE 与 `vdscreen.m` 的抽取边界（只需创建 + 核对 + terminationHandler） | 确定 vendor 范围，写出 NOTICE | 0.5 天 |
| 1 | `CVirtualDisplay` target + `--virtual-display=builtin` | **已完成 2026-10-22**：`id=7 logical=3008x1692 backing=6016x3384 hiDPI=true`（创建耗时 2.1 s），客户端 888 帧 / 60.4 fps / `failed=0`；恢复 external 后 469 帧无回归。未测：`onLost` 回调（需要系统主动移除显示器） | 2–3 天 |
| 2 | 默认改成 builtin，服务端按 displayID 精确采集，mini 上移走 vdscreen.app 与它的 LaunchAgent | **已完成 2026-10-22**：单块内建屏 3008×1692/6016×3384 HiDPI，客户端 588 帧 / 10 s（59 fps），服务端 `captured=480 fps=59.8`；`boltkvm displays` 只剩一块 | 0.5 天 |
| 3 | 抽出 `BoltKVMCore`（Protocol/Server/Renderer/Audio/VirtualDisplay/Client/InputCapture/Watchdog 移入），CLI 变成 40 行调度器 | **已完成 2026-10-22**：`swift build` 通过，`cryptotest` PASS，`doctor` 四项全 PASS，客户端 587 帧 / 10 s、服务端 `fps=59.8 dropped=0` | 1–2 天 |
| 4 | 单 app 骨架：角色选择、菜单栏常驻、client 全屏窗口 + 输入 + 连接面板 | **客户端已完成 2026-10-22**：`dist/BoltKVM.app` 首启选角色，连接面板连上 mini 后 decode 60.5 fps / render 55.4 fps（窗口 2400×1448）；服务端角色已实现但未在 mini 实测；输入延迟与全屏未实测 | 3–4 天 |
| 5 | server 角色：无窗口菜单栏、状态项、权限引导、SMAppService 自启、单实例锁 | **已完成并实测 2026-10-22**：菜单栏状态项（监听中/已连接/失败）、非模态权限引导、`SMAppService.mainApp` 开机自启、单实例锁；采集循环改为 app 内 bundled 的 `boltkvm-server` 子进程（见 4.4）。实测：重启 mini 后无人干预自动拉起 → `virtual display: id=5 3008x1692 backing=6016x3384 hiDPI=true` → `listening`，客户端随即连上（434 帧 / 8 s，服务端 58.3 fps） | 2–3 天 |
| 6 | `Packaging/build-app.sh` + 图标 + 自签名证书 | **已完成 2026-10-22**：`scripts/make-icon.swift` 代码画图标 → `AppIcon.icns`；`scripts/make-signing-identity.sh` 一键生成并信任 "BoltKVM Local"（无开发者账号、无 sudo）；`codesign -dvvv` 显示 CMS 签名 + hardened runtime（size=1678，非 adhoc） | 1–2 天 |

合计约 **10–16 个工作日**。阶段 1–2 是纯收益（少一个进程、少一个 LaunchAgent），阶段 4–6 才是"像个 app"。

### 4.1 实施中发现：两块虚拟屏会互相拖垮

排查帧率时踩到一个大坑：两块 3008×1692 虚拟屏同时在线（内建屏 + 残留的 vdscreen 屏），ScreenCaptureKit 掉到 **3–8 fps**，而且**两块都慢**——不是被采的那块慢，是整体被拖下来。只留一块立刻回到 57–60 fps。

所以"内建虚拟屏"和 vdscreen 不能同时在跑。阶段 2 把 vdscreen 从 mini 上移走（`~/Disabled/VDScreenBar.app`，LaunchAgent 与登录项一并删除），既解决了依赖，也消除了这个隐患。

顺带确认了两件事：

- `minimumFrameInterval` 从 0 改成 `1/60` 反而慢 3 fps（57.0 vs 59.8），已回退到 0；
- 创建失败（同身份已存在）时不能 `exit`，否则守护循环会反复重启。改成打日志、退化为采集现有显示器。

### 4.2 本地网络权限（macOS 15+）

app 第一次连内网地址报 `No route to host`：macOS 15 起「本地网络」是独立 TCC 项，Info.plist 必须带 `NSLocalNetworkUsageDescription`，否则连接直接被拒，错误信息完全看不出是权限问题。补上后立刻 60 fps。ad-hoc 签名每次构建 cdhash 都变，等于每次都是新 app，权限要重给——这是阶段 6 自签名证书要解决的核心问题。

### 4.3 签名身份与 TCC

ad-hoc 签名（`-`）每次构建 cdhash 都变，macOS 把每个构建当成新 app，屏幕录制、本地网络、输入监控的授权全部作废——今天被这件事咬了三次。解法是用自己的代码签名证书：

```bash
./scripts/make-signing-identity.sh                  # 生成并信任 "BoltKVM Local"（用户域，不需要 sudo）
BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local" ./Packaging/build-app.sh
```

证书自签、没有 Team ID，但 TCC 认的是「bundle id + 证书叶」，同一张证书重复签名身份不变，授权就不再丢。`codesign -dvvv` 里的 `Signature size=1678` + `flags=0x10000(runtime)` 说明确实带上了签名。

图标也是代码：`swift scripts/make-icon.swift Packaging/AppIcon.icns`，仓库里不放二进制素材。

### 4.4 GUI 进程建不出可靠的虚拟屏

app 直接在自己进程里调 `BKVVirtualDisplayCreate` 时，同样的代码会出现两种坏结果：被系统拒绝（`applySettings` 返回 NO），或者创建成功但掉成 LoDPI（3008×1692 而不是 6016×3384），同一台机器上 CLI 二进制却次次正常。换签名、去 hardened runtime、换 identity 都没用，问题在「GUI 进程上下文」本身。vdscreen 早就绕开了这件事——它的 app 也只是 UI，虚拟屏由其 `vdscreen-core` helper 持有。

所以服务端角色改成：app 只做菜单栏、权限、自启、单实例和状态解析，采集/编码/监听交给 bundle 内的 `boltkvm-server`（就是原来的 CLI），由 app 用 `Process` 拉起并读它的 stdout/stderr 更新状态，异常退出 3 秒后重启。TCC 记在「责任进程」上，app 拿到的屏幕录制授权对子进程同样有效，用户只需要授权一次。

还有个小坑：helper 不能叫 `boltkvm`——APFS 默认大小写不敏感，`cp` 到 `Contents/MacOS/boltkvm` 会直接覆盖主程序 `BoltKVM`，签名后表现为 app 打不开。

## 5. 收益量化

| 指标 | 现在 | 之后 |
|---|---|---|
| 部署件 | 6（二进制、supervisor、登录项、vdscreen.app、vdscreen LaunchAgent、Terminal 约束） | 1（BoltKVM.app） |
| 启动前提 | 必须 GUI Terminal | 双击 / 开机自启 |
| 显示器生命周期 | 外部进程，靠轮询发现丢失 | 进程内回调，立即重建 |
| 权限归属 | Terminal（脆弱，重装/升级易丢） | app bundle（稳定） |
| 升级 | 手动 scp + codesign + 重启 | 替换 .app |

## 6. 风险与未决

1. **私有 API**：`CGVirtualDisplay` 不属于任何兼容性承诺，macOS 更新可能改行为或移除。风险现在就有，整合不新增；但 app 化之后如果它失效，退路是"回到外接物理屏"或换 DeskPad 同类实现。
2. **公证账号**：没有付费账号就只能自用。**这是唯一需要你拍板的外部依赖**。
3. **角色切换的状态迁移**：单 app 的主要复杂度来源。server→client 要释放端口、销毁虚拟屏；client→server 要停输入捕获、清空渲染器。需要一个显式状态机，而不是散落的 if。
4. **迁移期双轨**：阶段 1–2 需要同时保留旧路径，`--virtual-display` 开关是回退阀门。
5. **输入捕获的 TCC 差异**：`CGEventTap` 在 app 里需要"输入监控"授权，用户可能只给了辅助功能；需要在启动时检测并提示。

## 7. 不做什么

- 不做 App Store 分发（私有 API + 监听端口，必被拒）。
- 不做 iOS/iPadOS 客户端（不在 charter 范围）。
- 不为了一次性打包引入 `.xcodeproj`；真需要 nib/资源目录时再评估。
- 不 fork 整个 vdscreen 仓库（只取 70 行 + 头文件，保留版权与许可）。
