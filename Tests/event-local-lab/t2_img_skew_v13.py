"""v1.3 图像通道 skew 修复的确定性部分(P0-2)。

问题:train.jsonl 里 183 行喂 2 张图,生产(v12_day.py)写死单图 → train/inference skew。
修法:组装时全部降到单图(images[:1])。但教师是【看着两张图】写的答案 ——
对抗核查实测 2 图样本里有 43 句/31 样本在整份 OCR 里零命中,即内容只可能来自
图像视觉通道。第二张图删掉后,这些句子若留在答案里 = 教模型凭空生成 = 手工造幻觉。

本脚本做确定性的候选圈定(高召回):
  对每个 2 图 work 样本,把 activity 切句,抽 token(拉丁串≥4 / CJK 串≥2),
  一句话的全部 token 在 corpus(OCR块+题头)里零命中 → 候选。
产出 /tmp/v13_imgfix_candidates.json,交给【极窄 LLM 步】逐句裁决:
  只回答"该句内容在第一张图里可见吗" —— 只准整句删除,不准重写(防手术失控)。
裁决结果由 t2_assemble_v13.py 消费,其余句子逐字节不动。
"""
import json
import re
import unicodedata

WORK = '/tmp/work_v13.json'
OUT = '/tmp/v13_imgfix_candidates.json'
PKG = '/tmp/t2v3/t2_pkg_v3'

# 与推理侧同一套归一化(v12_day.py)
def norm(s):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(s))).lower()


SENT_SPLIT = re.compile(r'(?<=[。;；!！?？])')
LATIN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._\-/+]{3,}')
CJK = re.compile(r'[一-鿿]{2,}')
# 叙述功能词:出现在几乎每句里,不算内容 token(否则"用户在画面中…"永远命中不了)
CJK_STOP = {'用户', '画面', '窗口', '屏幕', '内容', '显示', '可见', '正在', '同时', '随后',
            '继续', '接着', '然后', '其中', '以及', '这个', '那个', '一个', '两个', '会话',
            '前台', '背景', '打开', '界面', '页面', '当前', '里的', '中的', '截图', '助手',
            '对话', '进行', '操作', '任务', '项目', '工作', '代码', '文件', '模式', '状态'}


def tokens(sent):
    lat = [t for t in LATIN.findall(sent) if len(t) >= 4]
    cjk = [t for t in CJK.findall(sent) if t not in CJK_STOP]
    return lat, cjk


def main():
    W = json.load(open(WORK))
    cands, n_sent_total = [], 0
    for w in W['work']:
        if len(w['images']) < 2:
            continue
        corpus = norm(w['ocr'] + w['head_new'])
        act = w['answer'].get('activity') or ''
        sents = [s for s in SENT_SPLIT.split(act) if s.strip()]
        unsupported = []
        for i, s in enumerate(sents):
            lat, cjk = tokens(s)
            checkable = lat + cjk
            # 门槛:至少 1 个拉丁硬 token,或 ≥3 个 CJK 内容词(纯短叙述句不圈)
            if not (lat or len(cjk) >= 3):
                continue
            if any(norm(t) in corpus for t in checkable):
                continue
            unsupported.append({'idx': i, 'text': s})
        n_sent_total += len(sents)
        if unsupported:
            cands.append({
                'id': f"{w['day']}_s{w['key']}",
                'image1': f"{PKG}/{w['images'][0]}",
                'image2': f"{PKG}/{w['images'][1]}",
                'sentences': sents,
                'candidates': unsupported,
            })
    json.dump(cands, open(OUT, 'w'), ensure_ascii=False, indent=1)
    n_c = sum(len(c['candidates']) for c in cands)
    print(f"2图样本 {sum(1 for w in W['work'] if len(w['images'])>1)} 条 / "
          f"共 {n_sent_total} 句 → 零命中候选 {n_c} 句 / {len(cands)} 样本 → {OUT}")
    for c in cands:
        for u in c['candidates']:
            print(f"  {c['id']} [{u['idx']}] {u['text'][:80]}")


main()
