"""Regenerates lib/core/i18n/strings_*.dart from keys.json + tr_<lang>.tsv.

Run from anywhere:  python3 tool/i18n/gen.py
"""
import json,re,sys,os
HERE=os.path.dirname(os.path.abspath(__file__))
keys=json.load(open(HERE+'/keys.json'))
def dart_str(s):
    s=s.replace('\\','\\\\').replace("'","\\'").replace('$','\\$').replace('\n','\\n')
    return "'"+s+"'"
def build(lang, var, fname):
    rows={}
    for ln,line in enumerate(open(HERE+'/tr_%s.tsv'%lang,encoding='utf8'),1):
        line=line.rstrip('\n')
        if not line.strip(): continue
        i,t=line.split('\t',1)
        i=int(i); t=t.replace('\\n','\n')
        k=keys[i]
        pk=set(re.findall(r'\{\d+\}',k)); pt=set(re.findall(r'\{\d+\}',t))
        if not pt<=pk: print('PLACEHOLDER MISMATCH',lang,i,k,'->',t)
        if not t.strip(): print('EMPTY',lang,i)
        if i in rows: print('DUP',lang,i)
        rows[i]=t
    out=["// GENERATED from the English strings in the app; one entry per string.",
         "// Key = the English text exactly as it appears in the code; {0}, {1} = live values.",
         "const Map<String, String> %s = {"%var]
    for i in sorted(rows):
        out.append("  %s: %s,"%(dart_str(keys[i]),dart_str(rows[i])))
    out.append("};\n")
    open(HERE+'/../../lib/core/i18n/'+fname,'w',encoding='utf8').write('\n'.join(out))
    print(lang,len(rows),'of',len(keys))
if __name__=='__main__':
    for lang,var,fname in [('hi','hiStrings','strings_hi.dart'),('bn','bnStrings','strings_bn.dart'),('ne','neStrings','strings_ne.dart'),('ur','urStrings','strings_ur.dart'),('ar','arStrings','strings_ar.dart'),('fil','filStrings','strings_fil.dart'),('pt_BR','ptBrStrings','strings_pt_br.dart')]:
        try: build(lang,var,fname)
        except FileNotFoundError: pass
