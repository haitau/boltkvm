# CI 构建失败：Swift 6.1.2 对事件掩码表达式报类型检查超时

- 日期：2026-10-26
- 关联提交：`1c9f1b6 fix(input): 事件掩码改为列表折叠，绕开 Swift 6.1.2 的类型检查超时`
- 关联 CI：<https://github.com/haitau/boltkvm/actions/runs/40266047475>

## 1. 现象

CI 的 `swift build -c release` 在 `Sources/BoltKVMCore/InputCapture.swift:94` 失败：

```text
error: the compiler is unable to type-check this expression in reasonable time
```

失败点在 `start()` 里构造 `CGEventMask` 的表达式：14 个事件类型各自 `CGEventMask(1) << CGEventMask(type.rawValue)` 再逐项按位或。本地 Swift 6.4 / SDK 27 编译不复现，只有 CI 的 `macos-15` runner（Swift 6.1.2）报错。

## 2. 证据

为确认是编译器行为而不是工程配置，用 swift.org 的 6.1.2 工具链配合等价的 CoreGraphics 类型桩单独编译该表达式：

```text
旧写法（14 项或链）：5.3 s 后报 unable to type-check this expression in reasonable time
新写法（数组 + reduce）：0.11 s 编译通过
```

同一台机器上 Swift 6.4 编译旧写法没有报错。结论【推断】：6.1.2 的类型检查器在长或链上做了组合爆炸式重载解析，6.4 已改善；与 SDK 27 无关（桩代码只用到 `CGEventType`/`CGEventMask` 的整型语义）。

## 3. 修复

```swift
static let capturedEventTypes: [CGEventType] = [ ... 14 项 ... ]

static let eventMask: CGEventMask = capturedEventTypes.reduce(into: CGEventMask(0)) { mask, type in
    mask |= CGEventMask(1) << CGEventMask(type.rawValue)
}
```

`start()` 改用 `let mask = Self.eventMask`。折叠后的掩码值仍是 `0x0E401CFE`，与旧表达式逐位一致，事件监听行为不变。

## 4. 验证

```bash
# 本机（Swift 6.4）
swift build -c release
swift test --filter InputCaptureMaskTests
```

- 新增 `Tests/BoltKVMCoreTests/InputCaptureMaskTests.swift` 钉住 `InputCapture.eventMask == 0x0E40_1CFE`，并检查 14 个事件类型无重复；
- CI run 40266047475 全绿：构建通过，71 个 XCTest 中 70 个通过、1 个跳过（音频回归，runner 无输出设备，见 [音频设备报告](2026-10-26-audio-no-output-device.md)）；
- 本机完整测试同样通过。

## 5. 未验证与剩余风险

- 【未经核实】没有把整个工程在 Swift 6.1.2 上完整编译过：本地只有 6.4，6.1.2 只验证了等价表达式片段；真正的 6.1.2 全量构建由 CI 承担。
- 【未经核实】其他长或链（未来新增事件类型或掩码）是否会在旧工具链上复发没有穷举；已用单元测试钉住掩码值，新增事件类型时测试会先失败。
- 【推断】升级 CI 到更新的 Swift 版本后该表达式大概率也能编译，但未做对照实验。

## 证据分级

- 【事实】CI 报错位置与错误文本、掩码值 `0x0E401CFE`、CI run 40266047475 的结果、71 项测试中 1 项跳过。
- 【推断】6.1.2 类型检查器组合爆炸是根因；6.4 的改进使本地不复现。
- 【未经核实】6.1.2 下全工程的完整构建只能由 CI 证明；其他掩码表达式未穷举。
