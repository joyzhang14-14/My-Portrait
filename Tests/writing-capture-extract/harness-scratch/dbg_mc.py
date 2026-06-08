import re
from mlx_lm import load, generate
import rebuild as R
m, tok = load("mlx-community/Qwen3-8B-4bit")
def mc(py, context):
    choices = R.cands(py, 6)
    user = (f"用户在聊天里用拼音「{py}」打了一个词。结合上下文,从下面候选里选出最合理的一个,直接输出那个词,别的不要。\n"
            f"上下文: {context}\n候选: {' / '.join(choices)}")
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    out = generate(m, tok, prompt=pr, max_tokens=20, verbose=False)
    out = re.sub(r'<think>.*?</think>','',out,flags=re.S).strip()
    return out, choices
res=[]
for py,ctx in [("shuide","我今天早上5点"),("maigecan","朋友吐槽工作累,我回他:你别在这儿"),("fashao","你发烧了吗,多喝水"),("buxing","qwen为什么")]:
    r,ch=mc(py,ctx); res.append(f"py={py} ctx={ctx[:16]} 候选={ch[:4]} → 选={r!r}")
open('/tmp/dbg3.txt','w').write('\n'.join(res))
