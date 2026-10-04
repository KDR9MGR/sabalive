import re, os, json, sys
HERE=os.path.dirname(os.path.abspath(__file__))
ROOT=os.path.join(HERE,'..','..')

def lex_strings(src):
    """Yield (start, end, template, has_interp) for each Dart string literal (not in comments)."""
    i=0; n=len(src); out=[]
    def skip_comment(i):
        if src.startswith('//',i):
            j=src.find('\n',i); return n if j<0 else j
        if src.startswith('/*',i):
            j=src.find('*/',i+2); return n if j<0 else j+2
        return None
    def read_string(i):
        # i at opening quote or r-prefix
        raw=False; start=i
        if src[i]=='r' and i+1<n and src[i+1] in '\'"': raw=True; i+=1
        q=src[i]
        triple = src.startswith(q*3,i)
        qlen=3 if triple else 1
        i+=qlen
        buf=[]; k=0; interp=False
        while i<n:
            if src.startswith(q*qlen,i): i+=qlen; return start,i,''.join(buf),interp
            c=src[i]
            if not raw and c=='\\':
                e=src[i+1]
                buf.append({'n':'\n','t':'\t','\\':'\\',"'":"'",'"':'"','$':'$'}.get(e,'\\'+e)); i+=2; continue
            if not raw and c=='$':
                if src[i+1]=='{':
                    # nested expression; find matching }
                    depth=1; j=i+2
                    while j<n and depth:
                        cj=src[j]
                        if cj in '\'"':
                            _,j,_,_=read_string(j); continue
                        if cj=='{': depth+=1
                        elif cj=='}': depth-=1
                        j+=1
                    buf.append('{%d}'%k); k+=1; interp=True; i=j; continue
                m=re.match(r'\$([A-Za-z_]\w*)',src[i:])
                if m:
                    buf.append('{%d}'%k); k+=1; interp=True; i+=m.end(); continue
            buf.append(c); i+=1
        return start,i,''.join(buf),interp
    while i<n:
        c=src[i]
        if c=='/' and i+1<n and src[i+1] in '/*':
            i=skip_comment(i); continue
        if c in '\'"' or (c=='r' and i+1<n and src[i+1] in '\'"' and (i==0 or not (src[i-1].isalnum() or src[i-1]=='_'))):
            s,e,t,ip=read_string(i); out.append((s,e,t,ip)); i=e; continue
        i+=1
    return out

def merged(src):
    toks=lex_strings(src)
    res=[]; 
    for t in toks:
        if res and src[res[-1][1]:t[0]].strip()=='' :
            ps,pe,pt,pi=res[-1]
            # renumber placeholders of t after those in prev
            base=len(re.findall(r'\{\d+\}',pt))
            tt=re.sub(r'\{(\d+)\}',lambda m:'{%d}'%(int(m.group(1))+base),t[2])
            res[-1]=(ps,t[1],pt+tt,pi or t[3])
        else:
            res.append(t)
    return res


SKIP_FILES = {'mock_data.dart', 'supabase_config.dart', 'google_config.dart', 'agora_config.dart'}

def looks_like_ui_text(t):
    core = re.sub(r'\{\d+\}', '', t)
    if len(t.strip()) < 2 or not re.search(r'[A-Za-z]{2}', core): return False
    if re.match(r'^(https?:|package:|assets/|dart:|\w+://|sb_)', t.strip()): return False
    if re.search(r'\.(png|jpg|jpeg|svg|svga|mp4|json|dart|ttf|webp|gif)\b', t): return False
    if re.fullmatch(r'[a-z0-9_.:/\-]+', t.strip()): return False
    if re.fullmatch(r'[a-z]+([A-Z][a-z0-9]*)+', t.strip()): return False
    if re.fullmatch(r'[A-Z0-9_]+', t.strip()): return False
    if '_fkey' in t or re.search(r'^\*|\(\*\)|!inner|profiles!|,\s*\w+_\w+', t): return False
    if re.search(r'[a-z]+_[a-z]+', t) and ' ' not in t.strip(): return False
    # a database / log line rather than something a person reads
    if re.search(r'\bfailed\b|\.ilike\.|:\{0\}$|^[a-z-]+-\{0\}$', t): return False
    return True

if __name__ == '__main__':
    known = set(json.load(open(os.path.join(HERE, 'keys.json'), encoding='utf8')))
    found = {}
    for dp, dn, fn in os.walk(os.path.join(ROOT, 'lib')):
        if os.path.join('core', 'i18n') in dp: continue
        for f in fn:
            if not f.endswith('.dart') or f in SKIP_FILES: continue
            p = os.path.join(dp, f)
            src = open(p, encoding='utf8').read()
            for s, e, t, ip in merged(src):
                line = src[src.rfind('\n', 0, s) + 1:s].strip()
                if re.match(r'^(import|export|part)\b', line): continue
                if t not in known and looks_like_ui_text(t):
                    found.setdefault(t, os.path.relpath(p, ROOT))
    for t, p in sorted(found.items(), key=lambda x: x[0].lower()):
        print('%s\t%s' % (p, t.replace('\n', '\\n')))
    print('\n%d candidate strings without a translation (many are code, not UI text)' % len(found), file=sys.stderr)
