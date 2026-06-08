import re, sqlite3, os
from mlx_lm import load, generate
import rebuild as R
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
m, tok = load("mlx-community/Qwen3-8B-4bit")

def ctx_around(day, app_like, target, n=7):
    rows=[r[0] for r in con.execute("SELECT text FROM writing_records_staged WHERE date_utc=? AND app LIKE ? ORDER BY start_ts",(day,app_like)).fetchall()]
    # 找 target(或其前文)的位置,取前后窗
    idx=next((i for i,t in enumerate(rows) if target and target[:4] in t), len(rows)//2)
    return rows[max(0,idx-n):idx]   # 取它之前的对话

def rich(py, app, url, convo, prefix, expect):
    word=R.cands(py,6); top,syls=R.lattice(py)
    user=("你在还原用户在聊天 app 里用拼音打的一个词。输入法候选有歧义,你要结合上下文判断用户真正想打哪个。\n"
          f"app: {app}\n" + (f"url: {url}\n" if url else "") +
          "最近这段对话(时间顺序,最后一条就是当前消息):\n" + "\n".join(f"  - {c}" for c in convo) +
          f"\n当前消息已确定的前文: 「{prefix}」,后面紧跟拼音「{py}」要补的词。\n"
          f"拼音「{py}」的候选词: {' / '.join(word)}\n"
          f"逐音节候选: " + " | ".join(f"{s}:{''.join(c[:5])}" for s,c in syls) +
          "\n结合对话主题和前文,这个词最可能是哪个?只输出一个词(从候选里选),别的不要。")
    pr=tok.apply_chat_template([{"role":"user","content":user}],add_generation_prompt=True,tokenize=False,enable_thinking=False)
    out=re.sub(r'<think>.*?</think>','',generate(m,tok,prompt=pr,max_tokens=24,verbose=False),flags=re.S).strip()
    mm=re.search(r'[一-鿿]+',out)
    return (mm.group(0) if mm else out), expect

CASES=[
 ("shuide","com.hnc.Discord","","2026-05-27","%Discord%","我今天早上5点睡的","我今天早上5点","睡的"),
 ("maigecan","com.hnc.Discord","","2026-06-05","%Discord%","卖个惨","","卖个惨"),
 ("buxing","com.hnc.Discord","","2026-06-05","%Discord%","我在想qwen为什么不行","我在想qwen为什么","不行"),
 ("fashao","com.hnc.Discord","","2026-06-05","%Discord%","你发烧","你","你发烧"),
]
res=[]
for py,app,url,day,al,target,prefix,exp in CASES:
    convo=ctx_around(day,al,target); 
    got,_=rich(py,app,url,convo,prefix,exp)
    ok='✓' if exp.endswith(got) or got in exp else '✗'
    res.append(f"{ok} py={py} → 模型={got!r}  期望含={exp!r}")
open('/tmp/dbg_rich.txt','w').write('\n'.join(res))
