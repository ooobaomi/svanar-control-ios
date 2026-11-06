"""HIFIMAN ff77 control transport, independently implemented from protocol facts.

FE command 00 length(BE16) payload CRC16-CCITT-FALSE(BE16).
Queries have empty payload; 06 mode, 08 signed 10-band hardware EQ.
"""
import asyncio
import binascii
import json
import queue
import re
import subprocess
import threading
import time
from pathlib import Path
import logging
from device_features import Features, decode_touches, touch_setting, touch_bytes
from eq_library import atomic_write

SERVICE = '0000ff77-0000-1000-8000-00805f9b34fb'
TX = '0000ff88-0000-1000-8000-00805f9b34fb'
RX = '0000ff99-0000-1000-8000-00805f9b34fb'
FREQUENCIES = (31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
MODES = {0: 'HiFi', 1: '降噪', 2: '通透'}


def encode(command, payload=b''):
    data = bytes((254, command, 0)) + len(payload).to_bytes(2, 'big') + payload
    return data + binascii.crc_hqx(data, 65535).to_bytes(2, 'big')


def decode(data):
    if len(data) < 7 or data[0] != 254 or len(data) != 7 + int.from_bytes(data[3:5], 'big'):
        raise ValueError('无效的耳机响应长度')
    if data[-2:] != binascii.crc_hqx(data[:-2], 65535).to_bytes(2, 'big'):
        raise ValueError('耳机响应校验失败')
    return data[1], data[5:-2]


def eq_payload(gains):
    if len(gains) != 10 or any(type(g) is not int or not -10 <= g <= 10 for g in gains):
        raise ValueError('EQ 必须是 10 个 -10 至 +10 的整数 dB 值')
    return bytes((101, 10)) + bytes(g & 255 for g in gains)


def decode_eq(payload):
    if len(payload) != 12 or payload[0] not in (100,101) or payload[1] != 10:
        raise ValueError('此耳机返回的 EQ 格式不受支持')
    values = [b if b < 128 else b - 256 for b in payload[2:]]
    if any(not -10 <= g <= 10 for g in values):
        raise ValueError('EQ 回读值超出范围')
    return values


def known_addresses():
    ps = "Get-PnpDevice -Class Bluetooth | Where-Object FriendlyName -eq 'HIFIMAN SVANAR WIRELESS' | Select-Object -ExpandProperty InstanceId"
    r = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', ps],
                       capture_output=True, timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
    if r.returncode:
        raise RuntimeError('读取已配对耳机身份失败')
    return {m.upper() for m in re.findall(rb'DEV_([0-9A-Fa-f]{12})', r.stdout)}


async def find_headphone(return_identity=False):
    from bleak import BleakScanner
    addresses = await asyncio.to_thread(known_addresses)
    if not addresses:
        raise RuntimeError('请先在 Windows 中配对 SVANAR WIRELESS')
    matches = {}
    def match(device, adv):
        raw = adv.manufacturer_data.get(58914, b'')
        # Match the advertised Classic address, NOT only a nearby device name.
        if len(raw) < 11:
            return False
        classic = bytes(b ^ 173 for b in raw[5:11]).hex().upper().encode()
        valid = classic in addresses and int.from_bytes(raw[2:4], 'big') == 2
        if valid: matches[device.address] = ':'.join(classic.decode()[i:i+2] for i in range(0,12,2))
        return valid
    result = await BleakScanner.find_device_by_filter(match, timeout=10)
    if result is None:
        raise RuntimeError('未找到与已配对耳机匹配的控制广播，请唤醒双耳并关闭手机 App 后重试')
    return (result, matches[result.address]) if return_identity else result


class Session:
    def __init__(self, client):
        self.client = client
        self.responses = asyncio.Queue()
        self.buffer = bytearray()
        self.broken = False

    async def start(self):
        service = self.client.services.get_service(SERVICE)
        if service is None:
            raise RuntimeError('耳机缺少 ff77 控制服务')
        await self.client.start_notify(RX, self.notify)

    def notify(self, _, data):
        self.buffer.extend(data)
        while self.buffer:
            if self.buffer[0] != 254:
                self.buffer.pop(0)
                continue
            if len(self.buffer) < 5:
                return
            length = 7 + int.from_bytes(self.buffer[3:5], 'big')
            if length > 2048:
                self.buffer.pop(0)
                continue
            if len(self.buffer) < length:
                return
            frame = bytes(self.buffer[:length])
            del self.buffer[:length]
            try:
                self.responses.put_nowait(decode(frame))
            except ValueError:
                continue

    async def request(self, command, payload=b''):
        if self.broken:
            raise RuntimeError('控制会话已失效，请重新连接')
        while not self.responses.empty(): self.responses.get_nowait()
        try:
            await asyncio.wait_for(self.client.write_gatt_char(TX, encode(command, payload), response=True),4)
            deadline=asyncio.get_running_loop().time()+4
            while True:
                remaining=deadline-asyncio.get_running_loop().time()
                if remaining<=0:raise TimeoutError('耳机响应超时')
                cmd,data=await asyncio.wait_for(self.responses.get(),remaining)
                if cmd==command:return data
        except Exception:
            # No sequence numbers exist: any transport failure invalidates this session.
            self.broken=True
            try:await self.client.disconnect()
            except Exception:pass
            raise

    async def mode(self):
        data = await self.request(6)
        if len(data) != 2 or data[0] not in MODES:
            raise ValueError('耳机模式回读无效')
        return data[0]

    async def eq(self):
        return decode_eq(await self.request(8))

    async def set_mode(self, mode):
        if mode not in MODES:
            raise ValueError('不支持的模式')
        # Firmware can echo a SET before its audio state transition completes.
        for attempt in range(2):
            await self.request(6, bytes((mode, 0)))
            for _ in range(4):
                await asyncio.sleep(.7)
                actual = await self.mode()
                if actual == mode:
                    return actual
            if attempt == 0:
                await asyncio.sleep(1)
        raise RuntimeError('模式未通过回读确认，请双耳佩戴后重试')

    async def set_eq(self, gains):
        await self.request(8, eq_payload(gains))
        await asyncio.sleep(.5)
        actual = await self.eq()
        if actual != gains:
            raise RuntimeError('EQ 未通过耳机回读确认')
        return actual


class Bridge:
    """Single BLE owner, serialized requests, immutable configuration snapshots."""
    def __init__(self,data_dir=None):
        self.commands=queue.Queue();self.events=queue.Queue();self.stop_event=threading.Event();self.thread=None
        self.data_dir=Path(data_dir) if data_dir is not None else None
        self.config_lock=threading.Lock();self.links_enabled=False;self.links={}

    def set_links(self,enabled,links):
        valid={}
        for mode,values in links.items():
            if type(mode) is not int or mode not in MODES:raise ValueError('模式绑定无效')
            eq_payload(values);valid[mode]=list(values)
        with self.config_lock:self.links_enabled=bool(enabled);self.links=valid

    def connect(self):
        if self.thread and self.thread.is_alive():return
        self.stop_event.clear();self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()

    def run(self):
        try:asyncio.run(self.main())
        except Exception as e:
            logging.exception('BLE worker stopped')
            self.events.put({'connected':False,'done':True,'message':f'控制连接断开：{e or type(e).__name__}；请重新连接'})

    async def _linked(self,session,mode):
        with self.config_lock:target=list(self.links[mode]) if self.links_enabled and mode in self.links else None
        if target is None:return None
        before=await session.eq();actual=await session.set_eq(target) if before!=target else before
        self.events.put({'connected':True,'eq':actual,'message':MODES[mode]+'与绑定 EQ 已回读确认'})
        return actual

    def _backup_path(self,identity):
        if self.data_dir is None or not re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}',identity):raise RuntimeError('未确认耳机身份或备份目录')
        return self.data_dir/('touch-original-'+identity.replace(':','')+'.json')

    def _backup(self,identity,mapping):
        path=self._backup_path(identity)
        if path.exists():
            raw=path.read_bytes()
            if len(raw)>4096:raise ValueError('触控备份大小异常')
            value=json.loads(raw)
            if value.get('identity')!=identity:raise ValueError('触控备份身份不匹配')
            decode_touches(bytes(value['raw']))
        else:atomic_write(path,json.dumps({'identity':identity,'raw':list(touch_bytes(mapping))}).encode())

    async def _write_touch(self,session,before,entry):
        ear,gesture,action=entry;touch_setting(ear,gesture,action);key=ear*10+gesture
        if key not in before:raise ValueError('耳机未返回此手势')
        if before[key]==entry:return before
        await session.request(4,touch_setting(*entry));await asyncio.sleep(.45)
        actual=decode_touches(await session.request(4))
        self.events.put({'connected':True,'touches':actual})
        if set(actual)!=set(before) or actual[key]!=entry or any(v!=actual[k] for k,v in before.items() if k!=key):raise RuntimeError('触控回读不一致，原备份已保留')
        return actual

    async def _battery(self,session):
        b=await session.request(3)
        return {'left':(b[0]&127) if len(b)>0 and b[0]&127<=100 else None,'right':(b[1]&127) if len(b)>1 and b[1]&127<=100 else None}

    async def main(self):
        from bleak import BleakClient
        self.events.put({'connected':False,'message':'正在匹配耳机控制接口…'})
        while not self.commands.empty():self.commands.get_nowait()
        device,identity=await find_headphone(return_identity=True)
        async with BleakClient(device,timeout=15) as client:
            session=Session(client);await session.start();features=Features()
            mode,eq=await session.mode(),await session.eq();battery=await self._battery(session)
            self.events.put({'connected':True,'mode':mode,'eq':eq,'identity':identity,**battery,'message':'硬件控制已连接 · 首次连接只读，模式与 EQ 已回读'})
            last=time.monotonic()
            while not self.stop_event.is_set() and client.is_connected:
                try:action,value=self.commands.get_nowait()
                except queue.Empty:
                    if time.monotonic()-last>5:
                        actual=await session.mode()
                        if actual!=mode:await self._linked(session,actual)
                        mode=actual;self.events.put({'connected':True,'mode':mode,**(await self._battery(session))});last=time.monotonic()
                    await asyncio.sleep(.1);continue
                self.events.put({'connected':True,'busy':True})
                try:
                    result={}
                    if action=='mode':
                        mode=await session.set_mode(value);eq=await self._linked(session,mode)
                        result={'mode':mode,'message':MODES[mode]+('与绑定 EQ 已确认' if eq is not None else '模式已回读确认')}
                        if eq is not None:result['eq']=eq
                    elif action=='eq':result={'eq':await session.set_eq(value),'message':'EQ 已写入耳机，10 段回读一致'}
                    elif action=='read':
                        actual=await session.mode()
                        if actual!=mode:await self._linked(session,actual)
                        mode=actual;result={'mode':mode,'eq':await session.eq(),**(await self._battery(session)),'message':'已重新读取耳机模式、EQ 和左右耳电量'}
                    elif action in ('extras','strength'):
                        for cmd in ((2,5,6,9,11,12,13) if action=='extras' else (2,5,6)):
                            features.accept(cmd,await session.request(cmd));self.events.put({'connected':True,'features':dict(features.raw)})
                        result={'message':'扩展信息已读取；未写固件或未知档位'}
                    elif action=='game':
                        if features.game_supported is not True or features.game is None:raise ValueError('先读取扩展信息，确认支持游戏模式')
                        await session.request(9,bytes((1 if value else 0,)));await asyncio.sleep(.6);raw=await session.request(9);features.accept(9,raw)
                        self.events.put({'connected':True,'features':dict(features.raw)})
                        if raw!=bytes((1 if value else 0,)):raise RuntimeError('游戏模式回读不一致')
                        result={'message':'游戏模式已'+('开启' if value else '关闭')+'，回读一致'}
                    elif action=='touch_read':result={'touches':decode_touches(await session.request(4)),'message':'触控映射已读取；只开放耳机返回的手势'}
                    elif action=='touch_set':
                        before=decode_touches(await session.request(4));self._backup(identity,before)
                        result={'touches':await self._write_touch(session,before,tuple(value)),'message':'触控映射写入回读一致；实际手势请在耳机确认'}
                    elif action=='touch_restore':
                        path=self._backup_path(identity);raw=path.read_bytes()
                        if len(raw)>4096:raise ValueError('触控备份大小异常')
                        backup=json.loads(raw)
                        if backup.get('identity')!=identity:raise ValueError('备份身份不匹配')
                        target=decode_touches(bytes(backup['raw']));actual=decode_touches(await session.request(4))
                        if set(target)!=set(actual):raise ValueError('备份与当前手势集合不匹配')
                        for entry in target.values():actual=await self._write_touch(session,actual,entry)
                        if actual!=target:raise RuntimeError('触控恢复回读不一致')
                        result={'touches':actual,'message':'首次修改前的触控备份已恢复，回读一致'}
                    self.events.put({'connected':True,'done':True,'busy':False,**result})
                except Exception as e:
                    message=f'操作未完成：{e or type(e).__name__}'
                    if action.startswith('touch'):message+='；触控未取得可验证结果，写入保持禁用'
                    self.events.put({'connected':client.is_connected,'done':True,'busy':False,'message':message,'touch_error':message if action.startswith('touch') else None})
                    if session.broken:raise
                last=time.monotonic()
        self.events.put({'connected':False,'done':True,'message':'耳机控制已断开；音频仍由 Windows 管理'})

    def submit(self,action,value=None):self.commands.put((action,value))
    def close(self):self.stop_event.set()
