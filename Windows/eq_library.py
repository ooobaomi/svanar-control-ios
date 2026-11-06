"""Bounded cross-platform SVANAR EQ data. No device or GUI operations."""
import copy
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata
import uuid

FREQUENCIES = [31,62,125,250,500,1000,2000,4000,8000,16000]
MAX_BYTES = 65536
MAX_PROFILES = 64
PRESETS = [('平直', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), ('低频增强', [3, 3, 2, 1, 0, 0, 0, 0, 0, 0]), ('人声清晰', [-2, -1, 0, 0, 1, 2, 2, 1, 0, 0]), ('柔和高频', [0, 0, 0, 0, 0, 0, -1, -2, -3, -3]), ('流行', [1, 2, 1, 0, -1, 0, 1, 2, 1, 0]), ('摇滚', [2, 3, 2, 0, -1, 0, 2, 3, 2, 1]), ('电子', [4, 3, 2, 0, -1, 0, 1, 2, 2, 1]), ('爵士', [1, 2, 1, 0, 1, 1, 0, 1, 1, 0]), ('古典', [0, 0, 0, -1, 0, 0, 1, 1, 1, 1]), ('电影', [3, 3, 2, 0, 0, 1, 2, 1, 0, 0]), ('游戏', [-2, -2, -1, 0, 0, 1, 3, 2, 1, 0]), ('播客', [-3, -2, -1, 0, 1, 2, 2, 1, -1, -2]), ('女声', [-2, -1, -1, 0, 0, 1, 2, 2, 1, 0]), ('男声', [0, 1, 2, 1, 0, 1, 1, 0, -1, -1])]

def gains(values):
    if not isinstance(values, (list, tuple)) or len(values) != 10 or any(type(x) is not int or not -10 <= x <= 10 for x in values):
        raise ValueError('EQ 需要 10 段 ±10 dB 的整数，布尔值与小数不接受')
    return list(values)

def validate_profile(value):
    if not isinstance(value, dict): raise ValueError('收藏格式无效')
    pid, name = value.get('id'), value.get('name')
    if not isinstance(pid, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', pid): raise ValueError('收藏 ID 格式无效')
    if not isinstance(name, str) or not name.strip() or len(name.strip().encode('utf-16-le'))//2 > 40 or any(unicodedata.category(c) == 'Cc' for c in name):
        raise ValueError('名称须为 1–40 字且不含控制字符')
    return {'id':pid,'name':name.strip(),'gains':gains(value.get('gains'))}

def validate(value):
    if not isinstance(value, dict) or value.get('format') != 'svanar-eq' or type(value.get('version')) is not int or value['version'] != 1:
        raise ValueError('不是支持的 SVANAR EQ 文件版本')
    hz=value.get('frequencies'); profiles=value.get('profiles'); links=value.get('links')
    if not isinstance(hz,list) or any(type(x) is not int for x in hz) or hz != FREQUENCIES: raise ValueError('EQ 频段定义不匹配')
    if not isinstance(profiles,list) or len(profiles)>MAX_PROFILES or not isinstance(links,dict): raise ValueError('收藏数量或绑定格式无效')
    items=[validate_profile(p) for p in profiles]; ids=[p['id'] for p in items]
    if len(set(ids)) != len(ids): raise ValueError('文件包含重复收藏 ID')
    if any(k not in ('0','1','2') or not isinstance(v,str) or v not in ids for k,v in links.items()): raise ValueError('模式绑定指向缺失收藏')
    return {'format':'svanar-eq','version':1,'frequencies':FREQUENCIES.copy(),'profiles':items,'links':dict(links)}

def _pairs(pairs):
    result={}
    for k,v in pairs:
        if k in result: raise ValueError('JSON 包含重复字段')
        result[k]=v
    return result

def _constant(value): raise ValueError('JSON 不接受 '+value)

def decode(data):
    if isinstance(data,str): data=data.encode('utf-8')
    if not isinstance(data,bytes) or len(data)>MAX_BYTES: raise ValueError('文件超过 64 KiB 或格式无效')
    text=data.decode('utf-8-sig'); depth=0; quoted=False; escaped=False
    for c in text:
        if quoted:
            if escaped: escaped=False
            elif ord(c)==92: escaped=True
            elif c=='"': quoted=False
        elif c=='"': quoted=True
        elif c in '{[':
            depth+=1
            if depth>16: raise ValueError('JSON 嵌套过深')
        elif c in '}]': depth-=1
    return validate(json.loads(text,object_pairs_hook=_pairs,parse_constant=_constant))

def encode(value):
    data=json.dumps(validate(value),ensure_ascii=False,indent=2).encode('utf-8')
    if len(data)>MAX_BYTES: raise ValueError('收藏库超过 64 KiB')
    return data

def atomic_write(path,data):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    name=None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent,prefix='.'+path.name+'.',suffix='.tmp',delete=False) as f:
            name=f.name; f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(name,path)
    finally:
        if name and Path(name).exists(): Path(name).unlink()

def initial():
    return {'format':'svanar-eq','version':1,'frequencies':FREQUENCIES.copy(),'profiles':[{'id':f'builtin-{i}','name':n,'gains':g.copy()} for i,(n,g) in enumerate(PRESETS)],'links':{}}

def add(library, name, values, pid=None):
    result=copy.deepcopy(library); p=validate_profile({'id':pid or str(uuid.uuid4()),'name':name,'gains':values})
    index=next((i for i,x in enumerate(result['profiles']) if x['id']==p['id']),None)
    if index is None: result['profiles'].append(p)
    else: result['profiles'][index]=p
    return validate(result),p['id']

def remove(library,pid):
    result=copy.deepcopy(library);result['profiles']=[p for p in result['profiles'] if p['id']!=pid];result['links']={k:v for k,v in result['links'].items() if v!=pid};return validate(result)

def merge(library, imported):
    result=validate(library); incoming=validate(imported);ids={}
    for p in incoming['profiles']:
        old=next((x for x in result['profiles'] if x['id']==p['id']),None);new=copy.deepcopy(p)
        if old is not None and old!=p:new['id']=str(uuid.uuid4())
        result,_=add(result,new['name'],new['gains'],new['id']);ids[p['id']]=new['id']
    result['links'].update({k:ids[v] for k,v in incoming['links'].items()});return validate(result)

class Store:
    def __init__(self,path):
        self.path=Path(path);self.library=initial();self.enabled=False;self.load_error=None
        if self.path.exists():
            try:
                raw=self.path.read_bytes()
                if len(raw)>MAX_BYTES+2048:raise ValueError('本机收藏配置过大')
                value=json.loads(raw.decode('utf-8'),object_pairs_hook=_pairs,parse_constant=_constant)
                self.library=validate(value['library'])
                if type(value['enabled']) is not bool:raise ValueError('联动开关无效')
                self.enabled=value['enabled']
            except Exception as e:self.load_error=str(e)
    def save(self,library=None,enabled=None):
        value=validate(self.library if library is None else library);encode(value)
        active=self.enabled if enabled is None else bool(enabled)
        data=json.dumps({'library':value,'enabled':active},ensure_ascii=False,indent=2).encode('utf-8')
        # If an existing configuration was corrupt, preserve it before explicit recovery.
        if self.load_error and self.path.exists():
            backup=self.path.with_name(self.path.name+'.unreadable-'+uuid.uuid4().hex[:8]+'.bak');atomic_write(backup,self.path.read_bytes())
        atomic_write(self.path,data);self.library=value;self.enabled=active;self.load_error=None
    def mode_links(self):
        by_id={p['id']:p['gains'] for p in self.library['profiles']}
        return {int(k):by_id[v].copy() for k,v in self.library['links'].items()}
