"""Constrained JSON decoding for mlx_lm via lmfe TokenEnforcer + a custom logits_processor.
This mirrors the RELEASE config: MLX engine + JSON-schema constraint (= mlx-swift-structured).
No torch — replicates lmfe's regular-tokens builder inline."""
import os, pickle, numpy as np, mlx.core as mx
from lmformatenforcer import JsonSchemaParser
from lmformatenforcer.tokenenforcer import TokenEnforcer, TokenEnforcerTokenizerData

def _regular_tokens(hf_tok, vocab_size):
    token_0 = hf_tok.encode("0")[-1]
    special = set(hf_tok.all_special_ids)
    out = []
    for tid in range(vocab_size):
        if tid in special: continue
        d0 = hf_tok.decode([token_0, tid])[1:]      # word-start space trick
        dr = hf_tok.decode([tid])
        out.append((tid, d0, len(d0) > len(dr)))
    return out

def tokenizer_data(tokenizer, cache_key):
    hf = tokenizer._tokenizer
    vs = len(hf)
    cpath = f"/tmp/rime-test/eval/.ted_{cache_key}.pkl"
    if os.path.exists(cpath):
        reg = pickle.load(open(cpath, "rb"))
    else:
        reg = _regular_tokens(hf, vs)
        pickle.dump(reg, open(cpath, "wb"))
    eos = hf.eos_token_id
    return TokenEnforcerTokenizerData(reg, hf.decode, eos, False, vs), vs

def json_processor(schema, ted, vocab_size):
    """Returns a fresh logits_processor enforcing `schema` (one per generation)."""
    te = TokenEnforcer(ted, JsonSchemaParser(schema))
    def proc(tokens, logits):
        gen = tokens.tolist()[1:]                   # drop the single leading prompt token
        allowed = te.get_allowed_tokens(gen).allowed_tokens
        V = logits.shape[-1]                         # model logit dim (may be padded > tokenizer vocab)
        mask = np.full((V,), -1e9, dtype=np.float32); mask[allowed] = 0.0
        return logits + mx.array(mask)
    return proc
