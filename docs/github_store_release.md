# GitHub Actions 商店发布

仓库中的 `.github/workflows/store-release.yml` 会先运行 `flutter analyze` 和
`flutter test`。验证通过后，iOS 和 Android 发布任务并行执行：

- iOS 构建正式签名 IPA，并上传到 App Store Connect 的 TestFlight。
- Android 构建正式签名 AAB，并上传到 Google Play。

推送 `v1.2.3` 形式的 tag 会自动发布两端。tag 发布固定进入 TestFlight 和
Google Play `internal` 测试轨道，不会自动推送 Play production。也可以在
GitHub 的 **Actions > Build and release mobile apps > Run workflow** 中手动选择
平台、版本、Play 轨道和 `draft/completed` 状态。

## 1. GitHub Environments

在仓库 **Settings > Environments** 创建：

- `app-store`
- `play-store`

如需发布前人工确认，可在 environment 中设置 required reviewers。下面的
Secrets 可以放在对应 environment；若不需要隔离，也可以建立同名的 repository
secrets。

## 2. Apple 配置

先确认 App Store Connect 中已经存在 bundle ID
`com.lumiaiq.MotionCapture` 对应的 App。创建具有 App Manager 权限的 App Store
Connect API Key，并准备 Apple Distribution 证书：

| Secret | 内容 |
| --- | --- |
| `ASC_API_KEY_ID` | App Store Connect API Key ID |
| `ASC_API_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_API_PRIVATE_KEY` | `AuthKey_*.p8` 的完整文本 |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | 带私钥的 `.p12` 文件 Base64 |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |

可选 repository/environment variable：

| Variable | 默认值 |
| --- | --- |
| `IOS_TEAM_ID` | `UXQMR4GU6P` |

在 macOS 生成证书 Secret 的示例：

```bash
base64 -i ios_distribution.p12 | pbcopy
```

流水线会通过 App Store Connect API 下载 `IOS_APP_STORE` provisioning profile，
调用仓库现有的 `scripts/ios_release.sh` 构建并上传。上传成功只代表构建进入
TestFlight；正式 App Store 上架仍需要补齐商店资料并通过 Apple Review。

## 3. Google Play 配置

Play Console 中必须已经存在 package
`com.lumiaiq.MotionCapture`。第一次 AAB 通常需要先在 Console 手动上传，之后
Android Publisher API 才能管理该应用。

创建 Google Cloud service account，启用 Google Play Android Developer API，
再把 service account 邀请到 Play Console 并授予该 App 的发布权限。

| Secret | 内容 |
| --- | --- |
| `PLAY_SERVICE_ACCOUNT_JSON` | service account JSON 的完整文本 |
| `ANDROID_KEYSTORE_BASE64` | Play upload keystore 的 Base64 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | upload key alias |
| `ANDROID_KEY_PASSWORD` | upload key 密码 |

在 macOS 生成 keystore Secret 的示例：

```bash
base64 -i upload-keystore.jks | pbcopy
```

必须使用当前 Play App 已登记的 upload key。流水线只会在临时 runner 中还原
keystore 和 `android/key.properties`，两者都不会作为 artifact 上传。

## 4. 触发发布

自动发布测试版本：

```bash
git tag v1.2.3
git push origin v1.2.3
```

手动发布可以选择 `internal`、`alpha`、`beta` 或 `production`。选择
`production + completed` 会直接提交到正式轨道，因此建议给 `play-store`
environment 配置 required reviewer。

每次构建的 IPA/AAB 会作为 GitHub Actions artifact 保留 14 天。构建号使用 UTC
epoch seconds，以满足 App Store 与 Play Store 对递增 build/version code 的要求。
