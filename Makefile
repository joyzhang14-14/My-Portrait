# My-Portrait release Makefile
#
# 典型流程(第一次发布):
#   make sparkle-keys     # 一次性,把 EdDSA 公钥贴进 project.yml,再 commit
#   xcodegen generate     # 重新出 .xcodeproj 把公钥嵌进 Info.plist
#
# 每次发版:
#   make release          # build → notarize → dmg → sparkle (一条龙)
#   # 把 sparkle.sh 输出的 <item> 贴进 docs/appcast.xml
#   # git push + 上传 .dmg 到对应 GitHub release
#
# 中间步骤也可以单独跑:
#   make build / notarize / dmg / sparkle

.PHONY: build notarize dmg sparkle release sparkle-keys clean

SHELL := /bin/bash

build:
	@scripts/release/build.sh

notarize:
	@scripts/release/notarize.sh

dmg:
	@scripts/release/dmg.sh

sparkle:
	@scripts/release/sparkle.sh

# 一条龙(build → notarize → dmg → sparkle 签名 + 打印 appcast 片段)
release: build notarize dmg sparkle

# 一次性:生成 Sparkle EdDSA 密钥对(私钥进 Keychain,公钥贴 project.yml)
sparkle-keys:
	@scripts/release/generate-keys.sh

clean:
	rm -rf build/
