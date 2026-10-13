import re,html,sys
raw=open(sys.argv[1],'rb').read().decode('utf-8','replace').replace('\r\n','\n')
W=int(sys.argv[3]) if len(sys.argv)>3 else 132
raw=re.sub(r'\x1b\][^\x07]*\x07','',raw); raw=re.sub(r'\x1b\[8;\d+;\d+t','',raw); raw=re.sub(r'\x1b\[K','',raw)
lines=[(ln.split('\r')[-1] if '\r' in ln else ln) for ln in raw.split('\n')]
txt='\n'.join(l for l in lines if not re.search(r'\[download\]|encoding [░█]|ESTIMATE .*ELAPSED',l))
cols={'31':'#e5484d','32':'#46a758','33':'#e2b53e','36':'#3fb8d6','35':'#c46ad6','34':'#5b8def','90':'#888'}
def x256(n):  # xterm 256-color index → hex (cube + grays; 0-15 fall back to cols)
    n=int(n)
    if n<16: return {4:'#5b8def',5:'#c46ad6',2:'#46a758',1:'#e5484d',3:'#e2b53e',6:'#3fb8d6'}.get(n%8,'#d8d8d8')
    if n>=232: v=8+(n-232)*10; return '#%02x%02x%02x'%(v,v,v)
    n-=16; lv=[0,95,135,175,215,255]; return '#%02x%02x%02x'%(lv[n//36],lv[n//6%6],lv[n%6])
state={'b':False,'d':False,'c':None,'r':False}
def sp():
    st=[]; c=state['c'] or ('#fff' if state['b'] else None)
    if state['b']:st.append('font-weight:bold')
    if state['d']:st.append('opacity:.45')
    if state['r']:st.append('background:%s;color:#1e1e1e'%(c or '#d8d8d8'))
    elif c:st.append('color:'+c)
    return '<span style="%s">'%';'.join(st)
txt=txt.replace('\x1b[2J\x1b[H','\n\u2500\u2500\u2500\u2500 [screen clears] \u2500\u2500\u2500\u2500\n')
out=[sp()];pos=0
for m in re.finditer(r'\x1b\[([0-9;]*)m',txt):
    out.append(html.escape(txt[pos:m.start()]));pos=m.end()
    codes=(m.group(1) or '0').split(';'); k=0
    while k<len(codes):
        code=codes[k]
        if code in('','0'):state.update(b=False,d=False,c=None,r=False)
        elif code=='1':state['b']=True
        elif code=='2':state['d']=True
        elif code=='7':state['r']=True
        elif code=='22':state.update(b=False,d=False)
        elif code=='27':state['r']=False
        elif code=='39':state['c']=None
        elif code=='38' and k+2<len(codes) and codes[k+1]=='5':state['c']=x256(codes[k+2]);k+=2
        elif code in cols:state['c']=cols[code]
        k+=1
    out.append('</span>'+sp())
out.append(html.escape(txt[pos:])+'</span>')
open(sys.argv[2],'w').write('<html><head><meta charset="utf-8"></head><body style="margin:0;background:#1e1e1e"><pre style="font:12px/1.3 Menlo,monospace;color:#d8d8d8;width:%dch;background:#1e1e1e;padding:8px;white-space:pre-wrap;word-break:break-all;overflow:hidden;border-right:1px solid #444">%s</pre></body></html>'%(W,''.join(out)))
