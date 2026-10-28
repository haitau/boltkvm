# 全屏工具栏首次弹出无按钮：从自定义浮层回到原生工具栏（2026-10-28）

## 现象

新启动应用后进入全屏，第一次把指针移到屏幕顶边，工具栏出现但没有「调度中心」「桌面」按钮；把指针移开、再移到顶边，第二次弹出的工具栏才有按钮。窗口模式一直正常。

为绕开这个问题，曾把全屏工具栏改成内容视图里的 `NSVisualEffectView` 浮层。用户实测后反馈浮层“不如原生工具栏”，截图里菜单栏下方出现一条黑色带，按钮文字被压在浅色带底边、裁掉一半；它没有复现 macOS 屏幕共享的观感，因此该方案被放弃。

## 根因

【事实】全屏工具栏由 AppKit 的 `NSToolbarFullScreenWindow` 承载。该窗口在第一次 `toolbar.isVisible = true` 时才创建，基于 `NSToolbarItem.view` 的自定义按钮视图在首次显示时没有完成布局；第二次显隐复用了已经布局好的窗口，所以按钮出现。

【事实】自定义浮层放在 `contentView` 的 `bounds.height - chromeHeight` 位置，按内容坐标从顶部 0 pt 开始；全屏时系统菜单栏占屏幕顶部 30 pt，原生工具栏实际在 y=30、高 68 pt。浮层顶部被菜单栏压住，剩下的高度只够露出文字下半截，正是用户截图中的黑带 + 裁字。

【事实】`toolbar.isVisible = false` 之后，全屏工具栏子窗口仍留在屏幕上；它本身没有画出按钮时，就表现为一条空白/透明带。

【推断】这是 macOS 27.0.1 上 `NSToolbarFullScreenWindow` 对 view-based item 的首次布局时序问题，和 A-4 的标题栏白线不是同一处。

## 最终改动

- 删除自定义浮层与 `orderOut` 子窗口的路径，恢复真正的原生 `NSToolbar`。
- 「调度中心」「桌面」改为标准 `NSToolbarItem`：`label`、`image`（SF Symbols）、`toolTip` 和 `target/action` 都由 AppKit 绘制，不再塞自定义 `NSStackView`。
- 状态文字仍用原生工具栏项里的 `NSTextField`，保持在最右侧。
- 第一次顶边显隐做一次“显示 → 隐藏 → 显示”的预热：
  - 第一次 `isVisible = true` 让 AppKit 创建 `NSToolbarFullScreenWindow`；
  - 下一个 runloop 隐藏，再在 200 ms 后显示；进入全屏 0.7 s 后还会在指针不在顶边时做一次隐藏预热；
  - 之后同一全屏会话直接显示，不再重复预热。
- 居中：使用 macOS 13+ 的 `centeredItemIdentifiers = [tbMission, tbDesktop]`，把两个标准项作为一个居中集合。旧的 `centeredItemIdentifier` 只能指定一个锚点，窗口从 1200 pt 拉宽到远端尺寸后两个按钮会留在右侧；必须在 `window.toolbar` 赋值后再设置该属性。窗口标题改为 `titleVisibility = .hidden`，避免标题和居中按钮重叠。
- 画面位移使用全屏工具栏窗口的实际下沿：菜单栏显示时是 30 + 68 = 98 pt，菜单栏自动隐藏时是 68 pt（窗口模式仍是 52 pt）。之前只按固定 52/68 下移，远端画面会顶到菜单栏/工具栏下沿，或留下黑带。
- 窗口模式保留原生标题栏材质、交通灯和分隔线策略；标题隐藏，52 pt 标题栏里只显示图标（toolTip 可读），全屏 68 pt 工具栏显示图标和文字。

## 验证

```bash
swift build -c release --disable-sandbox --scratch-path .build
# 通过；app 版本 0.12.2 (215)

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --scratch-path .build
# Executed 92 tests, with 1 test skipped and 0 failures
```

本机 macOS 27.0.1、3008×1692 逻辑分辨率：

1. 窗口模式截取主窗口顶部：原生工具栏显示 `调度中心` / `桌面` 两个标准项（图标 + 文字）与右侧 `已连接 · 60 fps · ... · P3` 状态，没有自定义浮层的黑带/裁字。
2. 进入全屏后第一次移动指针到顶边，日志：
   - `fs: toolbar shown at the top edge (content shifted down by 68/98 pt)`（本次实测菜单栏自动隐藏时为 68 pt）；
   - `CGWindowList` 中 `NSToolbarFullScreenWindow` 为 3008×68、位于 y=30；
   - 首次预热后同一会话后续显隐正常。
3. 退出全屏 `AXFullScreen=false`，窗口模式工具栏仍在。
4. 远端画面在全屏工具栏显示时按工具栏窗口下沿下移，隐藏时铺满。

## 未验证 / 边界

- ScreenCaptureKit 和系统 `screencapture` 都不采集 `NSToolbarFullScreenWindow` 子窗口；本机无法用一张静态截图直接展示全屏按钮像素，只能由窗口模式截图、子窗口尺寸、显隐日志和首次预热路径推断。用户实机观感仍需确认。
- 只在本机 macOS 27.0.1 上验证；未在旧版 macOS、多显示器、深色/浅色外观逐一切换验证。
- 首次预热会有一次极短的 toolbar 显隐；进入全屏 0.7 s 后若指针不在顶边会先做一次隐藏预热，用户在顶边首次触发时还会做一次 200 ms 的兜底显隐。
- A-4 的长周期白线闪烁仍未做长时间录屏确认。

## 相关文件

- `Sources/BoltKVMCore/App/ClientController.swift`
- `Packaging/Resources/{zh-Hans,en}.lproj/Localizable.strings`
