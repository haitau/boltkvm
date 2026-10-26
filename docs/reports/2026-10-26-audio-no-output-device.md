# 无音频输出设备时 `--audio` 崩溃：从异常兜底到静音降级

- 日期：2026-10-26
- 关联提交：`1b74f47 fix(audio): 无输出设备时不连音频图`、`d710c7b fix(audio): CoreAudio 设备枚举`（被 `57ef2ab` 取代）、`57ef2ab fix(audio): ObjC 异常兜底`
- 关联 CI：<https://github.com/haitau/boltkvm/actions/runs/40266047475>

## 1. 现象

CI（`macos-15` runner，无音频输出设备）上 `AudioFinishTests.testFinishReturnsWithQueuedBuffers` 失败：

```text
[busArray objectAtIndexedSubscript:...] setFormat:format ... Code=-10868
```

`-10868` 是 `kAudioUnitErr_FormatNotSupported`：`AVAudioEngine` 在没有任何输出设备时仍被连接，`connect(_:to:format:)` 抛 Objective-C 异常，Swift 侧无法用 `do/catch` 捕获。

## 2. 排查过程

1. 先尝试在读流前判断 `engine.outputNode.outputFormat(forBus: 0)` 的采样率/声道数，但无设备时它仍可能返回非零值，判断不可靠；
2. 再尝试用 CoreAudio 枚举输出设备（`d710c7b`），runner 仍报告存在“可输出”设备，判断同样不可靠，该提交被 `57ef2ab` 取代；
3. 最终改为在 ObjC 层用 `@try/@catch` 包裹整个音频图搭建与启动，任何异常都只记录、不崩溃。

## 3. 修复

- `Sources/CVirtualDisplay/BKVTrying.m` 新增 `BKVTryCatching(NS_NOESCAPE void (^block)(void))`，用 `@try/@catch` 捕获 ObjC 异常并记录 `[BoltKVM] caught %@: %@`；
- `Sources/BoltKVMCore/Audio.swift` 用 `BKVTryCatching` 包住 `engine.attach` / `engine.connect` / `engine.start()`，失败时记录 `startError`，只有 `built && startError == nil` 才把播放器标记为可用，否则打印 `audio: playback unavailable (...)` 并继续跑视频与输入；
- 新增 `isPlaybackActive`（读 `player != nil`，加锁），`AudioFinishTests` 在 `!isPlaybackActive` 时 `XCTSkip("no usable audio output device; the drain path cannot be exercised")`，把“设备缺失”与“代码回归”区分开。

用户侧行为：开启 `--audio` 但机器没有输出设备时，音频静音、日志给出原因，视频与键鼠不受影响，服务端不再崩溃。

## 4. 验证

```bash
# 有输出设备的本机：应通过而不是跳过
swift test --filter AudioFinishTests

# 无输出设备的机器（CI runner）：应 skip
```

- CI run 40266047475 全绿：71 个 XCTest 中 70 通过、1 跳过，唯一跳过项就是本报告的音频回归；
- 本机（有输出设备）完整测试 71 项全部通过，`isPlaybackActive` 为真、走真实 drain 路径；
- 二进制中包含 `BKVTryCatching`（`strings`/`nm` 可查），v0.11 发布包已验证。

## 5. 未验证与剩余风险

- 【未经核实】只验证了“完全没有输出设备”这一种形态；HDMI 拔出、聚合设备切换、设备在推流中途消失等场景没有逐一复现；
- 【未经核实】静音降级后客户端 `audio` 统计是否会出现误导性的 `frames=0` 没有专门断言（现有统计会显示 0 帧，属预期但未写成测试）；
- 【推断】不同 macOS 版本的 `AVAudioEngine` 对无设备行为可能不同，`@try/@catch` 是兜底而非语义保证。

## 证据分级

- 【事实】CI 错误码 `-10868`、修复前后的提交链、`BKVTryCatching` 的实现位置、CI run 40266047475 的 70 通过 + 1 跳过。
- 【推断】两次设备探测失败的原因（`outputFormat` 与 CoreAudio 枚举在无设备时都不可靠）。
- 【未经核实】设备热插拔/中途消失等场景；不同系统版本的行为差异。
