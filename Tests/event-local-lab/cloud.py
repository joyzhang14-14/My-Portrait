"""hybrid 的云端调用层 —— 动态读用户 Connections 配的 provider,不写死。

provider/model 从 ~/.portrait/config.toml [memory] 段读(和生产 memory
pipeline 同源):每个用户配的不一样,这里照读。

key 取不到的真相:secrets.sqlite 的主密钥在 app 专属 keychain(data-protection
keychain),`security` CLI 都读不到,Python 更无法解密。所以 key 走环境变量 ——
跑之前 export 一次。这是 lab 的取舍,不是生产形态(生产在 Swift 里用 SecretStore)。

只实现 OpenAI 兼容 wire(deepseek/openai/perplexity/ollama 都是这条),
覆盖本机启用的 deepseek。anthropic/gemini/chatgpt(OAuth) 不是这条 wire,
lab 里直接报错说清,不假装支持。
"""
import json
import os
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

CONFIG = Path.home() / ".portrait" / "config.toml"

# provider_id → (base_url, api_key 环境变量名)。None = 无需 key(本地 ollama)。
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


def _resolve(provider):
    if provider not in _OPENAI_COMPAT:
        raise RuntimeError(
            f"lab 云端层只支持 OpenAI 兼容 provider {list(_OPENAI_COMPAT)};"
            f"你配的是 '{provider}'。要测它得在 cloud.py 加对应 wire。")
    base, env = _OPENAI_COMPAT[provider]
    key = os.environ.get(env) if env else None
    if env and not key:
        raise RuntimeError(
            f"缺 {env}。{provider} 的 key 在加密 secret store 里(app 专属 "
            f"keychain,无法自动解密)。跑前 export {env}=<你的 key>。")
    return base, key


def cloud_call(messages, *, model=None, max_tokens=4096, temperature=0.2,
               timeout=180):
    """一次云端调用。返回 (文本, 延迟ms)。provider/model 默认走 config。"""
    cfg = load_config()
    provider = cfg["provider"]
    model = model or cfg["model"]
    base, key = _resolve(provider)

    body = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }).encode()
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
        detail = e.read().decode(errors="replace")[:300]
        raise RuntimeError(f"{provider} HTTP {e.code}: {detail}") from e
    lat = int((time.time() - t0) * 1000)
    txt = obj["choices"][0]["message"]["content"]
    return txt, lat


if __name__ == "__main__":   # 烟雾测试:打印当前 config + 不发请求探活
    c = load_config()
    print(f"provider={c['provider']} model={c['model']} light={c['model_light']}")
    try:
        base, key = _resolve(c["provider"])
        print(f"base={base} key={'set' if key else '(none/unset)'}")
    except RuntimeError as e:
        print(f"⚠ {e}")
