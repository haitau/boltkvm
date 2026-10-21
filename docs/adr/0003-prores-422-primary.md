# ADR 0003：M1 主路径改用 ProRes 422

- 状态：已接受（M1 实测；HEVC 作为回退）
- 日期：2026-10-21

## 背景

ADR 0001 规定视频编码优先 VideoToolbox HEVC 低延迟。M1 实测显示，4K HEVC 硬件编码的管线延迟约 **22ms**，即便关闭低延迟码控、保持 60fps，capture→present P95 仍在 34.7ms 左右，端到端余量不足。

## 决策

M1 spike 的主路径改为 **ProRes 422**：

- 编码：VideoToolbox `kCMVideoCodecType_AppleProRes422` 硬件编码；
- 传输：雷雳 TCP，实测约 **658Mbps**，占链路约 1%；
- 解码：客户端 8-bit 422v 硬件解码 + Metal 1:1；
- 回退：HEVC 4:2:0（约 17Mbps、22ms 编码延迟），用于带宽或兼容性受限场景。

## 依据

【事实】4K 真实桌面：

| 编码器 | 吞吐 | 编码延迟 | 码率 |
|---|---|---|---|
| HEVC Main | 60fps | 22.9ms | 6–17Mbps |
| H.264 High | 55fps | 57.7ms | 2.5Mbps |
| **ProRes 422** | **59.9fps** | **9.16ms** | **658Mbps** |

【事实】ProRes 端到端（capture→present）P95 **18.2ms**，全图 SSIM **0.9839**（4K 1:1，测试图参考）。

## 后果

- 带宽从 Mbps 级升到 ~0.66Gbps；雷雳直连可接受，公网/无线不在目标内；
- 全 I 帧，丢帧不影响后续解码，适合低延迟调度；
- 解码输出 8-bit 4:2:2；SCK 采集仍是 4:2:0，彩色高频细节的 SSIM 上限受采集层限制；
- 项目章程的“HEVC 优先”条款需要同步修订，HEVC 保留为回退；
- 仍需 glass-to-glass 相机实测与客户端窗口化验证。
