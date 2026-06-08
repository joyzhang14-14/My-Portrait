import json, sqlite3, os, re
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
CV=json.load(open('canvas_cloud.json'))
# 找 My Portrait 那篇(05-29 Safari,结尾 it can...)
body=None
for r in CV.get('2026-05-29',[]):
    if 'My Portrait' in r['text'] or r['text'].rstrip().endswith('it can...'):
        body=r['text']; break
print("body 结尾80:", repr(body[-80:]) if body else "没找到")

def ocr_tail_backstop(body, anchor_len=40):
    anchor=re.sub(r'\s+','',body)[-anchor_len:]   # body 末尾去空白当锚
    best_add=""
    rows=con.execute("SELECT full_text FROM frames WHERE full_text LIKE ?",('%'+body[-15:].strip().replace('.','')[:10]+'%',)).fetchall()
    # 用 'it can' 之后内容找(更稳)
    key='it can'
    for (ft,) in con.execute("SELECT full_text FROM frames WHERE full_text LIKE '%entrepreneurial%' OR full_text LIKE '%run properly%'").fetchall():
        i=ft.find(key)
        if i<0: continue
        after=ft[i+len(key):]
        if len(after)>len(best_add): best_add=after
    return best_add

add=ocr_tail_backstop(body)
print("\nOCR 帧里 'it can' 之后最长续文(前300):")
print(repr(add[:300]))
print(f"\n→ 补尾后 body 从 {len(body)} 字 → {len(body)+len(add)} 字")
