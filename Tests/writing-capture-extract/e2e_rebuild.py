#!/usr/bin/env python3
"""阶段0 端到端:在真实 A–N 事件上跑 rebuild,接 MLX 8b 做同音消歧+尾巴拼接,对照老 pipeline 期望值。
用法: python3 e2e_rebuild.py [1.7b|4b|8b]   默认 8b"""
import sys, json, re, sqlite3, os
import rebuild as R
import extract_compare_v2 as X   # newExtract / loadev(已含回车检测)
import mlx_constrained as MC
from mlx_lm import load, generate

SIZE = sys.argv[1] if len(sys.argv) > 1 else "14b"
MID = {"1.7b": "mlx-community/Qwen3-1.7B-4bit", "4b": "mlx-community/Qwen3-4B-4bit",
       "8b": "mlx-community/Qwen3-8B-4bit", "14b": "mlx-community/Qwen3-14B-4bit"}[SIZE]
TAG = {"1.7b": "qwen3-1.7b", "4b": "qwen3-4b", "8b": "qwen3-8b", "14b": "qwen3-14b"}[SIZE]
con = sqlite3.connect(os.path.expanduser("~/.portrait/portrait.sqlite"))
print(f"加载 MLX {SIZE}…", flush=True)
m, tok = load(MID); ted, vs = MC.tokenizer_data(tok, TAG)
SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}

# disambig 模式(14b,词级 TOP 偏置 + 富上下文):默认信 TOP,只在明显同音选错时换。
def model_fn(p):
    if p.get('mode') != 'disambig': return None
    top = p['top']; alt = [w for w in p['words'] if w != top]
    user = ("用户在聊天 app 里用拼音打字,输入法默认上屏了一个词,但可能选错同音字了。结合上下文判断默认对不对:"
            "对就保留,只在明显选错(同音字不合语境)时才换。\n"
            f"上下文(当前句已确定的前文 + app + 最近对话):\n{p['context'][:400]}\n"
            f"拼音「{p['py']}」默认上屏=「{top}」。其他同音候选: {' / '.join(alt[:6])}\n"
            "输出这里最合理的那个词(默认合理就输出默认那个)。只输出一个词,别的不要。")
    pr = tok.apply_chat_template([{"role": "user", "content": user}], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    try:
        out = re.sub(r'<think>.*?</think>', '', generate(m, tok, prompt=pr, max_tokens=24, verbose=False), flags=re.S).strip()
        mm = re.search(r'[一-鿿]+', out)
        return mm.group(0) if mm else None
    except Exception:
        return None

# A–N 固定用例:(标签, 事件ids, [期望子串…], [不该出现…])
FIX = [
    ("A 点睡的",   [523],  ["我今天早上5点睡的"], []),
    ("B 啥/没看懂", [596],  ["啥", "没看懂"], []),
    ("E 卖个惨/发烧",[1123], ["卖个惨", "你发烧"], ["mai ge can", "fa shao"]),
    ("F 逆天",     [1128,1129], ["逆天"], ["你替"]),
    ("H 特定的人",  [1131], ["就是你有什么问题就问特定的人"], []),
    ("I Google生态",[1132], ["大多数人都很喜欢Google的生态"], []),
    ("J gmail不幻觉",[1132], ["gmail"], ["购买了"]),
    ("M 越高越好",  [1153], ["越高越好"], ["yue gao yue h"]),
    ("K 特点/用",   [1143,1144], ["特点"], []),
]

def convo_ctx(ev):
    """富上下文:app + 该会话同 app 同天的周围对话(老 staged,时间序)。"""
    r = con.execute("SELECT bundle_id, started_at FROM typing_events WHERE id=?", (ev['id'],)).fetchone()
    if not r: return ""
    bundle, ts = r
    day = con.execute("SELECT date_utc FROM writing_records_staged WHERE reference_typing_event_ids LIKE ? LIMIT 1", (f"%{ev['id']}%",)).fetchone()
    rows = []
    if day:
        rows = [x[0] for x in con.execute(
            "SELECT text FROM writing_records_staged WHERE date_utc=? AND app LIKE ? ORDER BY start_ts",
            (day[0], "%" + bundle.split('.')[-1] + "%")).fetchall()]
    app = bundle.split('.')[-1]
    return f"app:{app}\n最近对话:\n" + "\n".join(f"  - {t[:40]}" for t in rows[:24])

print("=== A–N 端到端重建(14b disambig + 富上下文)===", flush=True)
ok = 0
for tag, ids, want, avoid in FIX:
    evs = X.loadev(ids)
    rebuilt = []
    for ev in evs:
        ctx = convo_ctx(ev)
        sends = R.event_sends_with_ts(ev, X)
        for text, t0, t1, is_send in sends:
            ks = R.keys_in_window(con, ev['bundle'], t0, t1)
            fixed, info = R.reconstruct_message(text, ks, context=ctx, model_fn=model_fn)
            rebuilt.append(fixed)
    blob = " | ".join(rebuilt)
    hit_want = [w for w in want if any(w in r for r in rebuilt)]
    hit_avoid = [a for a in avoid if a in blob]
    good = len(hit_want) == len(want) and not hit_avoid
    ok += good
    print(f"\n[{tag}] {'✓' if good else '✗'}")
    print(f"   期望命中: {hit_want}/{want}" + (f"  ⚠️漏:{set(want)-set(hit_want)}" if len(hit_want)<len(want) else ""))
    if hit_avoid: print(f"   ⚠️不该出现却有: {hit_avoid}")
    print(f"   重建结果: {rebuilt}")
print(f"\n=== {ok}/{len(FIX)} 用例通过 | 14b disambig 调用 {R.DISAMBIG_CALLS[0]} 次 ===", flush=True)
