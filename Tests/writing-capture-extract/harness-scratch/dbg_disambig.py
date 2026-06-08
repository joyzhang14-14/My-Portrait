import json, re
import mlx_constrained as MC
from mlx_lm import load, generate
import rebuild as R
m, tok = load("mlx-community/Qwen3-8B-4bit"); ted, vs = MC.tokenizer_data(tok, "qwen3-8b")
SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}
def disambig(py, top, syls, context):
    user = ("根据上下文,为这段拼音的每个音节从它的候选字里挑出用户最可能想打的那个字,拼成词。\n"
            f"上下文(同会话其他消息): {context[:140]}\n"
            f"拼音: {py}   输入法整句最优(参考): {top}\n"
            "各音节候选(必须从对应行里选):\n" + "\n".join(f"  音节{i+1} {s}: {' '.join(c)}" for i,(s,c) in enumerate(syls))
            + f"\n只输出 {len(syls)} 个汉字(每个字必须来自对应音节那行的候选),别的都不要。")
    pr = tok.apply_chat_template([{"role":"user","content":user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    out = generate(m, tok, prompt=pr, max_tokens=60, verbose=False, logits_processors=[MC.json_processor(SCHEMA, ted, vs)])
    return json.loads(re.sub(r'<think>.*?</think>','',out,flags=re.S).strip()).get("text","")
out=[]
for py,ctx in [("shuide","我今天早上5点"),("maigecan","卖惨/装可怜的语境,朋友聊天"),("shuide","水管漏水")]:
    top,syls=R.lattice(py)
    syls=[(s,c[:8]) for s,c in syls]
    r=disambig(py, top, syls, ctx)
    out.append(f"py={py} ctx={ctx[:14]} TOP={top} → 模型={r!r}")
open('/tmp/dbg.txt','w').write('\n'.join(out))
