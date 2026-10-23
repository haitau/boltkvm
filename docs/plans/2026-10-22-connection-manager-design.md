# 连接管理（R1/R2/R3）设计与协议改动

> 需求见 [connection-manager.md](2026-10-22-connection-manager.md)。本文只写"怎么做"，
> R4/R5 已实现，这里覆盖 R1 列表、R2 每台配置、R3 登录密码。

## R1 数据模型

```swift
struct SavedHost: Codable, Identifiable {
    var id: UUID
    var name: String          // 显示名，默认取 host
    var host: String          // IP 或主机名
    var port: UInt16
    var pskAccount: String?   // keys/ 下文件名，nil 表示用 ~/.boltkvm-key
    var width: Int?           // 见 R2；界面里始终是具体数值，没有"默认"档
    var height: Int?
    var lastConnected: Date?
}
```

- 存储：`~/Library/Application Support/BoltKVM/hosts.json`；
- 首次启动迁移现有 `Prefs.host/port` 成一条记录（名字取 host），迁移后清掉旧键；
- 画质字段已删除（2026-10-23）：它当初只是占位，服务端根本没有对应能力，留着等于假承诺。
  真正的画面质量开关在**服务端菜单**里（画面质量 → 标准 / 清晰），见 `ServerAppController`；
- 分辨率在界面里是具体数值（预设 1280×720…3840×2160 + 自定义），自定义尺寸记在
  `UserDefaults` 的 `hosts.customResolutions`；仍然只存不生效，等 R2 的 config 包；
- 首次由服务端自动生成：`--key`/`$BOLTKVM_KEY`/`~/.boltkvm-key` 全空时，服务端在启动前
  生成 8 位口令（小写字母+数字，去掉 `0/o/1/l/i`，无连字符）写入 0600 文件，并显示在被控端
  面板；口令先经 PBKDF2-SHA256 12 万次拉伸再用作密钥，输入侧忽略大小写/连字符/空格；主控端在「编辑」里填一次即可（按台保存）。不用 SSH、不用手工 openssl；
- 首次生成也可以用 `boltkvm keygen`（写 0600 文件并打印 SHA-256 指纹前 8 字节），两端比对指纹
  即确认是同一把；服务端启动时、客户端握手时都会把指纹写进日志；
- PSK 只存**文件名**（`host:port`），内容写入
  `~/Library/Application Support/BoltKVM/keys/<host>_<port>`，权限 0600，不落 JSON。
  原本计划用 Keychain，实测行不通（2026-10-23）：本地重签名（`BoltKVM Local`）每次都让
  钥匙串把 app 当成"另一个程序"，连接时弹出"想使用您储存在钥匙串中的 boltkvm-psk"、
  要登录密码，界面就卡在黑屏。和已有的 `~/.boltkvm-key` 同级目录、同权限，重建不影响；
- 登录密码（R3，未实现）将来同样走文件而不是 Keychain，理由同上，且默认不写。

## R1 界面

- 主窗口 = 列表（`NSCollectionView` 或简单 `NSTableView`）：名称、地址、上次连接、状态点；
- 工具栏：`＋`（新建）、`编辑`、`删除`；
- 双击 / 回车 = 连接，连接后切到现在的视频窗口（新建一个 `ClientController` 并隐藏列表）；
- 关闭视频窗口 = 断开并回到列表（而不是退出进程——这会改掉今天 R4 的"关窗即退出"，
  只在列表存在时成立：最后一个窗口关闭才退出）。

## R2 分辨率：协议改动（已实现 2026-10-23）

现状：分辨率是服务端启动参数（`--width/--height` 决定采集尺寸，`--virtual-display-size`
决定虚拟屏逻辑尺寸）。客户端连接时无法影响——现在可以了。

协议：`authOk` 之后客户端发的**第一个包**是 `config`（`PacketType.config = 11`），载荷 8 字节：

```
u16 width, u16 height, u8 quality, u8 reserved, u16 reserved
// quality: 0 = standard（采集宽封顶 3840）, 1 = pixel（采集 = 2×逻辑）
```

服务端（`CLI.runServer`）在认证后带 1 秒读超时读这一包：

1. 收到 `config` 且尺寸与现有虚拟屏不同 → 销毁旧虚拟屏、按请求尺寸重建，采集尺寸按
   quality 重新算（pixel=2×，standard=≤3840），然后才开始推流；
2. 收到别的类型（老客户端发的是 `timeSync`）→ 丢弃，保持服务端自己的尺寸；
3. 读超时 / 客户端不发 → 同上，老客户端零改动可用；
4. `--virtual-display external`（别人家的屏）或重建失败 → 保持原尺寸并记日志，客户端从
   `format` 包看到真实尺寸。

为什么不做 `configOk`：`format` 包已经带真实宽高，客户端拿它校准即可；多一个确认包只是多
一处状态机。

客户端侧：列表里每台机器的 `width/height` 直接进 `SessionConfig`；命令行用
`--request-size 2560x1440`（配 `--request-quality 0|1`）复现同一路径。

服务端的自身设置（被控端面板/菜单里的分辨率）仍是默认值；客户端请求是**当次会话**的覆盖，
helper 重启后回到服务端设置——这是有意的：headless 机器不该被上一个客户端永久改尺寸。

## R3 登录密码（未实现，阻塞已定位）

目标：连上 mini 后，如果它停在锁屏/登录窗口，用记住的密码自动解锁。

现状：服务端只有"虚拟显示上的已登录会话"，**没有解锁注入能力**。缺的不是存储，
是下面这条链路，而它超出当前 app 的权限边界：

1. **检测**：可用 `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked`
   判断是否锁屏，这步没问题；
2. **注入**：登录窗口跑在 `loginwindow` 的 secure input 里，`CGEventPost` 合成键盘事件
   被系统丢弃（实测合成事件在登录窗口不产生字符）；可行的是
   `AuthorizationCreate` + 未公开的 `unlockScreen`，或者走 FileVault 解锁接口，
   两者都要求 **root / 特权 helper**；
3. **进程位置**：`boltkvm-server` 是用户级进程，拿不到上面前提；要做得加一个
   root `launchd` daemon + 用户授权（SMJobBless / 登录项授权），这属于新的分发形态，
   不是加几行代码。

所以 R3 当天不做，阻塞条件是：**需要 root 特权 helper + 私有解锁 API（或改服务端为
自动登录）**，二者都不在现有签名/TCC 能力内。存储侧已就绪：`keys/<host>_<port>`
（0600）将来直接复用，默认不写、只在用户勾选时写。

顺带说明为什么不走 Keychain：本地重签名让每次构建都被当成新程序，读钥匙串要登录
密码（见上文 R1 数据模型）。
