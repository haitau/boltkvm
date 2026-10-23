# 发布流程（GitHub Actions + Releases）

目标：打一个 tag，GitHub 自动编译出 `BoltKVM.app`、跑自测、生成带校验和的 zip，
并建成 Release。人不需要本地打包、不需要上传。

## 日常：提 tag

```bash
# 版本号写在 Info.plist 里只是默认值，CI 会用 tag 覆盖
git tag v0.2.0
git push origin v0.2.0        # 只有"发布"才需要 push
```

`.github/workflows/release.yml` 会：

1. `swift build -c release`；
2. 跑 `boltkvm selftest`、`boltkvm cryptotest`（纯协议/加密自测，不需要 TCC）；
3. 把 tag 写进 `Info.plist`（`CFBundleShortVersionString`），`CFBundleVersion` 用
   `GITHUB_RUN_NUMBER`；
4. `Packaging/build-app.sh` 打 `dist/BoltKVM.app`，`ditto` 压成 zip，`shasum -a 256`；
5. 有 `MACOS_CERT_P12` 时用 Developer ID 重签，没有就用 ad-hoc；
6. `softprops/action-gh-release` 建 Release，附件是 zip + `.sha256`，正文自动带
   `generate_release_notes`（对比上一个 tag 的提交）。

手动触发：Actions → Release → Run workflow，填版本号。

## 合并前：CI

`.github/workflows/ci.yml` 在 `push main` / PR 上跑构建 + `scripts/test.sh`（47 个 XCTest）+
`selftest` / `cryptotest` + 打包，产物作为 artifact 上传（ad-hoc 签名，不可直接分发）。

## 签名与公证的现状（重要）

| 方案 | 结果 |
|---|---|
| ad-hoc（默认，无 secrets） | 能跑；下载后有隔离属性，用户要右键打开或 `xattr -dr com.apple.quarantine` |
| Developer ID（有 secrets） | 签名可信；**仍然不能公证** |
| 公证（notarization） | **当前做不到** |

原因是硬碰硬的冲突：公证要求 hardened runtime，而 hardened runtime 会让
`CGVirtualDisplay` 创建失败（2026-10-22 实测：同一个二进制在 CLI 下能建虚拟屏，放进
开启 hardened runtime 的 bundle 里就失败）。而虚拟屏正是服务端存在的意义，所以宁可
不公证也不开 hardened runtime。

Release 正文里写了这一步，用户按右键打开即可。若哪天找到 hardened runtime 下建虚拟屏的
办法（例如换成 ScreenCaptureKit 的虚拟显示 API 或把建屏挪到另一个未加固的 helper），
再把 `BOLTKVM_HARDENED_RUNTIME=1` 打开并加回公证步骤。

## 每次构建 TCC 会重新询问

签名（哪怕自签）变了，macOS 就把 app 当成新程序，屏幕录制权限要重新授予。CI 产物每次
cdhash 都不同，所以用户升级后要重新授权一次——这是 TCC 的规则，不是打包脚本的问题。
本地开发想避免反复授权：用稳定的自签证书（`scripts/make-signing-identity.sh` 生成
`BoltKVM Local`），`BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local"`。

## 需要配置的 secrets（可选）

| Secret | 用途 |
|---|---|
| `MACOS_CERT_P12` | Developer ID 证书（base64） |
| `MACOS_CERT_PASSWORD` | 证书密码 |
| `MACOS_SIGN_IDENTITY` | 签名标识名，默认 `Developer ID Application` |

不配也能发布，只是 ad-hoc。
