# 全屏工具栏首次弹出无按钮修复（2026-10-28）

## 现象

新启动应用后进入全屏，第一次把指针移到屏幕顶边，工具栏浮层出现但没有「调度中心」「桌面」按钮；把指针移开、再移到顶边，第二次弹出的工具栏才有按钮。窗口模式一直正常。

## 根因

【事实】全屏工具栏由 AppKit 的 `NSToolbarFullScreenWindow` 承载。该窗口在第一次 `toolbar.isVisible = true` 时才创建，基于 `NSToolbarItem.view` 的按钮视图在首次显示时没有完成布局；第二次显隐复用了已经布局好的窗口，所以按钮出现。

【事实】`toolbar.isVisible = false` 之后，这个全屏工具栏子窗口仍留在屏幕上并覆盖内容视图顶部；它本身没有画出按钮，因此表现为一条空白/透明的顶部带，第一次的点击也落不到按钮上。

【推断】这是 macOS 27.0.1 上 `NSToolbarFullScreenWindow` 的首次布局时序问题，和 A-4 的标题栏透明/白线修复不是同一处。

## 改动

- 全屏不再依赖 AppKit 的原生工具栏浮层，改用内容视图内的 `NSVisualEffectView` 浮层：
  - 浮层在窗口创建时就建好并完成按钮布局，第一次顶边停留即可显示；
  - 浮层包含与窗口模式一致的「调度中心」「桌面」，并新增「退出全屏」；
  - 右侧沿用 `fps · Mbps · 缩放/P3` 状态文字，颜色随连接状态变化。
- 全屏时隐藏原生 `NSToolbar`，并在每次布局时把 `NSToolbarFullScreenWindow` 子窗口 `orderOut`，避免它覆盖浮层。
- 窗口模式完全保留原生 `NSToolbar`：标题栏、两个按钮和状态标签的行为不变。
- `ChromeLayout.videoFrame` 的位移逻辑未改；浮层显示时仍把远端画面整体下移 52 pt，隐藏时铺满全屏。

## 验证

构建与测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --scratch-path .build
# Executed 91 tests, with 1 test skipped and 0 failures

BOLTKVM_SWIFT_BUILD_FLAGS="--disable-sandbox --scratch-path .build" ./Packaging/build-app.sh
# ==> dist/BoltKVM.app
```

本机 macOS 27.0.1、3008×1692 逻辑分辨率，实测：

1. 重新安装并启动应用，连接被控端，进入全屏；**第一次**把指针移到顶边，截图已能看到「调度中心」「桌面」「退出全屏」三个按钮和右侧状态文字，不需要第二次上移。
2. 点击浮层「退出全屏」，`AXFullScreen` 从 `true` 变为 `false`，回到窗口模式；窗口模式的原生工具栏仍显示「调度中心」「桌面」和状态。
3. 指针移开顶边超过隐藏阈值后，浮层消失；截取顶部 260 px，没有空白工具栏带，也没有白线残留。
4. 浮层显示时远端画面整体下移，浮层隐藏时铺满全屏；未改变 `ClientChromeLayoutTests` 的几何。

## 未验证 / 边界

- 只在本机 macOS 27.0.1 上做了视觉验证；未在旧版 macOS、多显示器、深色/浅色外观逐一切换验证。
- 浮层是内容视图内的本地视图，不参与远端输入转发；按钮点击已实测「退出全屏」，`调度中心`/`桌面` 的点击路径与窗口模式共用同一组 selector。
- A-4 的长周期白线闪烁仍未做长时间录屏确认；本次只确认隐藏状态截帧无白线、无空白工具栏带。

## 相关文件

- `Sources/BoltKVMCore/App/ClientController.swift`
- `Packaging/Resources/{zh-Hans,en}.lproj/Localizable.strings`
