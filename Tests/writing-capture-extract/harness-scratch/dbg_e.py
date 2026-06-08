import sqlite3,os,rebuild as R,extract_compare_v2 as X
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
for ev in X.loadev([1123]):
    for text,t0,t1,snd in R.event_sends_with_ts(ev,X):
        ks=R.keys_in_window(con,ev['bundle'],t0,t1)
        segs=[''.join(s) for s in R.split_cr(ks) if any(c.isalnum() for c in s)]
        kseg=segs[-1] if segs else ''
        m=R.LATIN_TAIL.search(R.cv(text))
        resid=m.group().strip() if m else None
        print(f"发送={text!r}")
        print(f"  末段kseg={kseg!r}  残渣={resid!r}  picks={[(p,i) for p,i,c in R.parse_picks(list(kseg))]}")
        fixed,info=R.reconstruct_message(text,ks,model_fn=None)
        reason=info.get('lines',[{}])[0].get('reason') if 'lines' in info else info.get('reason')
        print(f"  → 重建={fixed!r}  reason={reason}")
