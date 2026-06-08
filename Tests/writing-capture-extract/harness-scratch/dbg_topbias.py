import re, sqlite3, os
from mlx_lm import load, generate
import rebuild as R
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
m, tok = load("mlx-community/Qwen3-8B-4bit")
def ctx_around(day, al, target, n=7):
    rows=[r[0] for r in con.execute("SELECT text FROM writing_records_staged WHERE date_utc=? AND app LIKE ? ORDER BY start_ts",(day,al)).fetchall()]
    idx=next((i for i,t in enumerate(rows) if target and target[:4] in t), len(rows)//2)
    return rows[max(0,idx-n):idx]
def topbias(py, app, convo, prefix):
    word=R.cands(py,6); top,_=R.lattice(py)
    user=("用户在聊天里用拼音打字,输入法默认上屏了一个词,但可能选错同音字了。你结合上下文判断默认对不对。\n"
          f"app: {app}\n最近对话(时间序,最后是当前消息):\n"+"\n".join(f"  - {c}" for c in convo)+
          f"\n当前消息前文:「{prefix}」,后面拼音「{py}」输入法**默认上屏=「{top}」**。\n"
          f"该拼音其他候选: {' / '.join(w for w in word if w!=top)}\n"
          f"问:结合对话和前文,默认的「{top}」在这里合理吗?\n"
          f"- 合理就直接输出「{top}」。\n- 只有明显不合理(同音选错)才从候选里换,输出换后的词。\n只输出一个词。")
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    out=re.sub(r'<think>.*?</think>','',generate(m,tok,prompt=pr,max_tokens=24,verbose=False),flags=re.S).strip()
    mm=re.search(r'[一-鿿]+',out); return (mm.group(0) if mm else out), top
CASES=[("shuide","2026-05-27","%Discord%","我今天早上5点睡的","我今天早上5点","睡的"),
 ("maigecan","2026-06-05","%Discord%","卖个惨","","卖个惨"),
 ("buxing","2026-06-05","%Discord%","我在想qwen为什么不行","我在想qwen为什么","不行"),
 ("fashao","2026-06-05","%Discord%","你发烧","你","你发烧"),
 ("tedian","2026-06-05","%Discord%","特点","","特点")]
res=[]
for py,day,al,target,prefix,exp in CASES:
    got,top=topbias(py,"Discord",ctx_around(day,al,target),prefix)
    ok='✓' if got in exp or exp.endswith(got) else '✗'
    res.append(f"{ok} py={py} TOP={top} → 模型={got!r} 期望含={exp!r}")
open('/tmp/dbg_tb.txt','w').write('\n'.join(res))
