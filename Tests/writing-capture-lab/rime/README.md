# 项目内置 librime(阶段四 #41/#42 重建的拼音候选)

给拼音返回 top-N 候选 = LLM 重建时只能从中挑字的"合法搜索空间"(verifier rule6 据此拒幻觉)。

## 组成
- `cands.c` / `lattice.c`:librime 调用源码(入 git)。数据目录走环境变量 `RIME_SHARED`/`RIME_USER`。
- `build.sh`:编译(依赖 homebrew `librime`:`brew install librime`)。
- `ice/`:雾凇(rime-ice)词库 + 编译产物,**65M、gitignore**。
- `ice-cands/`:librime user 目录,gitignore。
- 二进制 `cands`/`lattice`:gitignore(各自机器 `build.sh` 重编)。

## 准备(新机器/词库缺失时)
1. `brew install librime`
2. 准备词库到 `ice/`:从已有 rime-ice 拷贝(本机原在 `/tmp/rime-test/ice`),或从
   https://github.com/iDvel/rime-ice 部署。需含编译好的 `build/`。
3. `bash rime/build.sh`
4. 验证:`python3 rime_cands.py haibao` → `['海报','海豹',...]`

## 用法
```python
from rime_cands import candidates
candidates("jieshao", 6)   # → ['介绍','劫杀','截杀','接','解','姐']
```
