"""Offline tests. Mock transport cases do not claim physical headset verification."""
import asyncio
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import eq_library as eq
from device_features import Features,decode_touches,touch_setting,touch_bytes
from headphone_ble import Bridge,Session,encode,decode,eq_payload

class LibraryTests(unittest.TestCase):
    def test_fixture_roundtrip(self):
        library=eq.decode(Path(__file__).with_name('EQ-file-example.json').read_bytes())
        self.assertEqual(len(library['profiles']),14);self.assertEqual(eq.decode(eq.encode(library)),library)
    def test_strict_gains(self):
        for values in ([True]*10,[1.5]*10,[11]*10,[0]*9):
            with self.subTest(values=values),self.assertRaises(ValueError):eq.gains(values)
            with self.subTest(protocol=values),self.assertRaises(ValueError):eq_payload(values)
    def test_format_bounds(self):
        valid=eq.initial()
        cases=[]
        for key,value in [('version',True),('version',2),('frequencies',[31]*10),('links',{'1':'missing'})]:
            obj=copy.deepcopy(valid);obj[key]=value;cases.append(json.dumps(obj).encode())
        cases += [b' '*65537,b'['*18,b'{"format":"svanar-eq","format":"bad"}',b'NaN']
        for raw in cases:
            with self.subTest(raw=raw[:30]),self.assertRaises(ValueError):eq.decode(raw)
    def test_collision_and_removal(self):
        a={'format':'svanar-eq','version':1,'frequencies':eq.FREQUENCIES,'profiles':[],'links':{}}
        a,pid=eq.add(a,'original',[0]*10,'same');a['links']['1']=pid
        b=copy.deepcopy(a);b['profiles'][0]['gains'][0]=1
        merged=eq.merge(a,b);self.assertEqual(len(merged['profiles']),2);self.assertNotEqual(merged['links']['1'],'same')
        self.assertEqual(eq.remove(a,'same')['links'],{})
    def test_quote_names_and_atomic_store(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'profiles.json';store=eq.Store(path);library,_=eq.add(store.library,'曲线 "[]\\"',[0]*10)
            store.save(library,True);other=eq.Store(path);self.assertTrue(other.enabled);self.assertEqual(other.library,library)
            self.assertEqual(eq.decode(eq.encode(library)),library)
            eq.atomic_write(Path(folder)/'export.json',eq.encode(library));self.assertEqual(list(Path(folder).glob('*.tmp')),[])
    def test_corrupt_config_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'profiles.json';path.write_bytes(b'invalid original')
            store=eq.Store(path);self.assertIsNotNone(store.load_error);store.save(eq.initial(),False)
            backups=list(Path(folder).glob('*.bak'));self.assertEqual(len(backups),1);self.assertEqual(backups[0].read_bytes(),b'invalid original')
    def test_max_profiles(self):
        library=eq.initial()
        for i in range(50):library,_=eq.add(library,str(i),[0]*10)
        with self.assertRaises(ValueError):eq.add(library,'too many',[0]*10)

class FeatureTests(unittest.TestCase):
    def test_touch_roundtrip(self):
        raw=bytes([1,1,1,1,2,3,2,1,1]);self.assertEqual(touch_bytes(decode_touches(raw)),raw)
        for invalid in (b'',b'12',bytes([0,1,1]),bytes([1,5,1]),bytes([1,1,99]),bytes([1,1,1,1,1,1])):
            with self.assertRaises(ValueError):decode_touches(invalid)
    def test_capabilities(self):
        f=Features({2:[1,1,1,0,0,0],5:[0,0,1,0,2,0],9:[0],11:[1,0,0],13:[1,1,1,0,0,0,0,0,0,0,0,0]})
        self.assertTrue(f.game_supported);self.assertFalse(f.game);self.assertTrue(f.ldac)
        self.assertIn('AAC / 16 bit / 44.1 kHz',f.describe());self.assertIn('档位字段 0',f.strength())

class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_timeout_invalidates_session(self):
        class Client:
            disconnected=False
            async def write_gatt_char(self,*args,**kw):raise TimeoutError('mock timeout')
            async def disconnect(self):self.disconnected=True
        client=Client();session=Session(client)
        with self.assertRaises(TimeoutError):await session.request(6)
        self.assertTrue(client.disconnected)
        with self.assertRaises(RuntimeError):await session.request(6)
    async def test_link_opt_in(self):
        class Fake:
            values=[0]*10
            writes=0
            async def eq(self):return self.values.copy()
            async def set_eq(self,values):self.writes+=1;self.values=values.copy();return self.values
        bridge=Bridge();session=Fake();bridge.set_links(False,{1:[1]*10});self.assertIsNone(await bridge._linked(session,1));self.assertEqual(session.writes,0)
        bridge.set_links(True,{1:[1]*10});self.assertEqual(await bridge._linked(session,1),[1]*10);self.assertEqual(session.writes,1)
        self.assertIsNone(await bridge._linked(session,2));self.assertEqual(session.writes,1)
    async def test_first_connection_read_only(self):
        bridge=Bridge();bridge.set_links(True,{0:[1]*10});frames=[]
        class Fake:
            is_connected=True
            callback=None
            async def __aenter__(self):return self
            async def __aexit__(self,*args):self.is_connected=False
            @property
            def services(self):return self
            def get_service(self,*args):return object()
            async def start_notify(self,uuid,callback):self.callback=callback
            async def write_gatt_char(self,uuid,data,response):
                cmd,payload=decode(data);frames.append((cmd,payload));values={6:bytes([0,0]),8:bytes([100,10]+[0]*10),3:bytes([90,91,0])}
                self.callback(None,encode(cmd,values[cmd]))
                if len(frames)==3:bridge.stop_event.set()
            async def disconnect(self):self.is_connected=False
        async def find(return_identity=False):return ('mock-device','12:34:56:78:9A:BC')
        with mock.patch('headphone_ble.find_headphone',find),mock.patch('bleak.BleakClient',lambda *a,**k:Fake()):await asyncio.wait_for(bridge.main(),2)
        self.assertEqual([c for c,p in frames],[6,8,3]);self.assertTrue(all(p==b'' for c,p in frames))
    async def test_touch_backup_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            bridge=Bridge(folder);mapping=decode_touches(bytes([1,1,1,2,1,1]));identity='12:34:56:78:9A:BC';bridge._backup(identity,mapping)
            original=bridge._backup_path(identity).read_bytes();bridge._backup(identity,decode_touches(bytes([1,1,2,2,1,1])));self.assertEqual(bridge._backup_path(identity).read_bytes(),original)
            with self.assertRaises(RuntimeError):bridge._backup_path('../bad')

if __name__=='__main__':unittest.main()
