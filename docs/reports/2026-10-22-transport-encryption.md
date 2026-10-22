# 传输加密：ChaCha20-Poly1305 会话层

> 2026-10-22。之前只有认证（HMAC 挑战应答）没有加密，线上是明文 ProRes。现在握手完成后整条链路都是 AEAD 密封的。

## 设计

- **密钥来源**：复用认证用的 PSK。服务端挑战里的 32 字节随机 nonce 直接当 HKDF 盐，所以不需要额外往返；每次连接密钥都不同。
- **两个方向两把钥**：`HKDF-SHA256(psk, salt=nonce, info="boltkvm c2s"/"boltkvm s2c")`，避免双向同钥绕开 nonce 复用风险。
- **算法**：ChaCha20-Poly1305（CryptoKit），每包 16 字节 tag。
- **Nonce**：64 位计数器放在 12 字节 nonce 的低 8 位。TCP 有序，两端在同一协议点（authOk 之后）同时装密钥，计数器天然对齐，不需要重放窗口。
- **帧头保持明文**：头里有 magic/type/length，是分帧必需的；把它作为 AEAD 的 AAD 参与认证，所以改 type 或改长度都会校验失败。
- **载荷长度**：`payloadLength` 字段写的是密文+tag 的长度，接收端据此读取。

## 协议时序

```
client                          server
  |---- timeSync (明文) --------->|   （握手期间被跳过）
  |<--- authChallenge (明文) -----|
  |---- authResponse (明文 MAC) ->|
  |<--- authOk (明文) ------------|
  |                               |  装密钥 s2c/c2s
  装密钥 c2s/s2c
  |---- timeSync (加密, c2s#0) -->|
  |<--- timeSync echo (加密 s2c#0)|
  |<--- format / frame (加密) ----|
```

## 验证

| 项 | 方法 | 结果 |
|---|---|---|
| seal/open 往返 | `boltkvm cryptotest`：1000 帧双向 + 3 种篡改 | PASS |
| 载荷篡改 | 翻转密文最后一字节 | 拒绝（认证失败） |
| 帧头篡改 | 翻转 flags 字节 | 拒绝（AAD 不匹配） |
| 错误密钥 | 用全零 PSK 派生 | 拒绝 |
| 端到端 | 被控端新服务端 + 主控端新客户端 | `auth ok`、加密 timeSync 往返 RTT 22.5 ms、348 帧、`failed=0` |
| 旧客户端 | 用部署前的二进制连新服务端 | 帧数 0、`EBADMSG`——线上不再是可解析的明文帧 |

## 代价

- 每包多 16 字节；500 Mbps 下带宽开销可忽略（帧约 700 KB，tag 占比 0.002%）。
- 加密是逐包 AEAD，没有握手层的额外 RTT；实测帧率与加密前一致（约 58–61 fps，6 秒窗口）。
- CPU：ChaCha20 在 Apple silicon 上有硬件加速，未观察到编码/解码侧的变化。

## 未做的

- **不做前向保密**：PSK 泄漏等于历史流量可解。要 PFS 得上临时 ECDH，那是另一套握手。
- **不做重放窗口**：依赖 TCP 有序性；如果将来上 UDP/QUIC，需要补。
- **`--insecure` 仍是明文**：故意保留的逃生口，日志会警告。

## 复现

```bash
# 单元：加解密与篡改拒绝
.build/release/boltkvm cryptotest

# 端到端（两端都需新二进制）
.build/release/boltkvm client --host <bridge-ip> --port 7474 --seconds 6
# 期望：auth ok → time sync rtt=... → received frames > 0
```
