import re
from mlx_lm import load, generate
import rebuild as R
m, tok = load("mlx-community/Qwen3-8B-4bit")
def think(py, top, syls, context):
    user = (f"用户用拼音打字,这段拼音「{py}」要从候选里选字。结合上下文判断用户真正想打的词。\n"
            f"上下文: {context}\n各音节候选:\n" + "\n".join(f"  {s}: {' '.join(c)}" for s,c in syls)
            + "\n先简短推理再给答案。最后一行只写:答案=XX")
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=True)
    out = generate(m, tok, prompt=pr, max_tokens=600, verbose=False)
    mm=re.search(r'答案[=:＝]\s*([一-鿿]+)', out)
    return (mm.group(1) if mm else out[-40:])
res=[]
for py,ctx in [("shuide","我今天早上5点___ (在说几点睡觉)"),("maigecan","朋友吐槽工作,我回:别在这___ 了 (装可怜博同情)")]:
    top,syls=R.lattice(py); syls=[(s,c[:8]) for s,c in syls]
    res.append(f"py={py} TOP={top} → think答案={think(py,top,syls,ctx)!r}")
open('/tmp/dbg2.txt','w').write('\n'.join(res))
