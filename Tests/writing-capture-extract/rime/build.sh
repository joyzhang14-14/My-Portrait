#!/bin/bash
# 重编项目内 librime cands/lattice(依赖 homebrew librime:brew install librime)。
# 词库 ice/ + ice-cands/ 大、gitignore,需另行准备(从已有 rime-ice 拷;含编译好的 build/)。
# 源码里的数据目录是项目绝对路径;若仓库移动,改 cands.c/lattice.c 里的路径再重跑本脚本。
set -e
cd "$(dirname "$0")"
HINC=$(ls -d /opt/homebrew/include 2>/dev/null || ls -d /opt/homebrew/Cellar/librime/*/include | head -1)
clang cands.c   -o cands   -I"$HINC" -L/opt/homebrew/lib -lrime -Wl,-rpath,/opt/homebrew/lib
clang lattice.c -o lattice -I"$HINC" -L/opt/homebrew/lib -lrime -Wl,-rpath,/opt/homebrew/lib
echo "built: cands lattice"
