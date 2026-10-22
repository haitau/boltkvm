# 输入连续性长跑测试计划

> 状态：已设计，待执行。目标是一次夜间 8 小时无人值守跑，补上 8 小时长稳里唯一没有数据的一项。

## 1. 为什么要单独测

8 小时长稳（2026-10-21）里 `input.win sent=23`，全部集中在开局一分钟；`tapDisabled=0` 只证明 tap 在退出时还活着，**不能证明 8 小时里持续可用**。已知的风险点：

- 会话级 `CGEventTap` 在 secure input（密码框、锁屏）下会被系统禁用，`tapEnable` 无效；
- 主控端睡眠/唤醒、显示器休眠后 tap 可能失效；
- 系统在长时间无事件后可能回收 tap 的超时项。

这些都不会在短跑里暴露。

## 2. 假设与判据

| 编号 | 假设 | 通过 | 失败信号 |
|---|---|---|---|
| H1 | tap 全时长存活 | 客户端 `tapDisabled=0`，且 `sent` 持续增长 | `tapDisabled>0`，或 `sent` 在某个时刻后不再增长 |
| H2 | 事件端到端不丢 | 客户端 `sent` 增量 ≈ 探针 `posted` 增量 | `sent` 增量明显小于 `posted` |
| H3 | 服务端注入持续生效 | 服务端 `input events=N` 与 `sent` 同步增长 | `input` 停滞而 `sent` 增长（注入被拒） |
| H4 | 注入真的落到被控端 | 每次位移都能让 `captured` 增长（`showsCursor=true`） | `captured` 不随探针变化 |
| H5 | （顺带）锁屏态注入 | 若期间被控端锁屏，位移仍然改变画面 | 锁屏后 `captured` 不再随探针变化 → 锁屏注入不可用 |

H5 不是本轮的硬判据，但一旦命中就是重启救援那条链的关键答案。

## 3. 装置

**探针**：`boltkvm inputprobe --seconds 28800 --interval-ms 60000`

- 在主控端的 HID 层每 60 秒注入一次鼠标位移（±3 px 交替，位置不变）；
- 走的是**真实路径**：HID → 客户端 `CGEventTap` → TCP → 被控端 `CGEventPost`；
- 每发一个打一行 `inputprobe posted=N at=x,y`，结束时打 `inputprobe done posted=N`；
- 位移选 ±3 px 而不是点击或按键：对前台应用无副作用。

**客户端**：`--render --input --reconnect`（`--input` 才会起 tap；`--render` 才会持有 `idleDisplaySleepDisabled` 断言）

**服务端**：现有统计即可，`input events=N` 每 120 个事件打一行，`stats captured=...` 每 2 秒一行。

## 4. 执行

一键跑（推荐）：

```bash
scripts/input-continuity.sh --host <bridge-ip> --seconds 28800
# 产物：~/soak/<日期>-input/{probe.log,client.log,monitor.tsv}，结束时打印汇总
```

手工分步（想看每一步时）：

```bash
# 0) 起跑前自检（含 key、caffeinate、残留进程）
scripts/soak-preflight.sh --host <bridge-ip>

# 1) 被控端：确认服务端在跑、远端显示器在线
scripts/rescue.sh --host <bridge-ip>

# 2) 主控端：探针 + 客户端，两个进程，各自写日志
RUN=~/soak/$(date +%F-%H%M)
mkdir -p "$RUN"
nohup .build/release/boltkvm inputprobe --seconds 28800 --interval-ms 60000 > "$RUN/probe.log" 2>&1 &

# 3) 客户端（全屏，期间主控端不可用）
.build/release/boltkvm client --host <bridge-ip> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect > "$RUN/client.log" 2>&1

# 4) 每 5 分钟采样
nohup scripts/soak-monitor.sh --client-log "$RUN/client.log" \
  --out "$RUN/monitor.tsv" --interval 300 >/dev/null 2>&1 &
```

注意顺序：**探针在客户端之前启动**，确保 tap 起来后立刻有事件可收；客户端退出时探针也到点。

## 5. 读数

```bash
# 探针存活
grep -c 'inputprobe posted=' ~/soak/<RUN>/probe.log          # 期望 ≈ 480
tail -1 ~/soak/<RUN>/probe.log                                # posted=480

# tap 存活与转发
grep 'input.win' ~/soak/<RUN>/client.log | tail -3            # sent / tapDisabled
grep -c 'WARNING' ~/soak/<RUN>/client.log

# 注入落地
ssh <host> "grep 'input events=' ~/Library/Logs/boltkvm-server.log | tail -3"
ssh <host> "grep 'stats captured=' ~/Library/Logs/boltkvm-server.log | tail -3"
```

判读：

- `sent` 首尾差 ≈ 480（±2 为窗口边界误差）；若明显偏大，说明期间有人动过键盘鼠标（那也是正常的输入，不算失败）；
- `tapDisabled` 全程必须是 0；
- 服务端 `input events` 应与 `sent` 同量级，差值 < 1%（TCP 上丢失意味着断连，断连数应为 0）；
- `captured` 的增量应 ≥ 探针次数（每次位移至少触发一次采集）。

## 6. 风险与预案

| 风险 | 影响 | 预案 |
|---|---|---|
| 探针事件被自己的 tap 吞掉 | 主控端光标不动，属预期 | — |
| 期间有人操作主控端 | `sent` 偏大，但方向安全（只多不少） | 夜间执行 |
| 被控端锁屏 | 注入可能被丢弃 | 这正是 H5 要测的；记结论，不中断 |
| 主控端显示器休眠 | `render` 断言已禁用 idle display sleep | `soak-preflight.sh` 会检查断言 |
| 探针进程被杀 | `posted` 停在某值 | 与客户端日志的 `sent` 增长对照即可判断 |

## 7. 产出

- `~/soak/<RUN>/{probe.log,client.log,monitor.tsv}` 与被控端 `~/Library/Logs/boltkvm-server.log` 片段；
- 一份 `docs/reports/<date>-m3-input-continuity.md`，按 H1–H5 逐条给结论；
- 无论通过与否，都要更新 README 的“当前实测”表中「输入连续性」一行。
