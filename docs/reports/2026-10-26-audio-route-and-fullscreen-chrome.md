# 蓝牙耳机重连后音频失效与全屏工具栏画面变形

- 日期：2026-10-26
- 关联提交：本次 `fix(audio)` / `fix(client)` 提交（见 `git log`）
- 关联问题：用户反馈 1）蓝牙耳机断开再连接后，被控端音频不再播放；2）全屏下指针移到顶边、工具栏浮现时，远端画面整体变形/显示不全，与 macOS 屏幕共享 App 的「工具栏浮出、画面整体下移」差距明显。

## 1. 现象与复现

### 1.1 音频

主控端开启音频后，把系统默认输出从蓝牙耳机切到内建扬声器，再切回蓝牙耳机（等价于耳机断电/重连时 macOS 的默认输出切换），被控端仍在持续发送音频包，但主控端从此无声。

用一个与 `AudioPlayer` 相同的最小 `AVAudioEngine` 探针复现（默认输出：HUAWEI FreeLace Pro）：

```text
SWITCH -> speaker
CONFIG CHANGE running=false player=true scheduled=11 out=MacBook Pro扬声器
RESTART ok running=true player=true scheduled=11
STATUS scheduled=45  running=true player=true
STATUS scheduled=145 running=true player=true
STATUS scheduled=245 running=true player=true
STATUS scheduled=256 running=true player=true
```

关键事实：引擎显示 `running=true`、播放器显示 `player=true`，但已排队的缓冲区数量一路涨到上限 `256`，之后再没有缓冲区被消费。旧代码的配置变化处理只做了 `engine.start(); player.play()`，没有重建图，也没有清掉旧图上永远等不到完成回调的计数。

### 1.2 全屏工具栏

旧实现使用普通窗口样式，全屏时通过 `window.toolbar?.isVisible = true/false` 显示工具栏。几何探针记录到：

```text
# 普通样式 + 工具栏显示
window=(0,0,3008,1640) content=(0,0,3008,1640)
# 普通样式 + 工具栏隐藏
window=(0,0,3008,1692) content=(0,0,3008,1692)
```

即工具栏浮现时 AppKit 把**窗口本身**从 1692 pt 缩到 1640 pt。内容视图（以及 Metal drawable）的宽高比随之改变，16:9 的画面只能在更矮的区域里重新等比缩放，视觉上就是「整体变形、显示不全」。macOS 屏幕共享的做法是窗口保持全屏、工具栏作为浮层，画面整体下移。

## 2. 修复

### 2.1 音频输出图重建（`Sources/BoltKVMCore/Audio.swift`）

- 每次输出路线变化都**丢弃旧图、新建 `AVAudioEngine` + `AVAudioPlayerNode`**，重新 `attach/connect/start/play`；不是在旧图上再次 `start()`。
- 重建时清空 `scheduled` 计数，并用 generation 隔离旧缓冲区的完成回调，避免旧回调把新图的计数减成负数。
- 排队的 `scheduleBuffer` 全部移到独立串行队列 `controlQueue`，重建与调度不再竞争；`lock` 只保护计数，且不在持锁时调用任何 AVAudio 接口（保持原有关窗死锁修复）。
- 同时监听 `AVAudioEngineConfigurationChange` 与 CoreAudio 的 `kAudioHardwarePropertyDefaultOutputDevice`，并在 150 ms 内去重（蓝牙一次切换会连续发多条通知）。
- 增加 2 秒健康检查：引擎/播放器停止，或 `scheduled` 达到上限且 3 秒没有完成回调时自动重建；没有输出设备时按 1→2→4…30 秒退避重试，设备出现后自动恢复。
- 原有「无输出设备不崩溃」的 `BKVTryCatching` 兜底保留。

### 2.2 全屏工具栏与画面位移（`Sources/BoltKVMCore/App/ClientController.swift`）

- 窗口样式加入 `.fullSizeContentView`。几何探针验证：工具栏显示时窗口仍为 `3008×1692`，只有 `contentLayoutRect` 变成 `1640`，不再改窗口大小。
- 视频视图不再用四边 Auto Layout 固定，改由 `ChromeLayout.videoFrame` 计算：
  - 窗口模式：画面在标题栏+工具栏下方，高度 = 内容高度 − 52 pt；
  - 全屏、工具栏隐藏：画面占满屏幕；
  - 全屏、工具栏显示：画面**尺寸不变**，整体向下平移 52 pt，底部超出屏幕（与屏幕共享一致）。
- 顶部触发增加 0.2 秒停留（实际约两个 5 Hz 轮询 tick），避免指针只是路过顶边就弹出工具栏；隐藏阈值仍保留 110 pt 迟滞。
- 工具栏显示/隐藏、进出全屏、窗口缩放、分辨率变化都重新计算画面 frame；全屏中改分辨率不再重设窗口。

## 3. 验证

### 3.1 编译与测试

```bash
swift build -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# 77 个 XCTest：76 通过、1 跳过（AudioRouteChangeTests 默认跳过，见下）
```

```bash
# 真正切换系统默认输出（会短暂改变本机输出设备，结束后恢复）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BOLTKVM_AUDIO_ROUTE_TEST=1 swift test --filter AudioRouteChangeTests
```

实测（当前输出为 HUAWEI FreeLace Pro，切到内建扬声器再切回）：

```text
audio: playing to default output (initial; graph #1)
audio: default output device changed; rebuilding output graph in 150 ms
audio: playing to default output (default output device changed; graph #2)
audio: default output device changed; rebuilding output graph in 150 ms
audio: playing to default output (default output device changed; graph #3)
Test Case '...testRebuildsAfterDefaultOutputChanges' passed (6.300 seconds)
```

新增 `ClientChromeLayoutTests` 5 项，钉住窗口模式、全屏隐藏/显示、chrome 缺失和 chrome 超界四种几何：

```text
Test Suite 'ClientChromeLayoutTests' passed
Executed 5 tests, with 0 failures
```

### 3.2 GUI 实机（本地虚拟屏 + `BoltKVM.app`）

- 起一个本地虚拟屏服务端（`--virtual-display builtin --virtual-display-size 1280x800 --port 7475 --bind 127.0.0.1`），主控端连接后进入全屏：
  - `fs: chrome applied (fullscreen=true, fullSizeContent=true)`；
  - 指针到顶边后 `fs: toolbar shown at the top edge (content shifted down by 52 pt)`；
  - 窗口 ID 抓取显示主窗口始终 `3008×1692`，工具栏是独立的 68 pt 浮层窗口；
  - 窗口截图对比：工具栏隐藏时远端画面占满高度（左右黑边来自 16:10 远端对 16:9 屏幕）；工具栏显示时远端画面整体下移 52 pt，顶部露出工具栏，底部被屏幕裁掉，画面尺寸/比例不变。
- 退出全屏后窗口恢复 `1920×1132`（画面 1920×1080 + 52 pt chrome），与修改前的窗口布局一致。
- 全屏工具栏显示时，用鼠标点击「调度中心」：日志出现 `command: sent missionControl`，没有出现输入转发计数增长，说明点击仍由本地工具栏消费（B16 不回退）。

### 3.3 端到端音频（GUI）

本地虚拟屏服务端 `--audio`，主控端勾选音频连接，运行中把默认输出从内建扬声器切到 T3252U、再切回内建扬声器：

```text
audio: playing to default output (initial; graph #1)
audio: default output device changed; rebuilding output graph in 150 ms
audio: playing to default output (default output device changed; graph #2)
audio: default output device changed; rebuilding output graph in 150 ms
audio: playing to default output (default output device changed; graph #3)
```

服务端同时记录到 `audio source: 48000 Hz 2 ch ...`，说明采集与转发链路未受影响。

## 4. v0.12 回归：全屏工具栏点击穿透

### 4.1 现象

v0.12 发布后，用户复测全屏工具栏时发现「工具栏成了穿透层」：点击工具栏区域，远端 App 反而收到点击。上一轮报告 3.2 只验证了「调度中心」按钮中心，没有覆盖工具栏下沿、按钮空隙和窗口非 key 时的首次点击，因此这条回归没有被发现。

### 4.2 原因

`WindowInputCapture` 的本地事件监听器会收到 App 内所有窗口的事件，不只是视频窗口。全屏工具栏是独立浮层窗口，事件已经由 AppKit 路由给工具栏，但旧逻辑仍用 `NSEvent.mouseLocation` 对主窗口做命中测试：

- 工具栏浮层与下移后的画面之间存在重叠/边缘区域，命中测试可能返回视频视图，于是点击被转发给远端；
- 窗口不是 key window 时，第一次点击本应由 AppKit 用来激活窗口/工具栏，旧逻辑也可能把它转发出去；
- 旧验证点在工具栏上方，命中测试返回 nil，恰好没有触发上述路径。

### 4.3 修复

`Sources/BoltKVMCore/InputCapture.swift` 增加三层防护：

1. **事件窗口归属**：`event.window` 不是视频窗口时直接放行，不再参与视频命中测试；
2. **非 key 首击本地处理**：鼠标按下时窗口不是 key，先 `makeKeyAndOrderFront` 并放行，让 AppKit 激活窗口/工具栏；
3. **画面上沿以上不转发**：用视图顶部换算到屏幕坐标，指针在画面顶边以上（工具栏/菜单栏区域）一律不转发，并记录 `input: chrome click kept local`。

新增 `InputChromeRoutingTests` 钉住第 3 层的边界：画面顶边以上为 chrome，顶边及以下不是。

### 4.4 验证

- `swift build -c release` 通过；
- `swift test`：80 个测试，79 通过、1 个跳过（既有音频无输出设备跳过项）；
- 在 MacBook 上用 172 测试包连接 mini，锁定物理指针后分别点击工具栏顶部和工具栏下沿：
  - 未出现 `input: forwarded` 计数增长；
  - 工具栏按钮仍能触发本地动作。
- 【事实】v0.12.1 已发布，Release 产物 `BoltKVM-0.12.1.zip` 的 SHA-256 校验、`Info.plist` 版本与签名均已复核，见 [发布记录](2026-10-26-v0.12.1-release.md)。
- 【未经核实】最终 v0.12.1 安装包在目标机器上的完整人工复测；工具栏所有按钮、不同 macOS 缩放/多显示器组合仍需人工确认。

## 5. 未验证与剩余风险

- 【未经核实】没有在测试中物理关闭蓝牙耳机再重新配对/连接，只切换了系统默认输出（macOS 在耳机断开/重连时做的正是这一步）。音频探针与 XCTest 都覆盖了「默认输出来回切」，但耳机自身的重连时序、系统多次通知的间隔可能因设备而异；建议用户按原始步骤再验一次。
- 【未经核实】全屏工具栏的视觉效果由窗口截图人工确认，没有自动化 UI 快照测试；不同 macOS 版本的工具栏高度（当前 52 pt）由运行时 `contentLayoutRect` 实测，代码未写死该值。
- 【推断】多显示器/不同缩放比下顶部浮层与位移量应随 `contentLayoutRect` 自适应，但未逐组合实测。
- 【未经核实】CoreAudio 监听在系统睡眠/唤醒后的行为未单独长跑；健康检查每 2 秒可兜底，但没有 8 小时音频长跑数据。
- 【事实】`swift test` 仍需 Xcode 工具链（仅装 CLT 的机器无法链接 XCTest，和仓库既有说明一致）。

## 证据分级

- 【事实】旧音频图在路线变化后 `scheduled` 涨到 256、引擎与播放器仍报运行；重建后 `scheduled` 回落到个位数并保持；测试输出 graph #1/#2/#3。
- 【事实】普通样式全屏窗口在工具栏显示时从 1692 缩到 1640；`.fullSizeContentView` 后保持 1692，仅 `contentLayoutRect` 变为 1640。
- 【事实】GUI 日志中的 `fs:` 行、`command: sent missionControl`、窗口截图与全屏窗口 ID/尺寸；本地服务端 `audio source: 48000 Hz 2 ch`。
- 【推断】屏幕共享的「整体下移」等价于保持画面尺寸、把 frame 下移一个工具栏高度；本实现即按此几何实现，并用截图核对。
- 【未经核实】物理蓝牙断电/重连、睡眠唤醒、多显示器组合与长时间音频稳定性。
