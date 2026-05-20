# Before Sharing / Release Checklist

发布前/分享前必须解决的安全 + 配置问题。每项标注来源 audit 编号方便回溯。

## 安全

### [ ] master.key 切到 Data Protection Keychain
**来源**: audit_report.md 问题 10
**位置**: `Sources/MyPortrait/AI/SecretStore.swift:147-180`
**现状**: AES-256 主密钥以 0600 文件存在 `~/Library/Application Support/MyPortrait/master.key`。
本机 admin 任何进程都能读出主密钥 → 解出所有 secrets（OAuth token / API key）。
注释自承"adequate for a dev tool"。
**修复**:
- 短期：`kSecUseDataProtectionKeychain` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存 master key
- 长期：properly-signed app + Keychain
**为什么暂不改**: dev 阶段单机使用，FileVault 锁住时密钥也安全。release 前必须改。
