# 全屏"菜单不自动隐藏"：NSToolbarFullScreenWindow 滞留屏幕（2026-11-02）

## 现象

用户报告：全屏模式下 BoltKVM 的菜单（顶部菜单栏 + 工具栏带子）出现后不再自动隐藏，指针移开也不消失。当天上午 09:06–09:11 连续三次进全屏均复现；前一晚 22:19 同一进程内弹出/隐藏还完全正常。

## 取证（~/Library/Logs/BoltKVM.log，无代码变化、同一进程 PID 256）

- 11-01 22:19（进全屏后约 1 分钟内）：`toolbar shown … 82 pt` / `toolbar hidden` 多次成对出现——正常。
- 11-02 09:06 起三次进全屏：进入后各只有一条 `toolbar hidden`（预热窗口与 5 Hz tick 竞争所致），**没有任何 `toolbar shown`**；tick 循环本身活着（进出全屏的 `chrome applied` 都在）。
- 结论：不是某次提交引入的回归，而是**进全屏时的预热流程与 tick 竞争后落入了坏状态**；能否自愈取决于用户之后是否在顶边触发一次真实 reveal。

## 根因（探针实测，非推断）

用独立探针复刻 ClientController 的 chrome 逻辑（原生 NSToolbar、0.7 s/0.15 s 预热、顶边驻留 0.2 s、110 pt 迟滞隐藏）：

1. 在这台 macOS 27.0.1 上，`toolbar.isVisible = false` **不会把 `NSToolbarFullScreenWindow` 子窗口从屏幕撤下**（与 2026-10-28 报告记录的"子窗口仍留在屏幕上"是同一个事实）。AppKit 自己的全屏过渡也可能把它留在屏幕上且不透明。
2. 旧预热的收尾把 `fullScreenToolbarWindow?.alphaValue` 置回 **1**：若 tick 恰好落在预热 0.15 s 的可见窗口内（指针在画面里时几乎必然），时序为 `alpha=0 → isVisible=true →（tick）isVisible=false → alpha=1`，最终状态是 **flag=false 而子窗口 order 在屏、alpha=1**——工具栏带子 + 系统菜单栏永久卡在画面顶部。
3. `tickChrome` 以 `toolbar.isVisible` 判断状态，读到 false 后隐藏分支永不触发（日志里连 `toolbar hidden` 都不再出现）；reveal 分支也不会触发（带子已在屏上，用户没有必要去顶边唤出）——**状态无法自愈**。
4. 昨晚正常的原因：用户进全屏后在顶边驻留触发了一次真实 reveal（`shown 82 pt`），真实 show→hide 配对把 AppKit 状态修正了。

探针截图确认卡住的画面 = 系统菜单栏 + 标题栏/工具栏带子叠在全屏画面顶部。

## 改动（`Sources/BoltKVMCore/App/ClientController.swift`）

- 新增 `setFullScreenToolbarShown(_:)`：全屏下显/隐工具栏时同步驱动子窗口 alpha（显 1 / 隐 0），不再单独信任 `isVisible`。
- 新增 `fullScreenToolbarActuallyVisible`（含纯函数 `toolbarActuallyVisible(flag:childOrdered:childAlpha:)`）：把"滞留的不透明子窗口"视为可见。5 Hz 轮询用它做隐藏判定（自愈），`layoutVideo` 也改用它，画面位移与实际在屏带子保持一致。
- 预热收尾不再把 alpha 置回 1（就是这一行把带子重新点亮）：预热全程 alpha=0，真实 reveal 时才恢复 1；预热的 guard 改用 actually-visible，避免在坏状态上再叠一次可见 pass。
- reveal 两条路径、进出全屏转换、隐藏分支统一走 `setFullScreenToolbarShown`。

## 验证

```bash
swift build -c release   # 通过
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --scratch-path .build
# Executed 110 tests, with 1 test skipped and 0 failures（新增 5 项滞留状态判定测试）
```

探针（与产品同逻辑的独立 AppKit 程序，自动驱动指针）：

- 复现版：预热后子窗口 `vis=true alpha=1.00` 滞留 20 s 不消失，且 `toolbar.isVisible=false`——与用户现象一致；
- 修复版：进全屏后即使落进坏状态，0.2 s 内被自愈为 `alpha=0`；顶边驻留 reveal（alpha=1）、离开顶边隐藏（alpha=0）、退出再进全屏第二循环，断言全部通过。

## 未验证

- 真实双端会话（主控 GUI + mini 被控端）里的全屏显隐尚未人工复测，待用户替换 /Applications 里的 245 后确认；
- 预热窗口与 tick 的竞争本身未消除（保留了预热），只是坏状态可自愈；若后续仍有首次 reveal 空带，再考虑移除预热。

---

# 追记（同日晚些）：滞留修好了，但与 AppKit 原生唤出打架 → 改为自绘全屏工具条

## 现象（250 版本，重启后）

- 卡死消失（自愈在工作），但出现新问题：顶边唤出时菜单栏不弹（日志 `shifted down by 52 pt`，正常是 82 pt）、调度中心/桌面按钮不显示（空带），且日志出现**连续十几拍 `toolbar hidden` 而无 `shown`**——每拍我们隐藏、AppKit 又自己唤出，打架 8 秒。

## 根因（native 探针，只写一次 `isVisible=false` 后不再干预）

这台 macOS 27.0.1 的原生行为是：**全屏一进入，`NSToolbarFullScreenWindow` 就以 alpha=1 挂在屏幕上，之后无论指针怎么动都不隐藏**；只有菜单栏跟着指针在顶边弹出（offset 30 pt）。也就是说这个仓库一直在用轮询+预热去驯服一个系统根本不维护的状态机——空白首弹（10-28）、全天卡死（11-02 上午）、显隐打架（11-02 下午）三轮 bug 同源。继续在原生工具栏上打补丁没有出路。

## 最终改动：全屏工具条改为自有子窗口（`ClientController.swift`）

- 进全屏：**卸下 NSToolbar**（`window.toolbar = nil`，保存引用）——原生浮层彻底退场；构建自有 bar：无边框子窗口（`.fullScreenAuxiliary` + `addChildWindow`），titlebar 材质，左侧窗口标题、居中「调度中心 / 桌面 / 退出全屏」按钮（NSButton + SF Symbols），右侧状态；**显示= `orderFront`，隐藏= `orderOut`，状态机只剩我们自己**。
- 退出全屏：隐藏 bar，把 NSToolbar 原样装回（reattach 探针验证 items/居中标识/工具栏带完整恢复）。
- 菜单栏让位：系统在菜单栏弹出时会把我们的 bar 子窗口往下推约 30 pt（与当年推 `NSToolbarFullScreenWindow` 同一机制），画面位移 = bar 高度 + `screenTop - bar.frame.maxY`（沿用原 childTop 逻辑）。
- 删除：预热、reveal 舞步、`setFullScreenToolbarShown` alpha 驱动、`toolbarActuallyVisible` 启发式及其测试。0.2 s 顶边驻留 + 110 pt 迟滞保留（这是产品 UX，与底层窗口无关）。
- 桌面按钮「还原窗口」文案切换、状态栏 `fps · Mbps` 同步到 bar 上的对应控件。
- 新增本地化键 `client.toolbar.exitFullscreen(.tip)`（中英）。

## 验证

```bash
swift build -c release   # 通过
swift test               # 105 项通过（1 skip）；删除随启发式一起失效的 5 项
```

三个探针（均自动驱动指针）：

1. `native`：证明原生行为=永久可见（见上），排除"少干预"路线；
2. `ownbar`：自有 bar 显隐循环 3 轮无打架，截图确认观感（材质/居中按钮/右侧状态）与原生几乎一致；
3. `reattach`：全屏卸载→恢复 NSToolbar 两轮循环，items/居中标识/工具栏带全部完整。

## 未验证

- 真实双端会话的全屏人工复测：顶边驻留弹出、离开隐藏、菜单栏弹出时 82 pt 跟随、bar 按钮点击（调度中心/桌面/退出全屏）、窗口↔全屏往返后窗口工具栏完好——待用户部署 0.13 (251) 后确认。
