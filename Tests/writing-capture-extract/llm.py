"""Ollama call helper — native /api/chat with explicit num_ctx (critical: default is tiny)."""
import json, re, time, urllib.request

def call(model, text, num_ctx=16384, temperature=0.2, timeout=1200, fmt=None):
    body = {"model": model, "messages": [{"role": "user", "content": text}],
            "stream": False, "options": {"num_ctx": num_ctx, "temperature": temperature}}
    if model.startswith("qwen3"):
        body["think"] = False  # disable hybrid reasoning -> clean JSON + faster
    if fmt:
        body["format"] = fmt   # "json" forces valid-JSON output (no rambling)
    req = urllib.request.Request("http://localhost:11434/api/chat",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=timeout))
    out = r["message"]["content"]
    out = re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()
    return out, time.time() - t
