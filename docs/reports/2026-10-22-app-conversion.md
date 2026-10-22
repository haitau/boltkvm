# 单 app 化与内建虚拟显示（阶段 1–6）

日期：2026-10-22
范围：把「CLI + vdscreen 外挂」的部署方式收成一个 `BoltKVM.app`，两个角色共用一套采集/传输/渲染代码。

## 一句话结论

mini 已从「CLI 守护循环 + vdscreen 虚拟屏」切换为「`/Applications/BoltKVM.app` + SMAppService 登录项」，重启后无人干预自动起服务；Pro 的 app 作为主控端连上后 57 fps / 977 Mbps，服务端 58–60 fps。vdscreen 已从 mini 移走。

## 做了什么

| 阶段 | 内容 |
|---|---|
| 1 | vendored `CVirtualDisplay`（vdscreen MIT 代码，固定 commit），`--virtual-display builtin` 由进程自己建屏 |
| 2 | 默认改 builtin，采集按 displayID 精确锁定，mini 移除 vdscreen（app 与 LaunchAgent/登录项） |
| 3 | 抽出 `BoltKVMCore`，CLI 变成 40 行调度器，app 与 CLI 共用实现 |
| 4 | 单 app 骨架：首启选角色、主控端窗口（连接面板 + Metal 画面 + 全屏） |
| 5 | 被控端：菜单栏状态项、非模态权限引导、`SMAppService.mainApp` 自启、单实例锁 |
| 6 | `Packaging/build-app.sh`、代码生成的图标、自签名代码签名证书 |

## 实测

| 项目 | 结果 |
|---|---|
| CLI 服务端（单块内建屏） | `captured=480 encoded=480 dropped=0 fps=59.8 bitrate=522.7Mbps encLat=7.50ms` |
| 客户端（CLI，同一次） | 588 帧 / 10 s |
| app 主控端窗口渲染 | `decode 60.5 fps` / `render 447 帧 55.4 fps drawable=2400x1448 latency p50=27.2ms p95=29.3ms` |
| app 服务端（子进程） | `fps=58.3 bitrate=703.2Mbps dropped=0` |
| app → app 全链路 | 客户端 `57 fps · 977 Mbps`，服务端 `58.2 fps / 1004 Mbps` |
| 重启恢复（无人工步骤） | 开机 → app 自启 → 子进程建屏 `id=5 3008x1692 / 6016x3384 HiDPI` → `listening`，客户端随即连上（434 帧 / 8 s） |

## 关键发现

1. **两块虚拟屏会互相拖垮**：两块 3008×1692 虚拟屏同时在线时 ScreenCaptureKit 掉到 3–8 fps，两块都慢；只留一块立刻回到 57–60 fps。今天上午所有「帧率崩塌」的观测都是这个原因（残留的 vdscreen 屏）。
2. **GUI 进程建虚拟屏不可靠**：同样的 C 代码 CLI 次次成功，放进 app 里要么被拒绝、要么掉成 LoDPI。服务端角色改为监督 bundle 内的 `boltkvm-server` 子进程（vdscreen 也是这么做的），TCC 由责任进程继承。
3. **macOS 15 起「本地网络」是独立 TCC 项**：Info.plist 缺 `NSLocalNetworkUsageDescription` 时连接只报 `No route to host`。
4. **ad-hoc 签名会重置所有 TCC**：每次构建 cdhash 都变。改用自签名证书（`scripts/make-signing-identity.sh`）后授权可跨构建保留。
5. **APFS 大小写不敏感**：`Contents/MacOS/boltkvm` 会覆盖主程序 `BoltKVM`，helper 必须叫别的名字（现为 `boltkvm-server`）。

## 未验证 / 下一步

- app 部署下 >10 分钟的稳定性（今天只做了分钟级）；
- 主控端窗口里的键鼠转发、音频、全屏切换未实测；
- 8 小时输入连续性测试仍按用户要求搁置。
