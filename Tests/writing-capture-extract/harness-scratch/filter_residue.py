#!/usr/bin/env python3
"""后处理:读现有 新pipeline 文档,按确定性规则丢掉拼音/乱码残渣(A组#8),重新编号。
本地 1.7b Pass4 实测失效(MLX 啥都不丢),故残渣用规则清,不靠 LLM。"""
import re
ZW = {0x200B, 0x200C, 0x200D, 0xFEFF}
def cv(s): return ''.join(c for c in (s or '') if ord(c) not in ZW).strip()
def is_residue(t):
    c = cv(t)
    if not c: return True
    if re.fullmatch(r'[a-zA-Z0-9 ]{1,12}', c): return True                       # 纯拉丁/数字短串
    if re.search(r'[a-zA-Z ]{3,}$', c) and re.search(r'[一-鿿]', c) and len(c) <= 22: return True  # 末尾生拼音
    return False

P = "/Users/joyzhang14/Desktop/Obsidian/Pipeline成品-新pipeline.md"
txt = open(P).read()
head, *day_blocks = txt.split("\n## ")
out = [head.rstrip()]
dropped = 0
for db in day_blocks:
    day_line, rest = db.split("\n", 1)
    # 该天的标题行(### ...) + 记录
    parts = re.split(r'\n(?=\*\*\d+\.\*\* )', rest)
    header = parts[0]   # ### 🆕 ... 那行 + 可能的空行
    recs = []
    for blk in parts[1:]:
        # blk: **N.** `[src/kind]` 📍 `app`\n\n> text...
        mtag = re.search(r'\*\*\d+\.\*\* (`\[[^\]]+\]`) 📍 (`[^`]+`)', blk)
        if not mtag: continue
        # 引用块文本(去掉每行的 "> ")
        qlines = [ln[2:] if ln.startswith("> ") else (ln[1:] if ln.startswith(">") else ln)
                  for ln in blk.split("\n") if ln.startswith(">")]
        text = "\n".join(qlines).strip()
        # 结尾 --- 分隔符不算
        if is_residue(text):
            dropped += 1; continue
        recs.append((mtag.group(1), mtag.group(2), text))
    # 重新编号,改 header 里的计数
    hdr = re.sub(r'（\d+）', f'（{len(recs)}）', header).rstrip()
    out.append("## " + day_line)
    out.append("")
    out.append(hdr)
    out.append("")
    for i, (tag, app, text) in enumerate(recs, 1):
        body = text.replace("\n", "\n> ")
        out.append(f"**{i}.** {tag} 📍 {app}\n\n> {body}\n")
    out.append("\n---\n")
open(P, "w").write("\n".join(out))
print(f"已过滤残渣 {dropped} 条,重写: {P}")
