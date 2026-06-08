import rebuild as R, extract_compare_v2 as X
def records(ids):
    out=[]
    for ev in X.loadev(ids):
        app=ev['bundle'].split('.')[-1]
        for text,t0,t1,snd in R.event_sends_with_ts(ev,X):
            out.append((R.cv(text), snd, app))
    return out
res=[]
for tag,ids in [("类5a 长文 ev604-607",[604,605,606,607]),("类4 他骂你 ev1128-1129",[1128,1129])]:
    recs=records(ids)
    deduped=R.dedup_truncated(recs, X.cover)
    res.append(f"=== {tag} ===")
    res.append("  去重前:")
    for t,s,a in recs: res.append(f"    is_send={s} len={len(t)} {t[:34]!r}")
    res.append("  去重后:")
    for t,s,a in deduped: res.append(f"    is_send={s} len={len(t)} {t[:34]!r}")
open('/tmp/dbg_dedup.txt','w').write('\n'.join(res))
