# 连接管理器（R1/R2/R3）实现与协议规范

- 状态：已实现（2026-10-23）
- 关联：[连接管理需求](2026-10-22-connection-manager.md)

## 1. 数据模型与存储（R1）

```swift
struct SavedHost: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String          // 显示名称，留空时默认取 host
    var host: String          // IP 地址
    var port: UInt16
    var pskAccount: String?   // keys/ 目录下的凭据文件名，nil 时回退读取 ~/.boltkvm-key
    var width: Int?           // 请求的虚拟屏逻辑宽度（见第 2 节）
    var height: Int?          // 请求的虚拟屏逻辑高度
    var lastConnected: Date?
}
```

- **主机列表文件**：保存在 `~/Library/Application Support/BoltKVM/hosts.json`。首次启动若列表为空且存在旧版 `Prefs.host/port`，自动迁移为第一条记录并清理旧偏好键；
- **分辨率预设**：内置 `1280×720` 至 `3840×2160` 常用比例预设，支持添加自定义分辨率（宽高范围 `640...7680` × `480...4320` 且为偶数，持久化在 `UserDefaults` 的 `hosts.customResolutions`）；
- **画面质量归属**：编码画质（「标准」与「清晰」）属于被控端全局设置，在被控端菜单栏或设置面板中切换；
- **密码生成与保存**：
  - 被控端首次启动无密钥时，自动生成 8 位连接密码（剔除 `0/o/1/l/i` 的小写字母+数字）写入 `~/.boltkvm-key`（`0600`），并在被控端设置面板中展示密码与 SHA-256 指纹；
  - 主控端在主机编辑面板填入一次密码后，密码单独保存在 `~/Library/Application Support/BoltKVM/keys/<host>_<port>`（`0600`），不写入 `hosts.json`。

## 2. 会话分辨率协商协议（R2）

客户端可在握手完成后向服务端下发 `config` 包（`PacketType.config = 11`），请求当次会话的虚拟屏逻辑尺寸。

### 2.1 握手与升级时序

`authOk` 发送并安装基于 PSK 的初始会话加密后：

1. 若服务端在 `authOk` 载荷第 10 字节声明支持前向保密（`FLAG_SUPPORTS_KEY_EXCHANGE`），客户端首先发送 32 字节 `authExchange`（`PacketType.authExchange = 12`）完成 X25519 临时密钥交换并切换会话密钥（超时 2 秒）；
2. 随后，若客户端配置了目标分辨率且服务端在 `authOk` 首字节声明支持配置包（`payload.first == 1`），客户端发送 8 字节 `config` 包（服务端读取超时 1 秒）：

```text
struct SessionConfig (8 bytes, big-endian):
  u16 width      // 逻辑宽度 (320...7680)
  u16 height     // 逻辑高度 (240...4320)
  u8  quality    // 0 = standard (最大编码宽度 3840), 1 = pixel (2x backing 原画)
  u8  reserved
  u16 reserved
```

### 2.2 服务端处理规则

1. 收到合法的 `config` 包且请求尺寸与当前内建虚拟屏不一致时，服务端销毁旧虚拟屏并按新逻辑尺寸重建，随后按 `quality` 计算采集像素尺寸并启动推流；
2. 若客户端未发送 `config` 包（读超时或收到 `timeSync` 等其他包），服务端保持自身的默认分辨率设置，向后兼容旧客户端；
3. 若服务端运行在 `--virtual-display external` 模式或重建失败，则保持原显示器尺寸，客户端通过随后的 `format` 包获知实际画面尺寸；
4. 客户端请求的分辨率仅在当次连接会话内生效，服务端子进程重启后恢复为被控端面板配置的默认分辨率。

CLI 客户端可通过 `--request-size 2560x1440 --request-quality 1` 触发相同的协商流程。

## 3. 远端锁屏自动解锁（R3）受阻说明

要在被控端处于锁屏或登录窗口（`loginwindow`）时自动填入系统密码解锁，需跨越以下系统安全边界：

1. **状态检测**：可通过 `CGSessionCopyCurrentDictionary()` 中的 `CGSSessionScreenIsLocked` 判断是否处于锁屏状态；
2. **输入拦截限制**：`loginwindow` 全程启用 Secure Input，普通用户级进程调用的 `CGEventPost` 合成按键会被系统直接丢弃；
3. **特权要求**：在锁屏下完成认证需要 root 级 `launchd` 特权守护进程（`SMJobBless`）配合私有解锁接口。

由于引入 root 特权守护进程超出了当前单应用免安装的边界，R3 暂不实现。当被控端重启停留在锁屏界面时，统一使用 macOS 系统屏幕共享（`vnc://<地址>`）解锁。
