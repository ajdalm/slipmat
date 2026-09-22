import re,html,sys
raw=open(sys.argv[1],'rb').read().decode('utf-8','replace').replace('\r\n','\n')
W=int(sys.argv[3]) if len(sys.argv)>3 else 132
raw=re.sub(r'\x1b\][^\x07]*\x07','',raw); raw=re.sub(r'\x1b\[8;\d+;\d+t','',raw); raw=re.sub(r'\x1b\[K','',raw)
lines=[(ln.split('\r')[-1] if '\r' in ln else ln) for ln in raw.split('\n')]
txt='\n'.join(l for l in lines if not re.search(r'\[download\]|encoding [░█]|ESTIMATE .*ELAPSED',l))
cols={'31':'#e5484d','32':'#46a758','33':'#e2b53e','36':'#3fb8d6','35':'#c46ad6','34':'#5b8def','90':'#888'}
state={'b':False,'d':False,'c':None}
def sp():
    st=[]
    if state['b']:st.append('font-weight:bold;color:#fff')
    if state['d']:st.append('opacity:.45')
    if state['c']:st.append('color:'+state['c'])
    return '<span style="%s">'%';'.join(st)
out=[sp()];pos=0
for m in re.finditer(r'\x1b\[([0-9;]*)m',txt):
    out.append(html.escape(txt[pos:m.start()]));pos=m.end()
    for code in (m.group(1) or '0').split(';'):
        if code in('','0'):state.update(b=False,d=False,c=None)
        elif code=='1':state['b']=True
        elif code=='2':state['d']=True
        elif code=='22':state.update(b=False,d=False)
        elif code=='39':state['c']=None
        elif code in cols:state['c']=cols[code]
    out.append('</span>'+sp())
out.append(html.escape(txt[pos:])+'</span>')
open(sys.argv[2],'w').write('<html><body style="margin:0;background:#1e1e1e"><pre style="font:12px/1.3 Menlo,monospace;color:#d8d8d8;width:%dch;background:#1e1e1e;padding:8px;white-space:pre-wrap;word-break:break-all;overflow:hidden;border-right:1px solid #444">%s</pre></body></html>'%(W,''.join(out)))
