"""mlx_lm 包装:加载、生成、JSON 抽取/修复、重试、llm_calls 落库。

铁律(memory project_local_model_eval):schema 强制 + 小 prompt。
JSON 修复移植自生产 LLMJSON.repair(裸换行/裸引号前瞻/尾逗号)——
本地小模型同样会犯,提前兜住。
"""
import json
import re
import time

import labdb

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

def call(con, day, purpose, messages, *, session_id=None, expect="object",
         max_tokens=512, retries=1):
    """生成 → 抽取/修复 → 解析;失败补一条"只准 JSON"重试。全程落 llm_calls。"""
    prompt_chars = sum(len(m["content"]) for m in messages)
    last_err = None
    for attempt in range(retries + 1):
        t0 = time.time()
        try:
            raw = _generate(messages, max_tokens=max_tokens)
            obj = parse_json(raw, expect)
            labdb.log_call(con, day, purpose, session_id, prompt_chars,
                           raw, True, int((time.time() - t0) * 1000))
            return obj
        except Exception as e:                      # noqa: BLE001 实验线粗放兜
            last_err = e
            labdb.log_call(con, day, purpose, session_id, prompt_chars,
                           f"ERR {e}", False, int((time.time() - t0) * 1000))
            messages = messages + [{
                "role": "user",
                "content": "Output ONLY the JSON. No prose, no markdown fence.",
            }]
    raise RuntimeError(f"{purpose} failed after {retries+1} attempts: {last_err}")
