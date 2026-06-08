import re, sqlite3, os
from mlx_lm import load, generate
import rebuild as R
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
m, tok = load("mlx-community/Qwen3-14B-4bit")
def ctx_around(day, al, target, n=7):
    rows=[r[0] for r in con.execute("SELECT text FROM writing_records_staged WHERE date_utc=? AND app LIKE ? ORDER BY start_ts",(day,al)).fetchall()]
    idx=next((i for i,t in enumerate(rows) if target and target[:4] in t), len(rows)//2)
    return rows[max(0,idx-n):idx]
def pick(py, convo, prefix):
    words=R.cands(py,8)
    user=("用户在 Discord 用拼音打了一个词,下面是输入法给的候选词。结合上下文,选出用户在这句话里真正想打的那个词。\n"
          f"最近对话:\n"+"\n".join(f"  - {c}" for c in convo)+
          f"\n当前消息前文:「{prefix}」← 后面紧跟这个词。\n"
          f"拼音「{py}」的候选词(按输入法默认排序): {' / '.join(f'{i+1}.{w}' for i,w in enumerate(words))}\n"
          "结合前文和对话,哪个候选最通顺合理?直接输出那个词(必须是候选之一)。注意「的/得/地」要符合语法。")
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    out=re.sub(r'<think>.*?</think>','',generate(m,tok,prompt=pr,max_tokens=24,verbose=False),flags=re.S).strip()
    mm=re.search(r'[一-鿿]+',out); return (mm.group(0) if mm else out), words
CASES=[("shuide","2026-05-27","%Discord%","我今天早上5点睡的","我今天早上5点","睡的"),
 ("buxing","2026-06-05","%Discord%","我在想qwen为什么不行","我在想qwen为什么","不行"),
 ("fashao","2026-06-05","%Discord%","你发烧","你","你发烧"),
 ("tedian","2026-06-05","%Discord%","特点","","特点"),
 ("maigecan","2026-06-05","%Discord%","卖个惨","","卖个惨")]
res=[]
for py,day,al,target,prefix,exp in CASES:
    got,words=pick(py,ctx_around(day,al,target),prefix)
    inlist='在候选' if got in words else '不在候选'
    ok='✓' if got in exp or exp.endswith(got) else '✗'
    res.append(f"{ok} py={py} → 14b={got!r}({inlist}) 候选={words[:4]} 期望={exp!r}")
open('/tmp/dbg_pick.txt','w').write('\n'.join(res))
