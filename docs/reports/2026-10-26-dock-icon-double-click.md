# 2026-10-26：server 双 Dock 图标 / 双击不转发

## 现象

1. Mac mini 上看到两个运行中的 BoltKVM 图标。
2. 通过客户端双击 mini 上窗口的标题栏/工具栏空白处，窗口没有缩放到最大区域；
   像是双击没有“传送过去”。

## 原因

### 两个 Dock 图标

`boltkvm-server` 是 `BoltKVM.app/Contents/MacOS/` 里的可执行文件，LaunchServices
按 app bundle 的 `io.github.boltkvm` 把它注册成第二个前台 app（`lsappinfo`
`type="Foreground"`），于是 Dock 里出现两个 BoltKVM。

另外 `AppMain` 启动时先 `setActivationPolicy(.regular)`，等 delegate 进入 server
角色再切 `.accessory`；这个顺序会先注册一个 Dock 图标，切换后可能残留。

### 双击不缩放

`InputEvent` 里没有 click count；`WindowInputCapture` 只转发 down/up，
`Server` 注入时又把 `mouseEventClickState` 硬编码成 1。远端收到的永远是单击，
双击标题栏自然不会触发 zoom。

## 修复

- `CLI.runServer` 最前面调用 `TransformProcessType(...ToBackgroundApplication)`，
  让 helper 以 background app 运行。
- `AppMain.run` 在 `app.run()` 之前按角色设置策略：server 用 `.accessory`，
  其他用 `.regular`。
- `InputEvent` 的第 47 字节（原来的 padding）改为 `clickCount`，48 字节布局不变；
  旧客户端发 0 时按 1 处理。
- 窗口客户端取 `NSEvent.clickCount`，全局 tap 取 `mouseEventClickState`；
  `Server` 注入时把 click state 设为 `ev.clickCount`。

提交：`ef05be3`、`d50a66c`。

## 验证

- 部署 mini 后 `lsappinfo`：
  - `BoltKVM`（app）`type="UIElement"`
  - `boltkvm-server` `type="BackgroundOnly"`
  - Dock 不再出现第二个图标；进程、虚拟屏 3008×1692、监听 7474 正常。
- 客户端诊断日志实测：第二次按下 `n=2`；服务端收到
  `click=2 at (1300, 400)`。协议单测覆盖第 47 字节和旧包 0→1。
- 合成的双击打到 mini 的 Finder 标题栏后，Finder 窗口 bounds 未变化；
  该次测试的落点/焦点是否准确尚未确认。真实双击的 zoom 需要用户在
  客户端实机复核。
- 原始命令与输出见提交 `9d028b0` 的正文/本报告摘录；日志未入库。

## 备注

- server 的设置面板是 `[.titled, .closable]` 固定尺寸，不是 resizable，
  因此双击它自己的标题栏不会 zoom；如果用户指的是这个面板而不是远端窗口，
  需要单独把它改成可缩放并调整布局。
- 部署脚本在极短时间内 kill + open 时偶发 app 以 Foreground 注册；退出后
  重新打开会恢复 UIElement。正常登录启动不复现。

## 证据分级

- 【事实】部署 mini 后的 `lsappinfo` 结果：`BoltKVM`（app）为 `type="UIElement"`、`boltkvm-server` 为 `type="BackgroundOnly"`，Dock 不再出现第二个图标，进程、虚拟屏 3008×1692 与监听 7474 正常。
- 【事实】客户端诊断日志实测第二次按下 `n=2`，服务端收到 `click=2 at (1300, 400)`；协议单测覆盖第 47 字节与旧包 0→1 的兼容。
- 【推断】两个 Dock 图标的成因（LaunchServices 按 bundle id 把 helper 注册成第二个前台 app，以及先 `.regular` 再切 `.accessory` 的时序）是机制解释，报告未给出 `lsappinfo` 完整输出或注册时序日志。
- 【未经核实】远端窗口双击 zoom 的实际表现：合成双击打到 mini 的 Finder 标题栏后 bounds 未变化，且该次落点/焦点是否准确未确认；真实双击需在客户端实机复核；若用户指的是 server 自己的设置面板而非远端窗口，则需单独把它改成可缩放（见备注第 1 条）。
- 【未经核实】「部署脚本 kill + open 时偶发以 Foreground 注册、重新打开恢复」只有观察记录，未复现也未留存日志。
