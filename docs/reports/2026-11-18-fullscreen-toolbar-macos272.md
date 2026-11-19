# 全屏"状态栏收不起来"（macOS 27.2.1）：实测与 orderOut 方案证伪（2026-11-18）

## 现象

用户报告：运行久了之后，全屏时主控机顶部状态栏出现后不再收起，指针移开也不消失。当日 14:2x 复现；退全屏重进、顶边驻留自愈均无效；重启 app 清除。

这是 [2026-11-02 报告](2026-11-02-fullscreen-toolbar-stuck.md) 冻结问题（定案「回退 245 原样 + 重启清除」）的复发。与 11-02 的关键差异：系统已升到 27.2.1 (26B131)，经用户裁决重开。

## 探针实测（docs/_scratch/fs-*.swift，截屏判像素，均在本机 27.2.1）

1. **hidden 态子窗口不再撤屏**：`toolbar.isVisible = false` 只把 `NSToolbarFullScreenWindow` 子窗口从 66 pt 缩到 32 pt，仍 order 在屏、alpha=1。健康与卡死在窗口层面（ordered/alpha/位置）**完全无法区分**——11-02 的滞留判定失效。
2. **真实 show→hide 配对不再自愈**（连做 3 组配对，带子照旧）；alpha=0 路线 27.0.1 已证吞键盘，未再试。
3. **orderOut 是唯一真正撤下带子的调用**（截屏 21%→0% 亮像素）；orderOut 后 `isVisible=true` 唤不回，补显式 `orderFront` 在**短周期探针**里能完整恢复（44% vs 健康基线 45.3%，两轮稳定）。
4. **无工具栏的全屏窗口同样有 32 pt chrome 带**（探针 7：`window.toolbar` 不装，hidden 态截屏顶部仍有 32% 亮像素）——该带是全屏窗口 chrome（红绿灯宿主）的基础设施，不是 NSToolbar 的产物；深色外观下它与黑色视频融为一体，平时不可见。
5. **真实 app 全屏反复 orderOut/orderFront 后出现多个 3008×30 僵尸子窗口**（CGWindowList 实测 4 个，全部不在屏）——AppKit 会另建新实例，旧引用变成孤儿。

## orderOut 方案实施与证伪（commit 8dabd04 → revert 681c54d）

基于探针 3 的短周期结论实施：删除预热舞步；隐藏 = flag off + `orderOut`；唤出 = flag on + 下一轮 runloop 补 `orderFront`；tick 加不变量「全屏且 flag 关时子窗口必须不在屏」。

**部署 0.14.0 (272) 后用户实测失败，症状比原问题更重**：

- 顶边驻留唤不出工具栏（日志里 shown/hidden 配对正常——状态机在转，但唤回的是孤儿/错误实例，视觉上什么都没有）；
- **本机菜单栏永久卡在弹出态**（截图：黑底 BoltKVM 菜单条压在全屏画面顶端，不再收回）。

**证伪结论**：那个 32 pt 的 hidden 子窗口不是 bug，是全屏 chrome/菜单栏滑入滑出的宿主条。orderOut 它 = 拆掉 AppKit 全屏菜单栏管理的地基：菜单栏被唤出后没有容器收回（永久卡死），工具栏唤回的也是孤儿窗口（不可见）。探针 3 的两轮短循环没有暴露这个退化（缺真实菜单栏交互、缺多轮进出全屏）——探针无法用 CGWarp/CGEvent 唤出系统菜单栏，是本次验证盲区的根源。**「orderOut + orderFront」路线在 27.2.1 上判死。**

已 `git revert 681c54d` 回到 245 行为并重新部署：工具栏显隐恢复可用，菜单栏卡死回到已知的间歇形态（重启清除）。

## 重新定义的真正问题

用户可见的 bug 自始至终是：**系统菜单栏弹出后不收回**（带子/红绿灯在深色外观下不可见，用户看到的"状态栏"就是菜单栏）。它是间歇性的：11-02 当天 22:19 正常、次日 09:06 卡死；今天 14:2x 卡死。诱因疑似与 tick 在菜单栏滑入滑出动画期间切换 `isVisible` 有关，但未证实。

后续方向（未实施，待裁决）：

- **方向 A（继续 245）**：接受间歇卡死 + 重启清除，不再动；
- **方向 B（菜单栏专项）**：先解决"探针唤不出菜单栏"（CGEvent mouseMoved 事件流 / 真人协助），再实测卡死瞬间菜单栏与 chrome 带的窗口状态，找到 wedge 条件后做温和化处理（如检测菜单栏在屏时推迟 hide）；
- **方向 C（自绘工具条，252 复活）**：全屏卸载 NSToolbar、自有子窗口做工具条（状态机只剩自己）。252 当年被否的「三层叠盖」需在 27.2.1 重新评估——chrome 带依然存在（探针 7），但若菜单栏卡死与 NSToolbar 无关，方向 C 也治不了本症状。

## 验证留痕

- 8dabd04 实施时的验证：release 构建通过、`swift test` 112/1/0、探针显隐两轮 h=0.0%/r=44.0%——均通过但**不足以覆盖真实退化路径**；
- revert 681c54d 后：release 构建通过；部署 build 273 后待用户确认工具栏恢复；
- 本报告的探针脚本：`docs/_scratch/fs-chrome-probe-27.2.swift`（原生行为）、`fs-menubar-probe-27.2.swift`（菜单栏窗口枚举）、`fs-menubar-probe3-27.2.swift`（指针驱动+像素）、`fs-visual-probe-27.2.swift`、`fs-appfaithful-probe-27.2.swift`（orderOut 证伪）、`/tmp/fsprobe7.swift`（无工具栏对照）。

---

# 夜间实验（19:00-19:10）：菜单栏卡死根因落定与解除

## 现象重述（19:00 状态）

探针 8（`fs-menubar-lifecycle-27.2.swift`，CGEvent mouseMoved 事件流驱动指针）实测：**全屏一进入菜单栏就全程在屏**（M0 基线即 bar=true，3 轮「顶边扫动→移开」完全不改变状态），四个自愈（M4 presentationOptions 切换 / M5 工具栏 show→hide / M6 chrome 子窗口 orderFront→orderOut / M7 Mission Control 切换）**全部无效**。此时窗口化对比 15:41 探针 2（全屏菜单栏正常停在屏外 y=-30）可知：系统在 15:41-19:00 之间进入了一种**跨进程、跨 app 重启存活的坏状态**——所有 app 的全屏（包括用户实测的 Windows RDP 客户端）菜单栏都永久显示。

## 根因与解除（实测）

- 机器 5 天未重启（kern.boottime = 11-13），坏状态活在 WindowServer 运行态；
- **`killall Dock` 一键解除**：重启 Dock 后全屏菜单栏立即恢复自动隐藏（在屏=false），窗口模式菜单栏正常（在屏=true）；
- `_HIHideMenuBar`（历史键「自动隐藏和显示全屏菜单栏」）在 27.2.1 上**已失效**：0↔1 翻转对全屏菜单栏行为无任何影响（解除前后各测一轮），已恢复原值 0；
- 重启 MenuBarAgent 无效；
- 健康状态复验：chrome 子窗口回到正常 32 pt 驻留（深色外观下不可见），自动隐藏工作正常。CGEvent posted mouseMoved 仍无法唤出菜单栏（探针限制，真鼠标不受影响）。

## 触发源（强关联，非 100% 证明）

坏状态出现的时间窗（15:41 之后、19:00 之前）内发生的全屏 chrome 子窗口 `orderOut` 实验：探针 6（15:47-15:49）与 **build 272 的正式全屏使用（16:11-16:30，用户实际运行）**。推测：反复 `orderOut` 全屏 chrome 宿主条会把 WindowServer 的全屏菜单栏状态打坏（该条正是菜单栏滑入滑出的宿主）。原 245/build 270 的**间歇性**卡死（11-02 起、app 重启可清）是另一层：app 内部的子窗口滞留（app-scoped），与本次系统级 wedge（system-scoped，需 killall Dock/注销）不是同一层。

**对傍晚结论的修正**：用户「RDP 也一样」的观察成立且被证实（当时系统确实处于坏状态），但该坏状态是今天的 orderOut 实验引出的，不能作为「27.2.1 原生系统 bug」的直接证据；macOS 27 系列全屏 chrome 脆弱（27.0.1 起三连 bug）的判断仍成立。Reddit r/applehelp /comments/1wi7cfx（macOS 27 全屏菜单栏问题，F3 修复）供参考；检索通道：Firecrawl keyless（web_search 因用户 DeepSeek 402 不可用）。

## 用户侧 remedy

- **再遇全屏菜单栏卡死（任何 app）：终端跑 `killall Dock`，秒级解除，无需重启 BoltKVM**；
- 待裁决的可选产品化：BoltKVM 工具条加「修复全屏菜单栏」按钮（本质 killall Dock），是否要做由用户决定——它是系统级维护动作，不宜自动触发；
- 产品代码无需改动：245/build 274 保持现状；
- 建议向 Apple 提交 Feedback：macOS 27.x 全屏 chrome（NSToolbarFullScreenWindow + 菜单栏状态机）脆弱，附本报告两份探针数据。
- **已提交**：Feedback Assistant **FB25636635**（2026-11-19，macOS / 菜单栏 / 错误-异常行为），正文含环境、三项实测事实、复现探针方法与期望行为，附系统信息报告与诊断日志（自动收集）。

## 夜间验证留痕

- 探针输出：/tmp/fsprobe8.out（wedge 态全记录）、/tmp/fsprobe8b.out（解除后健康态）、/tmp/probe9（开关 `_HIHideMenuBar` 前后对照，脚本 /tmp/probe9.swift）；
- 机器收尾状态：`_HIHideMenuBar` 已恢复原值 0；Dock 已重启、全屏菜单栏自动隐藏正常；BoltKVM build 274 在跑；机器未重启、未注销。
