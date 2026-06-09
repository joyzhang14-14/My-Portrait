#!/usr/bin/env python3
"""项目内置 librime 候选封装(阶段四 #41/#42 重建用)。
调用 rime/cands(homebrew librime + 雾凇词库),给拼音返回 top-N 候选 = LLM 重建时的合法搜索空间。
词库 rime/ice 是 65M、gitignore;若缺失见 rime/README.md 准备。绝对路径,不依赖 cwd。"""
import os, subprocess, functools

RIME_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rime")
CANDS_BIN = os.path.join(RIME_DIR, "cands")
ICE = os.path.join(RIME_DIR, "ice")
ICE_USER = os.path.join(RIME_DIR, "ice-cands")

def available() -> bool:
    return os.path.exists(CANDS_BIN) and os.path.isdir(ICE)

@functools.lru_cache(maxsize=4096)
def candidates(pinyin: str, n: int = 15):
    """拼音 → top-N 候选列表(去掉表情/英文映射保留原样)。缺二进制/词库时抛错。"""
    if not available():
        raise RuntimeError("rime/cands 或 rime/ice 缺失;先跑 rime/build.sh 并准备词库(见 rime/README.md)")
    env = {**os.environ, "RIME_SHARED": ICE, "RIME_USER": ICE_USER}
    p = subprocess.run([CANDS_BIN, pinyin, str(n)], capture_output=True, text=True,
                       env=env, cwd=RIME_DIR, timeout=30)
    out = []
    for line in p.stdout.splitlines():
        if line.startswith("["):
            parts = line.split("\t", 1)
            if len(parts) == 2 and parts[1]:
                out.append(parts[1])
    return out

if __name__ == "__main__":
    import sys
    py = sys.argv[1] if len(sys.argv) > 1 else "haibao"
    print(f"{py} → {candidates(py, 8)}")
