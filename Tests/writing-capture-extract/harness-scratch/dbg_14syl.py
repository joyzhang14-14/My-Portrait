import re, sqlite3, os
from mlx_lm import load, generate
import rebuild as R
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
m, tok = load("mlx-community/Qwen3-14B-4bit")
def ctx_around(day, al, target, n=7):
    rows=[r[0] for r in con.execute("SELECT text FROM writing_records_staged WHERE date_utc=? AND app LIKE ? ORDER BY start_ts",(day,al)).fetchall()]
    idx=next((i for i,t in enumerate(rows) if target and target[:4] in t), len(rows)//2)
    return rows[max(0,idx-n):idx]
def syl(py, convo, prefix):
    top,syls=R.lattice(py)
    user=("用户在 Discord 用拼音打字。结合上下文,为这段拼音的每个音节从候选里挑出最合理的字,拼成词。\n"
          f"最近对话:\n"+"\n".join(f"  - {c}" for c in convo)+
          f"\n当前消息前文:「{prefix}」,后面拼音「{py}」。输入法默认拼出「{top}」(可能选错同音字)。\n"
          "各音节候选(每字必须从对应行选):\n"+"\n".join(f"  {s}: {' '.join(c[:8])}" for s,c in syls)+
          f"\n结合上下文,输出最合理的 {len(syls)} 个汉字(每字来自对应行)。只输出汉字。")
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    out=re.sub(r'<think>.*?</think>','',generate(m,tok,prompt=pr,max_tokens=24,verbose=False),flags=re.S).strip()
    mm=re.search(r'[一-鿿]+',out); return (mm.group(0) if mm else out), top, syls
CASES=[("shuide","2026-05-27","%Discord%","我今天早上5点睡的","我今天早上5点","睡的"),
 ("maigecan","2026-06-05","%Discord%","卖个惨","","卖个惨"),
 ("buxing","2026-06-05","%Discord%","我在想qwen为什么不行","我在想qwen为什么","不行"),
 ("fashao","2026-06-05","%Discord%","你发烧","你","你发烧")]
res=[]
for py,day,al,target,prefix,exp in CASES:
    got,top,syls=syl(py,ctx_around(day,al,target),prefix)
    valid = len(got)==len(syls) and all(got[i] in syls[i][1] for i in range(len(syls))) if got else False
    ok='✓' if (got in exp or exp.endswith(got)) else '✗'
    res.append(f"{ok} py={py} TOP={top} → 14b音节={got!r} 校验{'过' if valid else '失败'} 期望含={exp!r}")
open('/tmp/dbg_14syl.txt','w').write('\n'.join(res))
