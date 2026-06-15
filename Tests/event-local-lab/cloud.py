"""hybrid 的云端调用层 —— 动态读用户 Connections 配的 provider,不写死。

provider/model 从 ~/.portrait/config.toml [memory] 段读(和生产 memory
pipeline 同源):每个用户配的不一样,这里照读。本机当前 = chatgpt / gpt-5.4。

两条 wire,按 provider 派发:
  · chatgpt(Codex/ChatGPT OAuth):走 app 同款 Pi agent 一次性模式
    (bun pi-cli -p --provider openai-codex),OAuth 在 ~/.pi/agent/auth.json
    (app 写、Pi 自动刷 token)。和生产 EventBuilder 完全同源,最忠实。
  · deepseek/openai/perplexity/ollama:OpenAI 兼容 HTTP /chat/completions,
    key 本地从 SecretStore 解密(master.key + secrets.sqlite,AES-256-GCM)
    或环境变量覆盖。

anthropic/gemini 不在这两条里,lab 暂不支持,直接报错说清,不假装。
"""
import json
import os
import shutil
import sqlite3
import subprocess
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

PORTRAIT = Path.home() / ".portrait"
CONFIG = PORTRAIT / "config.toml"
PI_AUTH = Path.home() / ".pi" / "agent" / "auth.json"
PI_CLI = PORTRAIT / "pi-agent/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"

# OpenAI 兼容 provider → (base_url, 环境变量名)。None = 无需 key(本地 ollama)。
_OPENAI_COMPAT = {
    "deepseek":   ("https://api.deepseek.com",   "DEEPSEEK_API_KEY"),
    "openai":     ("https://api.openai.com/v1",  "OPENAI_API_KEY"),
    "perplexity": ("https://api.perplexity.ai",  "PERPLEXITY_API_KEY"),
    "ollama":     ("http://localhost:11434/v1",  None),
}


def load_config():
    """读 [memory] provider_id / model / model_light。缺省退回生产默认。"""
    try:
        with open(CONFIG, "rb") as f:
            mem = tomllib.load(f).get("memory", {})
    except FileNotFoundError:
        mem = {}
    return {
        "provider": mem.get("provider_id", "chatgpt"),
        "model": mem.get("model", "gpt-5.4"),
        "model_light": mem.get("model_light", "gpt-5.4-mini"),
    }


def _decrypt_secret(secret_key):
    """从本地 SecretStore 解密一条 secret(和生产 SecretStore 同逻辑)。
    master.key 32 字节 + secrets.sqlite(nonce ‖ ciphertext‖tag,AES-256-GCM)。"""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    mk = (PORTRAIT / "master.key").read_bytes()
    con = sqlite3.connect(f"file:{PORTRAIT / 'secrets.sqlite'}?mode=ro", uri=True)
    row = con.execute("SELECT nonce, ciphertext FROM secrets WHERE key=?",
                      (secret_key,)).fetchone()
    con.close()
    if not row:
        return None
    return AESGCM(mk).decrypt(row[0], row[1], None).decode()


# ---------------- chatgpt:Pi agent 一次性 ----------------

def _pi_oneshot(messages, model, timeout):
    """app 同款 Pi agent,非交互一次性。OAuth 走 ~/.pi/agent/auth.json。
    返回 (assistant 文本, 延迟ms)。"""
    if not PI_AUTH.exists():
        raise RuntimeError("缺 ~/.pi/agent/auth.json(Codex OAuth)。先在 app 里跑一次 "
                           "memory pipeline 让它写出来,或重新登录 ChatGPT。")
    if not PI_CLI.exists():
        raise RuntimeError(f"缺 pi-cli:{PI_CLI}")
    bun = shutil.which("bun") or str(Path.home() / ".bun/bin/bun")
    sys_msg = next((m["content"] for m in messages if m["role"] == "system"), "")
    user_msg = "\n\n".join(m["content"] for m in messages if m["role"] != "system")
    args = [bun, str(PI_CLI), "-p", "--mode", "text", "--no-tools", "--no-session",
            "--no-extensions", "--no-skills", "--provider", "openai-codex",
            "--model", model, "--system-prompt", sys_msg]
    t0 = time.time()
    cp = subprocess.run(args, input=user_msg, capture_output=True, text=True,
                        timeout=timeout)
    lat = int((time.time() - t0) * 1000)
    if cp.returncode != 0:
        raise RuntimeError(f"pi exit {cp.returncode}: {(cp.stderr or cp.stdout)[:300]}")
    return cp.stdout, lat


# ---------------- key 类:OpenAI 兼容 HTTP ----------------

def _resolve(provider):
    if provider not in _OPENAI_COMPAT:
        raise RuntimeError(
            f"lab 云端层暂不支持 provider '{provider}'(只有 chatgpt 走 Pi、"
            f"{list(_OPENAI_COMPAT)} 走 HTTP)。")
    base, env = _OPENAI_COMPAT[provider]
    if not env:                                    # ollama 无需 key
        return base, None
    key = os.environ.get(env) or _decrypt_secret(f"apikey:{provider}")
    if not key:
        raise RuntimeError(f"取不到 {provider} 的 key(env {env} 未设、SecretStore "
                           f"无 apikey:{provider})。")
    return base, key


def _http_chat(provider, base, key, messages, model, max_tokens, temperature, timeout):
    body = json.dumps({"model": model, "messages": messages,
                       "max_tokens": max_tokens, "temperature": temperature,
                       "stream": False}).encode()
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(f"{base}/chat/completions", data=body,
                                 headers=headers, method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            obj = json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{provider} HTTP {e.code}: "
                           f"{e.read().decode(errors='replace')[:300]}") from e
    return obj["choices"][0]["message"]["content"], int((time.time() - t0) * 1000)


def cloud_call(messages, *, model=None, max_tokens=4096, temperature=0.2,
               timeout=240):
    """一次云端调用。返回 (文本, 延迟ms)。provider/model 默认走 config,按 provider 派发。"""
    cfg = load_config()
    provider = cfg["provider"]
    model = model or cfg["model"]
    if provider == "chatgpt":
        return _pi_oneshot(messages, model, timeout)
    base, key = _resolve(provider)
    return _http_chat(provider, base, key, messages, model, max_tokens,
                      temperature, timeout)


if __name__ == "__main__":   # 探活:打印 config + transport(不发请求)
    c = load_config()
    print(f"provider={c['provider']} model={c['model']} light={c['model_light']}")
    if c["provider"] == "chatgpt":
        print(f"transport=Pi oneshot · auth={'OK' if PI_AUTH.exists() else '缺失'}"
              f" · pi-cli={'OK' if PI_CLI.exists() else '缺失'}")
    else:
        try:
            base, key = _resolve(c["provider"])
            print(f"transport=HTTP {base} · key={'OK' if key else '(none)'}")
        except RuntimeError as e:
            print(f"⚠ {e}")
