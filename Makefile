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
#   build.sh 先用 Xcode export(中间产物 Apple Development 签),再用本机
#   keychain 自签的 cert MyPortraitDev 整体重签 —— 跟 My-Smart-Bar /
#   My-Orphies 同款方案。
#
#   为啥不用 ad-hoc(`codesign --sign -`):ad-hoc 的 designated requirement
#   含 cdhash,每次 build 漂,Sparkle 跨版本判 identity 不一致拒绝自动升级。
#   MyPortraitDev 自签 cert 的 DR 含稳定的 cert subject hash,跨版本 TCC +
#   Sparkle 都吃这套。
#
#   为啥不用 Apple Development cert:绑你 Apple ID(签名里直接暴露作者
#   邮箱),账号变更 / expired 后签名身份就丢。自签 cert 跟 Apple ID 解耦。
#
#   一次性建 cert(本机做一次):Keychain Access → Certificate Assistant
#   → Create a Certificate(Name=MyPortraitDev,Self Signed Root,
#   Code Signing,trust=Always Trust)。
#
#   用户安装时仍需 xattr -d com.apple.quarantine 绕 Gatekeeper(README
#   已说明);Sparkle 自动升级路径不走 Gatekeeper,体验透明。
#
#   付了年费后,把 ExportOptions.plist method 改成 developer-id,build.sh
#   里 codesign 重签那段删掉,`release:` target 改成 `build notarize dmg
#   sparkle`。

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
