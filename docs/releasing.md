# 发布流程（GitHub Actions + Releases）

推送版本标签后，GitHub Actions 会自动编译 `BoltKVM.app`、运行测试、打包带 SHA-256 校验和的 zip，并创建 GitHub Release。

## 日常发布

```bash
# Info.plist 中的版本号仅为默认值，CI 构建时会用 tag 覆盖
git tag v0.2.0
git push origin v0.2.0
```

`.github/workflows/release.yml` 执行步骤：

1. 运行 `swift build -c release`；
2. 运行 `boltkvm selftest` 与 `boltkvm cryptotest`（纯协议与加解密自测，无需系统 TCC 权限）；
3. 将标签名写入 `Packaging/Info.plist` 的 `CFBundleShortVersionString`，将 `GITHUB_RUN_NUMBER` 写入 `CFBundleVersion`；
4. 调用 `Packaging/build-app.sh` 组装 `dist/BoltKVM.app`，使用 `ditto` 压缩为 zip 并生成 `.sha256` 校验文件；
5. 若仓库配置了 `MACOS_CERT_P12` 密钥则使用 Developer ID 签名，否则使用 ad-hoc 签名；
6. 通过 `softprops/action-gh-release` 创建 Release，上传 zip 与 `.sha256` 并自动生成变更说明。

也可在 GitHub Actions 页面选择 Release 工作流手动触发（`workflow_dispatch`）。

## 持续集成（CI）

`.github/workflows/ci.yml` 在每次推送 `main` 或发起 PR 时执行：

1. `swift build -c release` 编译；
2. `scripts/test.sh` 跑全部 XCTest 单元测试（不写死数量；没有音频输出设备的机器会跳过
   音频回归项，GitHub 的 macOS runner 就属于这种）；
3. 运行 `selftest` 与 `cryptotest`；
4. 执行 `Packaging/build-app.sh` 组装应用并上传为构建产物（Artifact）。

## 签名与公证限制

| 签名方式 | 前提条件 | 运行表现 |
|---|---|---|
| ad-hoc（默认） | 无需配置密钥 | 下载后带有隔离属性，首次需右键「打开」或执行 `xattr -dr com.apple.quarantine /Applications/BoltKVM.app` |
| Developer ID | 配置证书相关 Secrets | 具备开发者签名身份，但仍未公证 |
| Apple 公证（Notarization） | 需开启 Hardened Runtime | **当前不支持** |

**不支持公证的原因**：Apple 公证强制要求开启 Hardened Runtime（`--options runtime`），但实测开启 Hardened Runtime 后，进程调用私有 `CGVirtualDisplay` 接口创建虚拟显示器会被系统拒绝。为保证无头被控端正常创建虚拟屏，打包脚本默认关闭 Hardened Runtime（可通过 `BOLTKVM_HARDENED_RUNTIME=1` 显式开启）。

## 本地重编译与 TCC 权限保持

macOS 的 TCC 权限（屏幕录制、辅助功能、本地网络）绑定应用的签名身份。使用默认 ad-hoc 签名时，每次重编译都会改变二进制的 `cdhash`，导致系统将其视为新应用并要求重新授权。

本地开发时，建议生成稳定的自签名代码签名证书：

```bash
./scripts/make-signing-identity.sh
BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local" ./Packaging/build-app.sh
```

使用固定证书签名后，重新编译不会丢失已授予的 TCC 权限。

## 可选仓库密钥（Secrets）

| Secret 名称 | 用途 |
|---|---|
| `MACOS_CERT_P12` | Base64 编码的 Developer ID 证书（`.p12`） |
| `MACOS_CERT_PASSWORD` | 证书导入密码 |
| `MACOS_SIGN_IDENTITY` | 签名标识名，默认 `Developer ID Application` |

未配置上述密钥时，发布流水线自动回退为 ad-hoc 签名。
