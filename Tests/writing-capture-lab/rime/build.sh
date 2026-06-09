#!/bin/bash
# 编译 cands / lattice(依赖 homebrew librime)。词库 ice/ 需另行准备(见 README.md,gitignore)。
set -e
cd "$(dirname "$0")"
HINC=$(ls -d /opt/homebrew/include 2>/dev/null || ls -d /opt/homebrew/Cellar/librime/*/include | head -1)
clang cands.c   -o cands   -I"$HINC" -L/opt/homebrew/lib -lrime -Wl,-rpath,/opt/homebrew/lib
clang lattice.c -o lattice -I"$HINC" -L/opt/homebrew/lib -lrime -Wl,-rpath,/opt/homebrew/lib 2>/dev/null || true
echo "built: cands $([ -x lattice ] && echo lattice)"
