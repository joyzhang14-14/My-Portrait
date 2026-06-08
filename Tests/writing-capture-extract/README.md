# 写作采集 · unifiedExtract 消息切分 测试存档

scratch 测试脚本(Python),验证 `WritingCaptureWorker.unifiedExtract`(把一个 session 的
typing_events 切成"用户发出的每条消息")的改写。**不是 SwiftPM 单测**——直接读真实库
`~/.portrait/portrait.sqlite`,跑算法逻辑在真实数据上对照。SwiftPM 测试 target 只扫
`Tests/MyPortraitTests`,这个目录不会被 Swift 构建碰到。

## 背景:为什么要改 unifiedExtract

旧版用「占位符集合(`collectPlaceholders`,某 endValue 作为单条 commit/paste 复现 ≥3 次)+
字段 reset 启发式」切消息,导致桌面问题清单(`~/Desktop/Pipeline问题清单.md`)里的:
- **#5 占位符泄漏 + 消息切碎**:漏掉只出现 1-2 次的占位符(如 `Describe a task…`),既泄漏成
  记录、又被当成边界把会话切成碎片(`然后`/`Spiffy`/`每次都`…)。
- **#3 演进消息丢失**:连续消息之间缺 reset 边界 → 跨事件草稿 `cur` 被一条条覆盖,一串里
  只剩最后一条。

## 改写方案:edit_log 回放(见 `unifiedExtract_replay.patch`)

`submit` = 干净发送;非空 `endValue` = commit 背书的演进草稿(相似度判边界,不相似=新消息);
占位符靠「无 commit 背书(粘贴注入)/ 同事件里显示又被整条删(静止占位符)」识别,不再用集合;
`send-clear`(整框删掉的 commit 背书内容)**仅在 endValue 为空时**用。

## ⚠️ 当前状态:**未合入,已撤回**(2026-06-07)

- 改写曾 commit 为 `b01ff1f`,但用户要求"先测好再接",已 `git reset --hard` 撤回。
  实现保存在 `unifiedExtract_replay.patch`(`git apply` 可重新打上)。
- **`extract_compare.py` 全量对照(四天所有会话,旧版 vs 新版)抓到严重回归**:
  - 新版正确丢掉拼音残渣(`w1`/`xiang`/`p s`…)—— 是改进;
  - 但**误丢一大批真消息**(`OCR合成为什么那么难？` / `那你问Claude啊` / `AMFI（boot-arg）是什么？`
    / 英文 `I usually use AI…` 等,~15-20 条)。
  - **根因**:一条 typing_event 里**连发多条消息、输入框每次回到「占位符」(非空)**的情况
    (claudefordesktop 尤其多)。旧版靠"占位符当标记"在 `withinEventSends` 里拆;新版把
    send-clear 限制成「只在 endValue 空时用」(为干掉 Spiffy 草稿碎片),把这类真·事件内
    多发送一起干掉了。
- **下一步**:新版需补「事件内、占位符为标记的多发送」拆分,且与"打了又删的草稿"区分开
  (两者都是 commit 背书的删除,差别在后面是否真发出 / 字段是否回到占位符静止态)。把
  `extract_compare.py` 报告的回归逐条对到"该留/该丢"全部正确,再考虑合入。

## 怎么跑

```bash
python3 extract_compare.py     # 旧版 vs 新版 全量对照,打印回归/占位符泄漏
python3 handtyped_audit.py     # 按 commit 背书审计:哪些记录不是手打(粘贴/草稿/中途态)
```

依赖:`~/.portrait/portrait.sqlite`(真实库)、Python3 标准库(`sqlite3`/`difflib`)。
脚本里两个 `*Extract` 函数是 Swift `unifiedExtract` 的 Python 复刻,改 Swift 前先在这里验。
