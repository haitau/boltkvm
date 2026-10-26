# 验证报告

存放可复现的验证结果：命令、原始输出、结论、失败项与下一步。

- 不包含原始 agent 对话、内部决策语气、机器地址或密钥；
- 结论区分【事实】【推断】【未经核实】；
- 报告文件名使用 `YYYY-MM-DD-主题.md`；
- 新增报告必须写清可复跑命令与原始输出；**2026-10-26 之前的历史报告**在本次文档审计中补了「证据分级」一节，原始日志多数未入库，复跑只能按文中命令重做，不能当作逐字原始记录。

## 索引

| 日期 | 报告 | 主题 | 结论 |
|---|---|---|---|
| 2026-10-21 | [m0-display](2026-10-21-m0-display.md) | 虚拟显示与雷雳链路基线 | 显示层通过；M0 整体未关闭（物理拔线/听音/延迟基准仍开放） |
| 2026-10-21 | [m1-encoder-probe](2026-10-21-m1-encoder-probe.md) | 6K/4K 编码可行性探针 | 6K HEVC 不满足 60 fps；M1 选 α′（ProRes） |
| 2026-10-21 | [m1-pipeline](2026-10-21-m1-pipeline.md) | 采集→编码→传输→解码→上屏 | SSIM 0.984，60 fps 链路成立 |
| 2026-10-21 | [m2-input](2026-10-21-m2-input.md) | 键鼠输入链路 | 快捷键、修饰键、滚动相位通过；Unicode 文本注入未实现 |
| 2026-10-21 | [m3-stability](2026-10-21-m3-stability.md) | 稳定性与恢复 | 重连、整机重启恢复通过 |
| 2026-10-22 | [app-conversion](2026-10-22-app-conversion.md) | 应用化（阶段 1–6） | 单应用双角色、内建虚拟屏、打包签名通过 |
| 2026-10-22 | [audio-option](2026-10-22-audio-option.md) | 可选音频转发 | 默认零字节；开启后 48 kHz PCM 正常到达 |
| 2026-10-22 | [m3-soak-8h](2026-10-22-m3-soak-8h.md) | 8 小时长稳 | 0 断连、0 解码失败；个别窗口 P95 超 50 ms |
| 2026-10-22 | [night-run](2026-10-22-night-run.md) | 夜间输入连续性（8h） | tap 失效 0、0 断连（CLI 客户端） |
| 2026-10-22 | [present-sync-fix](2026-10-22-present-sync-fix.md) | 呈现同步（`displaySyncEnabled`） | 48.8 → 59.5 fps |
| 2026-10-22 | [transport-encryption](2026-10-22-transport-encryption.md) | PSK/HMAC/X25519/ChaCha20-Poly1305 | 全部通过 |
| 2026-10-23 | [audio-and-gui-stability](2026-10-23-audio-and-gui-stability.md) | 音频 + GUI 12/13 分钟 | 1.54 Mbps，GUI P95 45–46 ms |
| 2026-10-23 | [b5-latency](2026-10-23-b5-latency.md) | B5 帧率与延迟 | 解码 P95 25.4–27.0 ms；GUI 33.2 ms；解码 54.1–58.0 fps |
| 2026-10-25 | [headless-resolution-loop](2026-10-25-headless-resolution-loop.md) | 无雷雳网桥时虚拟屏分辨率来回跳 | 已修：无桥保持虚拟屏并重试绑定 |
| 2026-10-26 | [client-reconnect-resolution](2026-10-26-client-reconnect-resolution.md) | 改分辨率后主控端像死机 | 已修：自动重连 + 状态栏重连次数 |
| 2026-10-26 | [dock-icon-double-click](2026-10-26-dock-icon-double-click.md) | server 双 Dock 图标 / 双击不转发 | 已修；远端窗口 zoom 待实机复核 |
| 2026-10-26 | [input-event-mask](2026-10-26-input-event-mask.md) | CI 报 Swift 6.1.2 类型检查超时 | 已修：列表 + `reduce`，掩码 `0x0E401CFE` |
| 2026-10-26 | [audio-no-output-device](2026-10-26-audio-no-output-device.md) | 无音频输出设备时 `--audio` 崩溃 | 已修：`@try/@catch` + 静音降级，CI 跳过音频回归 |
