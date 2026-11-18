# 全屏"状态栏收不起来"：macOS 27.2.1 上 NSToolbarFullScreenWindow 滞留带（2026-11-18）

## 现象

用户报告：运行久了之后，全屏操作出问题——主控机顶部的状态栏（标题栏/工具栏带子 + 其上的系统菜单栏区域）在全屏下出现后不再收起，指针移开也不消失。当日 14:2x 进全屏后复现，退全屏重进无效，顶边驻留自愈也无效；重启主控端 app 后清除。

这是 [2026-11-02 全屏工具栏滞留报告](2026-11-02-fullscreen-toolbar-stuck.md) 所冻结问题（当时定案「回退 245 原样 + 重启清除」）的复发与重开。**与 11-02 的关键差异：系统已从 27.0.1 升级到 27.2.1，当日实测发现「真实 show→hide 配对可自愈」已不再成立，冻结决定的前提失效，故重开。**

## 取证（~/Library/Logs/BoltKVM.log，build 270）

- 14:2x 进全屏：`chrome applied (fullscreen=true)` 后紧跟一条无配对的 `toolbar hidden`——0.7s/0.15s 预热舞步与 0.2s tick 竞争的卡死签名（11-02 报告根因 2），此后该全屏周期再无任何 shown/hidden。
- 14:31 重进全屏：日志里 6 组 `shown 82 pt → hidden` 配对完全正常——**flag 层面健康，视觉上带子仍在**。27.0.1 时代的自愈手段失效。

## 根因（27.2.1 探针实测，非推断；探针脚本在 docs/_scratch/fs-*.swift）

用与产品同逻辑的独立 AppKit 探针在 macOS 27.2.1 (26B131) 上重跑（指针真实驱动到顶边，`screencapture -x` 同步截屏判定像素）：

1. **hidden 态不再撤下子窗口**：`toolbar.isVisible = false` 只把 `NSToolbarFullScreenWindow` 子窗口从 66 pt 缩到 32 pt（菜单栏条高度），子窗口仍 order 在屏、alpha=1、并**真实合成到屏幕上**——截屏测得顶部 21% 像素为浅色材质（红绿灯 + 标题栏材质），盖在全屏画面顶端。这就是用户看到的"收不起来的状态栏"。
2. **窗口层面无法区分健康/卡死**：hidden/shown 两种状态下子窗口的 ordered/alpha/位置全部一致（仅高度 32↔66），因此 11-02 时代基于 ordered/alpha 的滞留判定失效。
3. **子窗口的 view 树在 hidden 态也画满不透明像素**（`cacheDisplay` 实测 100% opaque），不是透明占位。
4. **真实 show→hide 配对不再自愈**（探针连做 3 组配对，带子照旧）；253 的 alpha=0 自愈未再尝试（27.0.1 已证会吞键盘）。
5. **`orderOut` 是唯一能真正撤下带子的调用**：orderOut 后截屏顶部 0% 亮像素，带子彻底消失。
6. **orderOut 后 `isVisible=true` 唤不回工具栏**（与 27.0.1 探针结论一致）；但 `isVisible=true` 之后补一次显式 `child.orderFront(nil)`，工具栏连同「动作」按钮完整回来（截屏 44% 亮像素 = 健康 shown 态基线 45.3%），两轮显隐循环稳定。
7. 进全屏时 AppKit 自己就把子窗口 order 在屏（无需预热参与），因此预热舞步不是带子的必要条件，只是当年的卡死放大器。

## 改动（`Sources/BoltKVMCore/App/ClientController.swift`）

- **删除预热舞步**（进全屏 0.7s 后的 alpha=0 可见 pass 及 `fullScreenToolbarPrimed`）：它是 11-02 卡死的来源（唯一 alphaValue 写入点），在 27.2.1 上也不再有任何收益。
- **隐藏走 `hideFullScreenToolbar()`**：`isVisible = false` 之后立即 `child.orderOut(nil)`——隐藏=真消失。
- **唤出走 `revealFullScreenToolbar()` 新路径**：`isVisible = true`，下一轮 runloop 若子窗口仍未在屏则 `orderFront(nil)`（AppKit 已在此期间完成 sizing，items 完整）。
- **tick 不变量**：全屏下 flag=false 且子窗口在屏 → 立即 orderOut。兜住进全屏过渡期 AppKit 的自行 order-in、菜单栏弹出时的重排等一切未知路径；隐藏不再可能滞留。
- 0.2s 顶边驻留、110pt 迟滞、`titleVisibility`/分隔线处理、几何下移逻辑全部保持不变。

## 验证

```bash
swift build -c release   # 通过（24.6s）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --scratch-path .build
# Executed 112 tests, with 1 test skipped and 0 failures（与基线一致）
```

探针（`/tmp/fsprobe6`，自动驱动指针 + 相位同步截屏）：

- h1/h2（隐藏+orderOut）：顶部亮像素 **0.0%**——带子彻底消失；
- r1/r2（唤出+orderFront）：**44.0%**——工具栏完整（健康基线 45.3%），两轮稳定；
- 对照组（纯 flag 隐藏）：21.3% 亮像素滞留——复现用户现象。

## 未验证

- 真实双端会话（主控 GUI + mini 被端）的全屏人工复测：进全屏无带、顶边驻留弹出（52/82 pt 跟随菜单栏）、离开完全隐藏、工具栏按钮点击——待用户替换本机 app 后确认；
- 菜单栏弹出与 orderOut 的交互：探针的 CGWarp 无法唤出系统菜单栏（需要真实鼠标移动事件流），「菜单栏弹出把子窗口下推」路径未被直接演练；tick 不变量应能兜住，若出现 ≤0.2s 闪烁再收紧不变量条件；
- 旧版 macOS（<27.2.1）行为未回归测试：orderOut 对正常显隐是冗余但无害的调用（orderOut 一个已不在屏的窗口是 no-op），理论无影响；
- 长跑（多日不重启）下的稳定性未验证，按仓库节奏先 10 分钟冒烟。
