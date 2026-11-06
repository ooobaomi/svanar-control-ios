"""Readback parsing only; no OTA or firmware write operations."""
ACTIONS=('无操作','播放 / 暂停','上一曲','下一曲','音量增加','音量减小','语音助手','模式切换','接听电话','挂断电话')
GESTURES=('', '单击','双击','三击','长按')

def touch_setting(ear,gesture,action):
    if any(type(v) is not int for v in (ear,gesture,action)) or ear not in (1,2) or gesture not in (1,2,3,4) or not 0<=action<len(ACTIONS):raise ValueError('未知耳侧、手势或动作')
    return bytes((ear,gesture,action))

def decode_touches(raw):
    if not raw or len(raw)>24 or len(raw)%3:raise ValueError('触控映射响应格式无效')
    result={}
    for i in range(0,len(raw),3):
        e,g,a=raw[i:i+3];touch_setting(e,g,a);key=e*10+g
        if key in result:raise ValueError('触控响应包含重复手势')
        result[key]=(e,g,a)
    return dict(sorted(result.items()))

def touch_bytes(mapping):return b''.join(touch_setting(*entry) for _,entry in sorted(mapping.items()))
def touch_name(entry):return ('左耳' if entry[0]==1 else '右耳')+' · '+GESTURES[entry[1]]

class Features:
    def __init__(self,raw=None):self.raw={int(k):bytes(v) for k,v in (raw or {}).items()}
    def accept(self,cmd,payload):self.raw[cmd]=bytes(payload)
    @property
    def game_supported(self):
        p=self.raw.get(2);return bool(p[2]&127==1) if p and len(p)>=3 else None
    @property
    def game(self):
        p=self.raw.get(9);return bool(p[0]) if p and len(p)==1 and p[0] in (0,1) else None
    @property
    def ldac(self):
        p=self.raw.get(13);return bool(p[2]&127==1) if p and len(p)>=3 else None
    def strength(self):
        flags=self.raw.get(2,b'');pairs=self.raw.get(5,b'');levels={pairs[i]:pairs[i+1]&127 for i in range(0,len(pairs)-1,2)}
        def flag(i):return '未读取' if len(flags)<=i else '声明支持' if flags[i]&127==1 else '未声明支持'
        return f"降噪强度：{flag(4)}；档位字段 {levels.get(1,'—')}\n通透强度：{flag(5)}；档位字段 {levels.get(2,'—')}\n接口未验证时不开放强度滑块；EQ 与音量不等于强度。"
    def describe(self):
        lines=['最近一次耳机报告；不等于 Windows 实际音频协商']
        p=self.raw.get(12,b'')
        if len(p)>8:
            model=p[:-8].decode('utf-8',errors='replace').strip('\0\r\n ')
            lines.extend(['型号：'+model,'固件字节：'+p[-8:-4].hex(' ').upper(),'充电盒版本字节：'+p[-4:].hex(' ').upper()])
        p=self.raw.get(11,b'')
        if len(p)>=3:
            groups=(('SBC','AAC','LDAC','aptX','aptX Adaptive','aptX Lossless','aptX HD','LHDC 4','LHDC 5','LC3','LC3 Plus','L2HC'),('16 bit','24 bit','32 bit'),('44.1 kHz','48 kHz','96 kHz','192 kHz','88.2 kHz','384 kHz'))
            values=[group[value&127] if value&127<len(group) else '未知' for group,value in zip(groups,p)]
            lines.append('耳机编码报告：'+' / '.join(values))
        lines.extend(['LDAC 能力声明：'+('未取得' if self.ldac is None else '支持' if self.ldac else '未声明'),'游戏模式：'+('未取得' if self.game is None else '开启' if self.game else '关闭'),self.strength(),'原始响应：'])
        lines.extend(f'{key:02X}: '+raw.hex(' ').upper() for key,raw in sorted(self.raw.items()))
        return '\n'.join(lines)
