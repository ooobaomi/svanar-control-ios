"""Validate Windows PE and package the complete standalone runtime."""
import argparse, hashlib, json, struct, zipfile
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--dist', required=True)
p.add_argument('--out', required=True)
a=p.parse_args()
root=Path(a.dist).resolve();out=Path(a.out).resolve();out.mkdir(parents=True,exist_ok=True)
exe=root/'SvanarControl.exe';b=exe.read_bytes()
assert b[:2]==b'MZ'
o=struct.unpack_from('<I',b,0x3c)[0]
assert b[o:o+4]==b'PE\0\0' and struct.unpack_from('<H',b,o+4)[0]==0x8664
assert struct.unpack_from('<H',b,o+24+68)[0]==2, 'Expected Windows GUI subsystem'
assert (root/'_internal').is_dir()
assert (root/'README.md').is_file() and (root/'EQ-file-example.json').is_file()
name='SvanarControl-Windows-v1.3-x64.zip';target=out/name
files=sorted(x for x in root.rglob('*') if x.is_file())
with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for f in files:z.write(f,'SvanarControl/'+f.relative_to(root).as_posix())
with zipfile.ZipFile(target) as z:assert z.testzip() is None
sha=hashlib.sha256(target.read_bytes()).hexdigest()
(out/'SHA256SUMS.txt').write_text(sha+'  '+name+'\n',encoding='utf-8')
print(json.dumps({'zip':str(target),'bytes':target.stat().st_size,'files':len(files),'sha256':sha,'pe':'AMD64 GUI'},ensure_ascii=False))
