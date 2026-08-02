# Android 自动更新发布

客户端只接受 Ed25519 签名的更新清单；加速下载源不被信任，下载完成后仍会校验 APK 的 SHA-256、包名、版本号和签名证书。

## 发布前一次性配置

1. 创建并妥善保存 Android release keystore；不要使用当前的 debug keystore。
2. 将 release keystore 和密码保存为 GitHub Actions Secrets，并让 release 构建始终使用同一证书。
3. 生成一对 Ed25519 更新清单签名密钥。私钥只保存为 CI Secret；将 Base64 编码的 32-byte 公钥作为 release 编译参数：

```text
--dart-define=UPDATE_PUBLIC_KEY_BASE64=<base64-public-key>
```

4. 创建 `update-feed` 分支，在其中发布 `updates/latest.json`。客户端按以下顺序读取：

```text
https://fastly.jsdelivr.net/gh/kobe24o/SofterPlease@update-feed/updates/latest.json
https://raw.githubusercontent.com/kobe24o/SofterPlease/update-feed/updates/latest.json
```

## 清单格式

`latest.json` 是 envelope，而不是直接 JSON：

```json
{
  "protocol": 1,
  "payload": "<Base64 UTF-8 manifest>",
  "signature": "<Base64 Ed25519 signature>"
}
```

被签名的 payload：

```json
{
  "version": "2.2.2",
  "build_number": 5,
  "platform": "android",
  "file_name": "softerplease-2.2.2.apk",
  "package_name": "com.softerplease.app",
  "signing_certificate_sha256": "<release certificate SHA-256>",
  "sha256": "<APK SHA-256>",
  "download_urls": [
    "https://ghfast.top/https://github.com/kobe24o/SofterPlease/releases/download/v2.2.2/softerplease-2.2.2.apk",
    "https://github.com/kobe24o/SofterPlease/releases/download/v2.2.2/softerplease-2.2.2.apk"
  ],
  "notes": "更新说明"
}
```

加速地址必须放在首位，GitHub 官方 Release 地址必须保留为回退。只有上述内容已签名并且 APK 全部校验通过时，客户端才会唤起系统安装器。
