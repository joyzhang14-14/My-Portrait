import sqlite3, os
import rebuild as R, extract_compare_v2 as X
con=sqlite3.connect(os.path.expanduser('~/.portrait/portrait.sqlite'))
FIX=[('A',[523],'我今天早上5点睡的'),('B',[596],'啥|没看懂'),('E',[1123],'卖个惨|你发烧'),
     ('F',[1128,1129],'逆天'),('H',[1131],'就是你有什么问题就问特定的人'),('I',[1132],'大多数人都很喜欢Google的生态'),
     ('J',[1132],'gmail'),('M',[1153],'越高越好'),('K',[1143,1144],'特点')]
out=[]
for tag,ids,want in FIX:
    evs=X.loadev(ids); rebuilt=[]
    for ev in evs:
        for text,t0,t1,snd in R.event_sends_with_ts(ev, X):
            ks=R.keys_in_window(con, ev['bundle'], t0, t1)
            fixed,info=R.reconstruct_message(text, ks, model_fn=None)
            rebuilt.append(fixed)
    hit='OK' if all(w in '|'.join(rebuilt) for w in want.split('|') if w) else 'XX'
    out.append(f"[{tag}] {hit} want[{want}]")
    out.append(f"     {rebuilt}")
open('/tmp/det_result.txt','w').write('\n'.join(out))
