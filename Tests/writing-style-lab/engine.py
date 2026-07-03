"""mlx_lm 包装:加载、生成、JSON 抽取/修复、重试、llm_calls 落库。

直接沿用 event-local-lab/engine.py 的成熟实现(schema 强制 + 小 prompt +
JSON 修复 + 重试),只把默认模型和 labdb 依赖换成本实验室自己的。

铁律(memory project_local_model_eval):schema 强制 + 小 prompt + 显式禁 thinking。
本地小模型偶发 JSON 崩,repair() 提前兜住(裸换行/裸引号前瞻/尾逗号)。

模型档位:一 agent 一维度,难维度用大模型、易维度用小模型。load(model_id)
带缓存,同 id 不重载;换 id 自动切。DEFAULT_MODEL 只是兜底,真正档位在
dimensions.py 里按维度指定,run.py 按模型分组避免反复重载。
"""
import re
import time
import json

import labdb

# 机器上实际已下载的最新 Qwen(HF 缓存实测):Qwen3.5-27B / Qwen3-30B-A3B /
# 14B / 8B / 4B / 1.7B。想换 Qwen3.6 等新模型:先 `huggingface-cli download
# mlx-community/<id>`,再把这里或 --model 换成对应 id。
DEFAULT_MODEL = "mlx-community/Qwen3-14B-4bit"

_model = None
_tokenizer = None
_model_id = None


def load(model_id: str = DEFAULT_MODEL):
    global _model, _tokenizer, _model_id
    if _model is not None and _model_id == model_id:
        return
    from mlx_lm import load as _load
    print(f"[engine] loading {model_id} …")
    t0 = time.time()
    _model, _tokenizer = _load(model_id)
    _model_id = model_id
    print(f"[engine] loaded in {time.time()-t0:.1f}s")


def current_model():
    return _model_id


def _generate(messages, max_tokens=512, temp=0.2):
    from mlx_lm import generate as _gen
    prompt = _tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True,
        enable_thinking=False,          # Qwen3:禁 thinking,直接出答案
    )
    kwargs = {"max_tokens": max_tokens, "verbose": False}
    try:                                # 新版 mlx_lm 用 sampler 控温
        from mlx_lm.sample_utils import make_sampler
        kwargs["sampler"] = make_sampler(temp=temp)
    except Exception:
        pass
    return _gen(_model, _tokenizer, prompt=prompt, **kwargs)


# ---------------- JSON 抽取 + 修复(移植 LLMJSON) ----------------

def _strip_fence(s: str) -> str:
    s = s.strip()
    s = re.sub(r"^```(?:json|JSON)?\s*\n?", "", s)
    s = re.sub(r"\n?```$", "", s)
    return s


def _extract_balanced(s: str, open_ch: str, close_ch: str):
    start = s.find(open_ch)
    if start < 0:
        return None
    depth, in_str, esc = 0, False, False
    for i in range(start, len(s)):
        ch = s[i]
        if esc:
            esc = False
        elif in_str:
            if ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth == 0:
                    return s[start:i + 1]
    return None


def repair(s: str) -> str:
    """字符串内裸控制字符转义 + 裸引号前瞻判定 + 字符串外尾逗号删除。"""
    out, pending = [], []
    in_str, esc = False, False
    n = len(s)

    def quote_is_terminator(i):
        j = i + 1
        while j < n and s[j].isspace():
            j += 1
        return j >= n or s[j] in ",:}]"

    i = 0
    while i < n:
        ch = s[i]
        if in_str:
            if esc:
                out.append(ch); esc = False
            elif ch == "\\":
                out.append(ch); esc = True
            elif ch == '"':
                if quote_is_terminator(i):
                    out.append(ch); in_str = False
                else:
                    out.append('\\"')
            elif ch == "\n":
                out.append("\\n")
            elif ch == "\r":
                out.append("\\r")
            elif ch == "\t":
                out.append("\\t")
            else:
                out.append(ch)
            i += 1; continue
        if pending:
            if ch.isspace():
                pending.append(ch); i += 1; continue
            if ch in "]}":
                out.extend(pending[1:]); pending = []   # 丢尾逗号
                out.append(ch); i += 1; continue
            out.extend(pending); pending = []
        if ch == ",":
            pending = [","]; i += 1; continue
        if ch == '"':
            in_str = True
        out.append(ch); i += 1
    out.extend(pending)
    return "".join(out)


def parse_json(raw: str, expect: str = "object"):
    s = _strip_fence(raw)
    o, c = ("{", "}") if expect == "object" else ("[", "]")
    frag = _extract_balanced(s, o, c)
    if frag is None:
        raise ValueError("no JSON in output")
    try:
        return json.loads(frag)
    except json.JSONDecodeError:
        return json.loads(repair(frag))


# ---------------- 统一调用入口 ----------------

def call(con, day, purpose, messages, *, group_key=None, expect="object",
         max_tokens=640, retries=1):
    """生成 → 抽取/修复 → 解析;失败补一条"只准 JSON"重试。全程落 llm_calls。"""
    prompt_chars = sum(len(m["content"]) for m in messages)
    last_err = None
    for attempt in range(retries + 1):
        t0 = time.time()
        try:
            raw = _generate(messages, max_tokens=max_tokens)
            obj = parse_json(raw, expect)
            labdb.log_call(con, day, purpose, group_key, prompt_chars, raw,
                           True, int((time.time() - t0) * 1000), _model_id)
            return obj
        except Exception as e:                      # noqa: BLE001 实验线粗放兜
            last_err = e
            labdb.log_call(con, day, purpose, group_key, prompt_chars,
                           f"ERR {e}", False, int((time.time() - t0) * 1000), _model_id)
            messages = messages + [{
                "role": "user",
                "content": "Output ONLY the JSON object. No prose, no markdown fence.",
            }]
    raise RuntimeError(f"{purpose} failed after {retries+1} attempts: {last_err}")
