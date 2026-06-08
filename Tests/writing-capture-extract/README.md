# 写作采集 pipeline · scratch harness 存档

Python scratch 脚本,在真实库 `~/.portrait/portrait.sqlite` 上跑写作采集 pipeline 的算法逻辑,
**改 Swift 前先在这里验**。不是 SwiftPM 单测(Swift 构建不碰这个目录)。

## 文件

| 文件 | 作用 |
|---|---|
| `extract_compare_v2.py` | unifiedExtract v2(edit_log 回放)+ **回车检测**(查 keystroke_log `\r`/`\n` 区分真发送 vs 退格草稿)+ 全量对照旧版 |
| `faithful_pipeline.py` | 忠实全本地 MLX pipeline(`1.7b\|4b\|8b`):v2 切分 + 组级击键 gate + slash gate + **librime AxCleanup** + supersede + merge + 完整记录 Pass4 + is_residue → 写 `Pipeline成品-新pipeline-<size>.md` |
| `gen_raw.py` / `gen_local_fusion.py` / `merge_final.py` | 原始切分 / librime+MLX fusion 重建 / 合并云端 canvas |
| `harness.py` / `mlx_constrained.py` / `llm.py` | 基础设施(读 Swift prompt、MLX 约束解码、本地模型调用) |
| `librime-tools/cands.c` `lattice.c` | librime C 桥源码(`cands <连写拼音> <n>` 出候选;`lattice` 出 TOP+逐音节)。编译:`clang cands.c -o cands -I/opt/homebrew/opt/librime/include -L/opt/homebrew/opt/librime/lib -lrime` |
| `PIPELINE-ALGORITHM.md` | 整条 pipeline 算法 spec(给 Claude 自己看,§12 有 A–N 退步表) |
| `RESEARCH-ime-fix.md` | **IME 重建修复调研报告**(老靠 sonnet/新断在 gate;全本地路线=librime+选字数字+MLX消歧+防幻觉guard) |
| `extract_compare.py` / `handtyped_audit.py` / `unifiedExtract_replay.patch` | 早期版本(历史存档) |

## 当前状态(2026-06-08):优化前检查点

- 回车检测已验证(旧 193→新 169,清 24 条草稿碎片,0 回归);8b 跑批产出 `Pipeline成品-新pipeline-8b.md`。
- 用户逐条对照发现 **A–N 共 14 处"老 pipeline 比新的全"** 的退步(详见 `RESEARCH-ime-fix.md` + `~/Desktop/Pipeline问题清单.md`),
  根因主旋律 = **IME 尾巴重建**(类1/3):老 pipeline 靠 sonnet 读击键脑补汉字,新 harness 一道 gate 把 LLM 屏蔽了 + 本地模型弱。
- **下一步 = 阶段0 优化**(本目录内):改 `faithful_pipeline.py::axcleanup`(砍 gate + librime+选字数字确定性重建 +
  英文拦截 + 防幻觉 guard + 按 Enter 分段)+ 改 `extract_compare_v2.py` 的 supersede/merge(类4/5a),A–N 回归 0 幻觉。
  **Swift 移植(阶段2)推迟,先在 harness 测好。**

## 怎么跑

```bash
python3 extract_compare_v2.py            # v2 切分 + 回车检测,全量对照旧版(0 回归校验)
python3 faithful_pipeline.py 8b          # 忠实全本地 MLX 8b pipeline → 写产出 md
```

依赖:`~/.portrait/portrait.sqlite`、Python3、MLX(`mlx_lm`)、homebrew librime(`/tmp/rime-test/cands`)。
