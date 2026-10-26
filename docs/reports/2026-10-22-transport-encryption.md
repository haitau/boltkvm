# 传输层加密与前向保密：ChaCha20-Poly1305 + X25519

- 日期：2026-10-22（2026-10-23 升级 X25519 前向保密）
- 相关：[ADR-0004](../adr/0004-psk-over-pairing-code.md)

## 1. 设计概览

握手认证完成后，整条 TCP 传输链路（视频帧、音频流、键鼠输入、远端命令、时钟同步）均采用 **ChaCha20-Poly1305（AEAD）** 逐包加密与认证：

- **初始密钥派生**：复用挑战-应答认证阶段的预共享密钥（PSK）与服务端生成的 32 字节随机 `nonce`，通过 `HKDF-SHA256(psk, salt=nonce, info="boltkvm c2s" / "boltkvm s2c")` 派生收发双向独立密钥；
- **X25519 前向保密升级**：`authOk` 之后，双方通过已加密通道交换 32 字节 X25519 临时公钥（`PacketType.authExchange = 12`），计算出共享秘密 `sharedSecret`，并立即将双向会话密钥升级为 `HKDF-SHA256(psk ‖ sharedSecret, salt=nonce)`。即使预共享口令在事后泄露，历史录制的抓包流量也无法被解密；
- **Nonce 计数器**：采用 64 位递增计数器（置于 12 字节 Nonce 的后 8 字节）。由于 TCP 严格保序且收发双方在完全相同的协议节点（`authOk` 后及 `authExchange` 后）切换密钥，两端计数器天然对齐；
- **帧头认证（AAD）**：20 字节协议帧头（含 `magic`、`type`、`flags`、`payloadLength`、`ptsMicros`）保持明文以便流式分帧，同时作为 AEAD 的附加认证数据（AAD）参与校验，任何对包类型或长度的篡改均会被拒绝；
- **密文载荷**：加密帧设置 `FLAG_ENCRYPTED (0x02)`，`payloadLength` 为密文长度加上 16 字节 Poly1305 认证标签（Tag）。一旦会话启用加密，接收端拒绝任何未携带 `FLAG_ENCRYPTED` 的明文帧。

## 2. 握手与加密时序

```text
Client                                          Server
  |---- timeSync (明文，握手期被跳过) ------------>|
  |<--- authChallenge (32B nonce, 明文) ----------|
  |---- authResponse (HMAC-SHA256, 明文) -------->|
  |<--- authOk (含服务端时钟与能力标志, 明文) ----|
  |                                               |
  [安装初始会话密钥: HKDF(psk, nonce)]            [安装初始会话密钥: HKDF(psk, nonce)]
  |                                               |
  |---- authExchange (客户端 X25519 公钥, 加密) ->|
  |<--- authExchange (服务端 X25519 公钥, 加密) --|
  |                                               |
  [升级前向保密密钥: HKDF(psk ‖ shared, nonce)]   [升级前向保密密钥: HKDF(psk ‖ shared, nonce)]
  |                                               |
  |---- config / timeSync (前向保密加密) -------->|
  |<--- format / frame / audio (前向保密加密) ----|
```

## 3. 验证结果

| 验证项 | 方法 | 结果 |
|---|---|---|
| 加解密往返与篡改拒绝 | `boltkvm cryptotest`（1000 帧双向往返 + 密文/帧头/密钥 3 类篡改） | 【事实】PASS |
| X25519 协商与重键对齐 | `CryptoTests` 单元测试（11 项，含双向重键后流对齐与临时密钥敏感性） | 【事实】PASS |
| 明文注入拒绝 | `TransportSafetyTests.testPlaintextFrameIsRejectedOnceEncrypted` | 【事实】PASS（返回 `EPROTO`） |
| 并发发送 Nonce 顺序 | `TransportSafetyTests.testConcurrentSendersKeepNonceOrder`（6 线程并发） | 【事实】PASS |
| 端到端实测 | 主控端与被控端雷雳桥连接 | 日志确认 `auth: forward secrecy on (X25519)`，帧率稳定 58–60 fps【未经核实】 |

## 4. 性能开销

- **带宽开销**：每包增加 16 字节 Tag，对约 700 KB 的视频帧而言占比仅约 `0.002%`；
- **计算开销**：Apple Silicon 原生硬件加速 ChaCha20-Poly1305，实测开启前后帧率与延迟无变化。

## 5. 复现命令

```bash
# 运行加解密自测与 XCTest 加密单测
.build/release/boltkvm cryptotest
./scripts/test.sh

# 端到端连接验证
.build/release/boltkvm client --host <被控端地址> --port 7474 --seconds 6
```

## 证据分级

- 【事实】第 3 节前四行的 PASS 来自 `boltkvm cryptotest` 与 XCTest 的实际输出，可用上面的命令重跑（报告记录了方法与结果）。
- 【事实】协议常量和时序（`PacketType.authExchange = 12`、`FLAG_ENCRYPTED = 0x02`、20 字节帧头、16 字节 Poly1305 Tag、`authOk` 后与 `authExchange` 后各切一次密钥）与第 2 节时序图对应实现。
- 【未经核实】端到端一行只有「日志确认 `auth: forward secrecy on (X25519)`、帧率稳定 58–60 fps」的结论，原始日志未入库，无法复跑核对。
- 【推断】第 4 节「开启前后帧率与延迟无变化」建立在 Apple Silicon 硬件加速的解释上，报告没有给出开关前后的逐项对比数据。
- 【推断】「即使预共享口令事后泄露，历史抓包也无法被解密」是对 X25519 前向保密机制的说明，报告未附抓包或离线解密的验证记录。
