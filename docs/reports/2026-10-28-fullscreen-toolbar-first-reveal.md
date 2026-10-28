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
- 动作按钮居中：使用 `centeredItemIdentifiers = [tbMission, tbDesktop]` 把两个标准项作为一组居中。标题仍显示 `BoltKVM — 主控端`，状态仍在工具栏最右侧；只改按钮水平位置，不隐藏标题、不改状态位置。
- 画面位移使用 `contentLayoutRect` / 工具栏 host 给出的**可见工具栏高度**；本机实测为 52 pt（窗口模式也是 52 pt）。**不要用 `NSToolbarFullScreenWindow` 的完整高度 68 pt**：这个子窗口底部有 16 pt 透明区域，按 68 pt 下移会在工具栏和远端画面之间留下一条 16 pt 黑带。菜单栏在本机是覆盖层，不增加这个值；若旧版系统把菜单栏计入布局，代码会直接采用更大的实测值，不写死 98。
- 窗口模式保留原生标题栏材质、交通灯、标题和分隔线策略；状态标签保持最右。

## 验证

```bash
swift build -c release --disable-sandbox --scratch-path .build
# 通过；app 版本 0.12.2 (221)

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --scratch-path .build
# Executed 93 tests, with 1 test skipped and 0 failures
```

本机 macOS 27.0.1、3008×1692 逻辑分辨率：

1. 窗口模式截取主窗口顶部：标题仍在左，`调度中心` / `桌面` 两个标准项居中，`fps · Mbps` 状态在最右，没有自定义浮层的黑带/裁字。
2. 进入全屏后第一次移动指针到顶边，日志：
   - `fs: toolbar shown at the top edge (content shifted down by 52 pt)`（本机菜单栏显示/隐藏时均为 52 pt）；
   - `CGWindowList` 中 `NSToolbarFullScreenWindow` 为 3008×68，其中 `_toolbarView` 实际可见高度 52 pt；
   - 首次预热后同一会话后续显隐正常。
3. **2026-10-28 追加修复黑条**：用户截图显示工具栏下方仍有一条黑带。几何日志为 `layout=(0,0,3008,1640) child=(0,1624,3008,68) host=(0,0,3008,52) video=(0,-68,3008,1692)`，即画面按 68 pt 下移、实际可见工具栏只有 52 pt，多出的 16 pt 正好是黑带。改为按 `contentLayoutRect` 的 52 pt 下移后，日志为 `video=(0,-52,3008,1692)`；截图行扫描中工具栏在 102 px（2×）结束，远端菜单栏从 104 px 开始，中间没有空白行。
4. 退出全屏 `AXFullScreen=false`，窗口模式工具栏仍在。
5. 远端画面在全屏工具栏显示时按可见工具栏高度下移，隐藏时铺满。

## 未验证 / 边界

- ScreenCaptureKit 和系统 `screencapture` 都不采集 `NSToolbarFullScreenWindow` 子窗口；本机用整屏截图的行扫描确认工具栏与远端菜单栏之间没有空白行，但按钮像素仍只能由窗口模式截图与几何日志验证。用户实机观感仍需确认。
- 旧版 macOS 若把菜单栏计入 `contentLayoutRect`，值可能大于 52；本机未复现该布局，代码按实测值自适应。
- 只在本机 macOS 27.0.1 上验证；未在旧版 macOS、多显示器、深色/浅色外观逐一切换验证。
- 首次预热会有一次极短的 toolbar 显隐；进入全屏 0.7 s 后若指针不在顶边会先做一次隐藏预热，用户在顶边首次触发时还会做一次 200 ms 的兜底显隐。
- A-4 的长周期白线闪烁仍未做长时间录屏确认。

## 相关文件

- `Sources/BoltKVMCore/App/ClientController.swift`
- `Packaging/Resources/{zh-Hans,en}.lproj/Localizable.strings`
