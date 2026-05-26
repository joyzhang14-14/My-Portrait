# My-Portrait release Makefile
#
# 典型流程(第一次发布):
#   make sparkle-keys     # 一次性,把 EdDSA 公钥贴进 project.yml,再 commit
#   xcodegen generate     # 重新出 .xcodeproj 把公钥嵌进 Info.plist
#
# 每次发版:
#   make release          # build → dmg → sparkle (一条龙,无 notarize)
#   # 把 sparkle.sh 输出的 <item> 贴进 docs/appcast.xml
#   # git push + 上传 .dmg 到对应 GitHub release
#
# 中间步骤也可以单独跑:
#   make build / notarize / dmg / sparkle
#
# 关于签名:
#   build.sh 直接用 Xcode automatic 签出来的 Apple Development cert,**不二次
#   重签**。
#
#   为啥不用自签 keychain cert(MyPortraitDev / 类似):My-Portrait 核心走
#   ScreenCaptureKit,macOS TCC 对**非 Apple-anchored 签名**直接拒 Screen
#   Recording(auth_value 卡 0),系统设置里给权限也不解锁。这条原始作者
#   在 project.yml 里写明过。Apple Development cert DR 带 `anchor apple
#   generic`,TCC 才认。
#
#   为啥不用 ad-hoc(`codesign --sign -`):ad-hoc 的 DR 带 cdhash,每次
#   build 漂,Sparkle 跨版本判 identity 不一致拒绝自动升级。
#
#   付不起 $99/yr Developer Program → 拿不到 Developer ID + notarize,用户
#   下载 .dmg 第一次仍需 \`xattr -d com.apple.quarantine\` 绕 Gatekeeper
#   (README 已说明);Sparkle 自动升级路径不走 Gatekeeper,体验透明。
#
#   付了年费后,ExportOptions.plist method 改成 developer-id,`release:`
#   target 加 notarize。

.PHONY: build notarize dmg sparkle release sparkle-keys clean

SHELL := /bin/bash

build:
	@scripts/release/build.sh

# notarize 单独可用(需 $99/年 Apple Developer Program)。默认不在 release
# 流程里 —— 当前账号没付费,跑了会 401。
notarize:
	@scripts/release/notarize.sh

dmg:
	@scripts/release/dmg.sh

sparkle:
	@scripts/release/sparkle.sh

# 一条龙(build → dmg → sparkle 签名 + 打印 appcast 片段)
# 不含 notarize —— 当前 Apple ID 没付 Developer Program 年费,跑了必 401。
release: build dmg sparkle

# 一次性:生成 Sparkle EdDSA 密钥对(私钥进 Keychain,公钥贴 project.yml)
sparkle-keys:
	@scripts/release/generate-keys.sh

clean:
	rm -rf build/
