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
# 关于 notarize:
#   notarize 需要 $99/年 的 Apple Developer Program 会员。当前账号没付费,
#   `make release` 默认跳过 notarize。用户安装后 Gatekeeper 会拦截
#  「无法验证开发者」,需要右键 Open 一次绕过(README 已说明)。
#   付了年费后,把 `release:` 这条 target 改回 `build notarize dmg sparkle`。

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
