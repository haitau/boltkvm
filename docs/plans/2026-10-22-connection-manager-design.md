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
    var keychainPSK: String?  // Keychain 条目的 account，nil 表示用 ~/.boltkvm-key
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
- PSK 只存 Keychain 条目名（`boltkvm-psk` / `host:port`），不落 JSON；
- 登录密码同理，条目 `boltkvm-login` / `user@host`，且默认不写。

## R1 界面

- 主窗口 = 列表（`NSCollectionView` 或简单 `NSTableView`）：名称、地址、上次连接、状态点；
- 工具栏：`＋`（新建）、`编辑`、`删除`；
- 双击 / 回车 = 连接，连接后切到现在的视频窗口（新建一个 `ClientController` 并隐藏列表）；
- 关闭视频窗口 = 断开并回到列表（而不是退出进程——这会改掉今天 R4 的"关窗即退出"，
  只在列表存在时成立：最后一个窗口关闭才退出）。

## R2 分辨率与画质：协议改动

现状：分辨率是服务端启动参数（`--width/--height` 决定虚拟显示），客户端连接时无法影响。
客户端的"画质"从未参与协议，已删除。

方案：`authOk` 之后客户端发一个 `config` 包（新的 `PacketType.config = 11`）：

```
u16 width, u16 height, u8 fps, u8 quality   // quality: 0=pixel 1=balanced 2=smooth
```

服务端收到后：
1. 若与当前虚拟显示不同，重建虚拟显示（沿用 `VirtualDisplay` 的创建路径）；
2. 用新的画质档位重配编码器（bitrate 目标 + 帧率）；
3. 回一个 `configOk`（可复用 `authOk` 的语义或新增类型），之后才开始推流。

兼容：老客户端不发 `config`，服务端保持现有行为；新客户端连老服务端时，`config` 包未知
类型会被忽略（`PacketType` 解析失败时跳过），退化为"用服务端默认"。

## R3 登录密码

服务端当前只有虚拟显示上的已登录会话，没有登录窗口/解锁注入能力。要做"记住远端登录
密码"，还需要：

1. 服务端能检测到"锁屏/登录界面"状态（`CGSessionCopyCurrentDictionary` 的
   `CGSSessionScreenIsLocked`）；
2. 解锁注入：`CGEvent` 输入密码到登录窗口——登录窗口是 secure input，合成事件通常无效；
   可行路径是 `AuthorizationCreate` + `unlockScreen` 私有 API 或 FileVault 解锁接口，
   都有权限/签名要求。

结论：R3 依赖服务端新能力，先只定存储（Keychain，条目 `boltkvm-login`），不做 UI。
