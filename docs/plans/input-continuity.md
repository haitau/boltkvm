# 输入连续性 8 小时测试计划

- 状态：已执行并通过（2026-10-22 夜间跑完，466 次转发、tap 失效 0、0 断连；结果见 [夜间执行报告](../reports/2026-10-22-night-run.md)）

## 1. 测试背景

在首次 8 小时长稳测试（2026-10-21）中，因夜间无人操作键鼠，全程仅在开局第一分钟产生了 23 个输入事件。虽然退出时 `tapDisabled=0`，但尚不足以证明 `CGEventTap` 在连续 8 小时运行中不会因系统休眠、超时回收或安全输入状态而静默失效。因此单独设计本项测试，通过定时合成输入探针验证 8 小时端到端输入连续性。

## 2. 验证假设与通过标准

| 编号 | 验证项 | 通过标准 | 失败信号 |
|---|---|---|---|
| H1 | 事件监听（tap）全程存活 | 客户端全程 `tapDisabled=0`，且 `sent` 计数持续增长 | `tapDisabled > 0`，或 `sent` 在中途停止增长 |
| H2 | 事件传输不丢失 | 客户端 `sent` 增量 ≥ 探针 `posted` 增量 | `sent` 明显少于 `posted` |
| H3 | 服务端注入持续生效 | 服务端 `input events=N` 随客户端 `sent` 同步增长 | 服务端计数停滞 |
| H4 | 注入动作触发画面更新 | 每次光标微移均触发服务端采集帧数（`captured`）增长 | `captured` 停滞 |

## 3. 测试装置

- **输入探针**：`boltkvm inputprobe --seconds 28800 --interval-ms 60000`
  - 每 60 秒在主控端 HID 层注入一次 ±3 px 的鼠标交替微移，对前台应用无副作用；
  - 完整经过 `HID → 客户端 CGEventTap → TCP 加密传输 → 被控端 CGEventPost` 全链路；
  - 每次注入输出 `inputprobe posted=N at=x,y`，结束时输出汇总。
- **客户端**：`boltkvm client --render --input --reconnect`（持有防显示器休眠断言并开启输入捕获）。
- **服务端**：每 120 个事件输出 `input events=N`，每 2 秒输出 `stats captured=...`。

## 4. 执行命令

一键执行脚本：

```bash
./scripts/input-continuity.sh --host <被控端地址> --seconds 28800
# 产物目录：~/soak/<日期>-input/{probe.log,client.log,monitor.tsv}
```

手动分步执行：

```bash
# 1. 起跑前环境与救援通道自检
./scripts/soak-preflight.sh --host <被控端地址>
./scripts/rescue.sh --host <被控端地址>

# 2. 启动输入探针与全屏客户端
RUN=~/soak/$(date +%F-%H%M)
mkdir -p "$RUN"
nohup .build/release/boltkvm inputprobe --seconds 28800 --interval-ms 60000 > "$RUN/probe.log" 2>&1 &
.build/release/boltkvm client --host <被控端地址> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect > "$RUN/client.log" 2>&1

# 3. 后台每 5 分钟采样一次健康度
nohup ./scripts/soak-monitor.sh --client-log "$RUN/client.log" \
  --out "$RUN/monitor.tsv" --interval 300 >/dev/null 2>&1 &
```

## 5. 结果核对命令

```bash
# 核对探针发送次数（8 小时预期约 480 次）
grep -c 'inputprobe posted=' "$RUN/probe.log"
tail -1 "$RUN/probe.log"

# 核对客户端转发与 tap 状态
grep 'input.win' "$RUN/client.log" | tail -5

# 核对服务端注入日志
ssh <被控端地址> "grep -E 'input events=|stats captured=' ~/Library/Logs/BoltKVM.log | tail -10"
```
