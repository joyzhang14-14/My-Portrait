"""事件合并共用的三样：向量（EmbeddingGemma 2，本机 MLX）、模型调用（OpenAI 兼容接口或本机 mlx-lm）、坏 JSON 修复器。

模型调用逐条缓存在 <out>/llm_cache/（按题面哈希），中断后重跑从缓存回放、接着往下。
模型输出先过修复器（裸引号 / 截断补齐 / 漏引号），再查字段合不合格，不合格才重试。

接口模型：环境变量 EVENT_MERGE_LLM_URL（如 http://127.0.0.1:8000/v1）、EVENT_MERGE_LLM_KEY（可空）、
EVENT_MERGE_LLM_MODEL（可空，空就用 /models 返回的第一个）。本机模型：mlx-lm 加载 MAC_REPO（4-bit），关思考。
"""
import copy, hashlib, json, os, re, threading, time, urllib.error, urllib.request
from collections import OrderedDict, deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from mlx_vlm.embedding_loader import load_embedding_model
from transformers import AutoTokenizer

EMBED_REPO = "mlx-community/embeddinggemma-2-bf16"
MAC_REPO = "mlx-community/Qwen3.5-9B-MLX-4bit"
TIMEOUT_S = 300
MAX_TOKENS = 1200          # 正常一次输出几十到几百 token
BAD_OUTPUT_LIMIT = 5       # 连续坏输出这么多次：这道题记 error，接着往下
SNAP_MAX = 16              # 本机模型存的题面前缀快照个数（一个约 100MB）
SNAP_MIN = 256             # 和最近题面的公共前缀至少这么多 token 才存快照


def obj_schema(props, enum=None):
    """全是字符串字段的 JSON schema；enum 给 decision 字段限定取值。"""
    p = {k: {"type": "string"} for k in props}
    if enum:
        p["decision"] = {"type": "string", "enum": enum}
    return {"type": "object", "properties": p, "required": list(p), "additionalProperties": False}


def need(*fields):
    """校验：这些字段非空。"""
    def valid(r):
        for f in fields:
            if not str(r.get(f) or "").strip():
                return f"{f} 为空"
        return ""
    return valid


class Embedder:
    # MLX 的 GPU stream 绑在建它的线程上：加载和推理都放进同一个专用线程
    def __init__(self):
        self.pool = ThreadPoolExecutor(1)
        self.pool.submit(self._load).result()

    def _load(self):
        path = Path(snapshot_download(EMBED_REPO))
        self.model = load_embedding_model(path)
        self.tok = AutoTokenizer.from_pretrained(path)

    def _embed(self, text: str) -> np.ndarray:
        ids = self.tok(text, truncation=True, max_length=8192)["input_ids"]
        out = self.model(mx.array([ids]), attention_mask=mx.ones((1, len(ids)), dtype=mx.int32))
        mx.eval(out.text_embeds)
        vec = np.array(out.text_embeds[0].astype(mx.float32))
        # 每段文字长度不同，MLX 按形状留的缓存只增不减（实测 60 次就 15.9GB）：算完即清
        mx.clear_cache()
        return vec

    def __call__(self, text: str) -> np.ndarray:
        return self.pool.submit(self._embed, text).result()

    def query(self, text):
        return self("task: search result | query: " + text)

    def doc(self, title, narrative):
        return self(f"title: {title} | text: {narrative}")


class _Base:
    def __init__(self, out: Path):
        self.cache = out / "llm_cache"
        self.bad_dir = out / "bad"
        self.cache.mkdir(parents=True, exist_ok=True)

    def _bad(self, tag, n, why, text):
        self.bad_dir.mkdir(parents=True, exist_ok=True)
        (self.bad_dir / f"{tag}-{n}.txt").write_text(f"{why}\n\n{text}")
        print(f"  {tag} 输出坏了第 {n} 次：{why}", flush=True)

    @staticmethod
    def _save(cpath, rec):
        tmp = cpath.with_suffix(".tmp")
        tmp.write_text(json.dumps(rec, ensure_ascii=False))
        tmp.rename(cpath)


class LLM(_Base):
    """OpenAI 兼容接口（vLLM 等），json_schema 强制输出结构，关思考。"""
    def __init__(self, out: Path):
        super().__init__(out)
        base = os.environ["EVENT_MERGE_LLM_URL"].rstrip("/")
        self.url, self.key = base + "/chat/completions", os.environ.get("EVENT_MERGE_LLM_KEY", "")
        self.model = os.environ.get("EVENT_MERGE_LLM_MODEL") or json.loads(self._req(base + "/models", None))["data"][0]["id"]

    def _req(self, url, body):
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            return r.read().decode()

    def __call__(self, prompt: str, schema: dict, valid, tag: str, max_tokens=MAX_TOKENS) -> dict | None:
        """valid(parsed) -> 不合格的原因（合格回 ""）。连续坏 BAD_OUTPUT_LIMIT 次回 None。"""
        cpath = self.cache / (hashlib.sha256(prompt.encode()).hexdigest()[:32] + ".json")
        if cpath.exists():
            return json.loads(cpath.read_text())["parsed"]
        body = {"model": self.model, "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.2, "max_tokens": max_tokens,
                "response_format": {"type": "json_schema", "json_schema": {"name": "out", "schema": schema}},
                "chat_template_kwargs": {"enable_thinking": False}}
        bad = 0
        for _ in range(60):
            try:
                resp = json.loads(self._req(self.url, body))
                text = resp["choices"][0]["message"]["content"]
                parsed = parse_lenient(text)
                why = "修不回来的 JSON" if parsed is None else valid(parsed)
                if why:
                    bad += 1
                    self._bad(tag, bad, why, text)
                    if bad >= BAD_OUTPUT_LIMIT:
                        return None
                    # 结构化输出偶尔在 JSON 空白里打转到 max_tokens：升温 + 重复惩罚把它推出去
                    body["temperature"] = 0.2 + 0.25 * bad
                    body["frequency_penalty"] = 0.3 * bad
                    continue
                self._save(cpath, {"prompt": prompt, "text": text, "parsed": parsed})
                return parsed
            except urllib.error.HTTPError as e:
                # 503 = 服务在排队 / 切模型，按 Retry-After 等
                wait = int(e.headers.get("Retry-After") or 30) if e.code == 503 else 10
                print(f"  HTTP {e.code}，{wait}s 后重试", flush=True)
                time.sleep(wait)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, KeyError) as e:
                print(f"  调用失败（{type(e).__name__}），10s 后重试", flush=True)
                time.sleep(10)
        raise RuntimeError("模型调用连续失败")


class MacLLM(_Base):
    """本机 mlx-lm 跑 Qwen3.5-9B（4-bit），关思考。没有 json_schema 强制：prompt 末尾补一句「只输出这些字段的 JSON」。
    一个模型实例，调用加锁串行；缓存 key 带 mac9b 前缀，不和接口模型混。
    前缀复用：和最近几次题面的公共前缀（同一天的固定题面 + 同一会话）算一次存成快照，之后同前缀的调用从快照接着算
    （Qwen3.5 有线性注意力层，缓存不能截短，只能按前缀存快照）。"""
    def __init__(self, out: Path):
        super().__init__(out)
        from mlx_lm import load
        self.model, self.tok = load(snapshot_download(MAC_REPO))
        self.lock = threading.Lock()
        self.snaps, self.recent = OrderedDict(), deque(maxlen=8)

    def _prefill(self, toks):
        """返回 (KV 缓存, 还要喂的 token)。"""
        from mlx_lm.models.cache import make_prompt_cache
        best = max((k for k in self.snaps if len(k) < len(toks) and tuple(toks[:len(k)]) == k), key=len, default=())
        if best:
            cache = copy.deepcopy(self.snaps[best])
            self.snaps.move_to_end(best)
        else:
            cache = make_prompt_cache(self.model)
        pos = len(best)
        lcp = 0
        for r in self.recent:
            n = 0
            while n < min(len(r), len(toks)) and r[n] == toks[n]:
                n += 1
            lcp = max(lcp, n)
        lcp = min(lcp, len(toks) - 1)
        self.recent.append(toks)
        if lcp - pos >= SNAP_MIN:
            for i in range(pos, lcp, 2048):
                self.model(mx.array([toks[i:min(i + 2048, lcp)]]), cache=cache)
                mx.eval([c.state for c in cache])
            self.snaps[tuple(toks[:lcp])] = copy.deepcopy(cache)
            if len(self.snaps) > SNAP_MAX:
                self.snaps.popitem(last=False)
            pos = lcp
        return cache, toks[pos:]

    @staticmethod
    def _json_note(schema):
        parts = []
        for k, v in schema["properties"].items():
            if v.get("enum"):
                parts.append(f'"{k}" (one of {", ".join(v["enum"])})')
            elif v.get("type") == "array":
                inner = v["items"]
                if inner.get("type") == "object":
                    parts.append(f'"{k}" (a list of objects with keys {", ".join(inner["properties"])})')
                else:
                    parts.append(f'"{k}" (a list of strings)')
            else:
                parts.append(f'"{k}"')
        return "\n\nReply with only one JSON object with exactly these keys: " + ", ".join(parts) + ". No other text."

    def __call__(self, prompt: str, schema: dict, valid, tag: str, max_tokens=MAX_TOKENS) -> dict | None:
        from mlx_lm import generate
        from mlx_lm.sample_utils import make_sampler
        cpath = self.cache / (hashlib.sha256(("mac9b|" + prompt).encode()).hexdigest()[:32] + ".json")
        if cpath.exists():
            return json.loads(cpath.read_text())["parsed"]
        msgs = [{"role": "user", "content": prompt + self._json_note(schema)}]
        toks = self.tok.encode(self.tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False))
        for bad in range(BAD_OUTPUT_LIMIT):
            with self.lock:
                cache, rest = self._prefill(toks)
                text = generate(self.model, self.tok, prompt=rest, max_tokens=max_tokens, prompt_cache=cache,
                                sampler=make_sampler(temp=0.2 + 0.25 * bad))
                mx.clear_cache()
            parsed = parse_lenient(text[text.find("{"):] if "{" in text else text)
            parsed = parsed if parsed is None else fix_keys(parsed, schema)
            why = "修不回来的 JSON" if parsed is None else valid(parsed)
            if not why:
                self._save(cpath, {"prompt": prompt, "text": text, "parsed": parsed})
                return parsed
            self._bad(tag, bad + 1, why, text)
        return None


def make_llm(kind: str, out: Path):
    return MacLLM(out) if kind == "mac" else LLM(out)


def _repair_quotes(txt):
    """字符串里的裸英文双引号把 JSON 撑破：遇到 `"` 若后面不是结构字符（, } ] : 或行尾）就当裸引号，成对换成「」。"""
    out, i, instr, opened, n = [], 0, False, False, len(txt)
    while i < n:
        c = txt[i]
        if not instr:
            if c == '"':
                instr, opened = True, False
            out.append(c); i += 1; continue
        if c == '\\':
            out.append(txt[i:i + 2]); i += 2; continue
        if c == '"':
            j = i + 1
            while j < n and txt[j] in ' \t':
                j += 1
            if j >= n or txt[j] in ',}]:\n\r':
                instr = False; out.append(c)
            else:
                out.append('」' if opened else '「'); opened = not opened
            i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def _close_truncated(txt):
    """在空白里打转、被 max_tokens 截断：压掉字符串外的空白，补齐没闭合的引号和括号。"""
    out, instr, esc, stack = [], False, False, []
    for c in txt:
        if instr:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                instr = False
            continue
        if c.isspace():
            continue
        out.append(c)
        if c == '"':
            instr = True
        elif c in "{[":
            stack.append("}" if c == "{" else "]")
        elif c in "}]" and stack:
            stack.pop()
    s = "".join(out)
    if instr:
        s += '"'
    s = s.rstrip(",:")
    return s + "".join(reversed(stack))


_BARE = re.compile(r'^(\s*"[A-Za-z_]+"\s*:\s*)(?!["\[{\-\d]|true\b|false\b|null\b)(\S.*?)(,?)\s*$', re.M)


def _quote_bare_values(txt):
    """没有 schema 强制时（本机模型）字符串值偶尔漏掉开头的引号（"narrative": 用户…）：把这一行剩下的内容当字符串值重新编码。"""
    return _BARE.sub(lambda m: m[1] + json.dumps(m[2].rstrip('"'), ensure_ascii=False) + m[3], txt)


def parse_lenient(text: str) -> dict | None:
    """修复器：原样 → 裸引号换「」→ 截断补齐（两样都做）；都不行再先补漏掉的开头引号重来一遍。都不行回 None。"""
    for pre in (lambda t: t, _quote_bare_values):
        for fix in (lambda t: t, _repair_quotes, _close_truncated, lambda t: _close_truncated(_repair_quotes(t))):
            try:
                d = json.loads(fix(pre(text)))
                if isinstance(d, dict):
                    return d
            except (json.JSONDecodeError, ValueError):
                pass
    return None


def fix_keys(d: dict, schema: dict) -> dict:
    """字段名拼错（narrative 写成 narrature）：缺的字段和多出来的陌生字段一一对得上（前 3 个字母相同）就改回来。"""
    want = [k for k in schema["properties"] if k not in d]
    extra = [k for k in d if k not in schema["properties"]]
    for k in want:
        hit = [x for x in extra if x[:3] == k[:3]]
        if len(hit) == 1:
            d[k] = d.pop(hit[0]); extra.remove(hit[0])
    return d
