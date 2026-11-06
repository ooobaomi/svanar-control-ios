"""SVANAR Control: local Windows companion. No network service or account."""
import ctypes
import json
import logging
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import ttk, messagebox
from companion_ui import CompanionMixin
from eq_library import PRESETS
import warnings

warnings.filterwarnings('ignore', category=FutureWarning, module='pycaw.*')
from pycaw.pycaw import AudioUtilities
from pycaw.constants import ERole
from headphone_ble import Bridge, MODES, FREQUENCIES

DATA = Path(os.environ.get('SVANAR_CONTROL_DATA_DIR',str(Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'SvanarControl')))
DATA.mkdir(parents=True, exist_ok=True)
logging.basicConfig(filename=DATA / 'app.log', level=logging.INFO,
                    format='%(asctime)s %(levelname)s %(message)s')
BG, CARD, FG, DIM, ACCENT = '#101719', '#1b2629', '#eef5f1', '#9baead', '#9ce5bb'


def devices():
    return AudioUtilities.GetAllDevices(data_flow=0, device_state=1)


def headset(items):
    matches = [d for d in items if 'HIFIMAN' in d.FriendlyName.upper()
               and 'SVANAR' in d.FriendlyName.upper()]
    return next((d for d in matches if 'hands-free' not in d.FriendlyName.lower()),
                matches[0] if matches else None)


def battery():
    # Read only driver-published battery properties for this device/container.
    ps = r'''$ErrorActionPreference='Stop'
    $all=@(Get-PnpDevice -ErrorAction Stop)
    $root=@($all | Where-Object {$_.Class -eq 'Bluetooth' -and $_.FriendlyName -eq 'HIFIMAN SVANAR WIRELESS'})
    $containers=@($root | ForEach-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction SilentlyContinue).Data })
    $result=@()
    foreach($d in $all) {
      if($d.FriendlyName -like '*HIFIMAN*' -or $d.InstanceId -match 'BTHENUM|BTHLEDEVICE|BTHHFENUM') {
        $props=@(Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue)
        $cid=($props | Where-Object KeyName -eq 'DEVPKEY_Device_ContainerId').Data
        if($d.FriendlyName -like '*HIFIMAN*' -or ($cid -and $containers -contains $cid)) {
          foreach($p in $props) {
            if($p.KeyName -match 'BatteryLifePercent|BatteryLevel|BatteryPercent|\{104EA319-6EE2-4701-BD47-8DDBF425BBE5\} 2') {
              $n=0
              if([int]::TryParse([string]$p.Data,[ref]$n) -and $n -ge 0 -and $n -le 100) {
                $result+=@{percent=$n;source=$p.KeyName}
              }
            }
          }
        }
      }
    }
    ConvertTo-Json -InputObject @($result) -Compress'''
    r = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', ps],
                       capture_output=True, timeout=35, creationflags=subprocess.CREATE_NO_WINDOW)
    if r.returncode:
        raise RuntimeError('Windows 设备属性读取失败')
    values = json.loads(r.stdout.decode('utf-8-sig').strip() or '[]')
    # A single Windows value does not establish separate L/R/case battery levels.
    unique = sorted({v['percent'] for v in values})
    return ' / '.join(f'{v}%' for v in unique) if unique else '驱动未提供电量'


class App(CompanionMixin, tk.Tk):
    def __init__(self, *, data_dir=None, start_services=True):
        super().__init__()
        self._test_mode = not start_services
        if self._test_mode:self.withdraw()
        self.title('SVANAR Control 1.3 · HIFIMAN')
        self.geometry('760x790')
        self.minsize(700, 760)
        self.configure(bg=BG)
        self.data_dir = Path(data_dir) if data_dir is not None else DATA
        self.init_companion()
        self.dev = None
        self.items = []
        self.updating = False
        self.events = queue.Queue()
        self.battery_busy = False
        self.previous = None
        self.ble = Bridge(self.data_dir)
        self.sync_links()
        self.ble_connected = False
        self.ble_busy = False
        self.mode_text = tk.StringVar(value='当前模式：等待耳机控制连接')
        self.control_text = tk.StringVar(value='正在准备硬件接口…')
        self.eq_values = [tk.IntVar(value=0) for _ in FREQUENCIES]
        self.eq_readback = None
        self.eq_window = None
        self.status = tk.StringVar(value='正在读取音频端点…')
        self.battery_text = tk.StringVar(value='正在读取…')
        self.default_text = tk.StringVar(value='—')
        self.notice = tk.StringVar(value='只操作选中的 SVANAR 音频端点；退出后保留当前系统音量。')
        self.volume = tk.DoubleVar(value=0)
        self.percent = tk.StringVar(value='—')
        self.mute_text = tk.StringVar(value='静音')
        self.output = tk.StringVar()
        style = ttk.Style(self)
        style.theme_use('clam')
        style.configure('TCombobox', fieldbackground=CARD, background=CARD, foreground=FG,
                        arrowcolor=ACCENT, padding=8)
        style.map('TCombobox', fieldbackground=[('readonly', CARD)],
                  foreground=[('readonly', FG)], selectbackground=[('readonly', CARD)])
        self.build()
        self.update_idletasks()
        # Fit content at the user's actual Windows DPI instead of clipping cards.
        height = min(self.winfo_screenheight() - 100, self.winfo_reqheight() + 20)
        self.geometry(f'820x{max(790, height)}')
        self.report_callback_exception = self.callback_error
        self.after(200, self.poll)
        if start_services:
            self.after(80, self.refresh)
            self.after(250, self.refresh_battery)
            self.after(350, self.ble.connect)
        if self.store.load_error:self.notice.set('收藏读取异常，原配置保留：'+self.store.load_error)
        self.protocol('WM_DELETE_WINDOW', self.close)

    def label(self, parent, text='', size=11, color=FG, variable=None, **kw):
        return tk.Label(parent, text=text, textvariable=variable, bg=parent['bg'], fg=color,
                        font=('Microsoft YaHei UI', size), **kw)

    def button(self, parent, text, command, primary=False):
        return tk.Button(parent, text=text, command=lambda: self.safe(command),
                         bg=ACCENT if primary else '#2a3a3e', fg=BG if primary else FG,
                         activebackground='#b7f1ce', activeforeground=BG, relief='flat',
                         bd=0, padx=16, pady=9, cursor='hand2', font=('Microsoft YaHei UI', 10))

    def card(self):
        frame = tk.Frame(self.body, bg=CARD, padx=22, pady=15)
        frame.pack(fill='x', padx=28, pady=(0, 12))
        return frame

    def build(self):
        canvas=tk.Canvas(self,bg=BG,highlightthickness=0);bar=ttk.Scrollbar(self,orient='vertical',command=canvas.yview)
        bar.pack(side='right',fill='y');canvas.pack(side='left',fill='both',expand=True);canvas.configure(yscrollcommand=bar.set)
        self.body=tk.Frame(canvas,bg=BG);item=canvas.create_window((0,0),window=self.body,anchor='nw')
        self.body.bind('<Configure>',lambda e:canvas.configure(scrollregion=canvas.bbox('all')))
        canvas.bind('<Configure>',lambda e:canvas.itemconfigure(item,width=e.width))
        def wheel(e):
            if not isinstance(e.widget,(tk.Scale,ttk.Combobox)):canvas.yview_scroll(-int(e.delta/120),'units')
        self.bind('<MouseWheel>',wheel)
        top = tk.Frame(self.body, bg=BG)
        top.pack(fill='x', padx=30, pady=(22, 18))
        self.label(top, 'SVANAR', 28, ACCENT).pack(anchor='w')
        self.label(top, 'CONTROL  /  Windows 耳机伴侣', 11, DIM).pack(anchor='w')
        c = self.card()
        self.label(c, 'HIFIMAN SVANAR WIRELESS', 15).pack(anchor='w')
        self.label(c, variable=self.status, color=ACCENT).pack(anchor='w', pady=(7, 0))
        self.label(c, variable=self.default_text, color=DIM, size=10).pack(anchor='w')
        row = tk.Frame(c, bg=CARD)
        row.pack(fill='x', pady=(10, 0))
        self.label(row, '耳机电量', color=DIM).pack(side='left')
        self.label(row, variable=self.battery_text).pack(side='left', padx=12)
        self.button(row, '刷新电量', self.refresh_battery).pack(side='right')
        c = self.card()
        row = tk.Frame(c, bg=CARD)
        row.pack(fill='x')
        self.label(row, '耳机音量', 13).pack(side='left')
        self.label(row, variable=self.percent, size=21, color=ACCENT).pack(side='right')
        self.slider = tk.Scale(c, from_=0, to=100, resolution=1, orient='horizontal',
                               variable=self.volume, command=self.set_volume, showvalue=False,
                               bg=CARD, fg=FG, troughcolor=BG, highlightthickness=0,
                               activebackground=ACCENT, length=600, sliderrelief='raised',
                               sliderlength=28, width=16)
        self.slider.pack(fill='x', pady=10)
        row = tk.Frame(c, bg=CARD)
        row.pack(fill='x')
        self.mute = self.button(row, '静音', self.toggle_mute)
        self.mute.configure(textvariable=self.mute_text)
        self.mute.pack(side='left')
        self.button(row, '保存音量', self.save_volume).pack(side='left', padx=8)
        self.button(row, '恢复已存音量', self.load_volume).pack(side='left')
        c = self.card()
        self.label(c, '输出路由', 13).pack(anchor='w')
        self.combo = ttk.Combobox(c, textvariable=self.output, state='readonly')
        self.combo.pack(fill='x', pady=(10, 10))
        row = tk.Frame(c, bg=CARD)
        row.pack(fill='x')
        self.button(row, '设为默认输出', self.set_default, True).pack(side='left')
        self.button(row, '恢复上次输出', self.restore_default).pack(side='left', padx=8)
        self.button(row, '蓝牙设置', lambda: os.startfile('ms-settings:bluetooth')).pack(side='right')
        c = self.card()
        self.label(c, '耳机硬件控制', 13).pack(anchor='w')
        self.label(c, variable=self.mode_text, color=ACCENT).pack(anchor='w', pady=(7, 0))
        row = tk.Frame(c, bg=CARD)
        row.pack(fill='x', pady=10)
        self.mode_buttons = []
        for mode, name in MODES.items():
            b = self.button(row, name, lambda m=mode: self.send_control('mode', m))
            b.configure(state='disabled')
            b.pack(side='left', padx=(0, 8))
            self.mode_buttons.append(b)
        self.button(row, '10 段硬件 EQ', self.open_eq, True).pack(side='right')
        row = tk.Frame(c, bg=CARD)
        row.pack(fill='x')
        self.label(row, variable=self.control_text, size=9, color=DIM,
                   wraplength=520, justify='left').pack(side='left')
        self.button(row, '重新连接', self.ble.connect).pack(side='right')
        row=tk.Frame(c,bg=CARD);row.pack(fill='x',pady=(10,0))
        self.button(row,'收藏 / 文件 / 联动',self.open_library).pack(side='left')
        self.button(row,'游戏 / 诊断 / 触控',self.open_extras).pack(side='left',padx=8)
        self.button(row,'断开控制',self.ble.close).pack(side='right')
        self.label(self.body, variable=self.notice, size=9, color=DIM,
                   wraplength=700, justify='left').pack(fill='x', padx=30, pady=(0, 10))

    def safe(self, fn):
        try:
            fn()
        except Exception as e:
            logging.exception('Action failed')
            self.notice.set(f'操作未完成：{e}')

    def callback_error(self, kind, value, tb):
        logging.error('UI error', exc_info=(kind, value, tb))
        self.notice.set(f'操作未完成：{value}')

    def require(self):
        if not self.dev:
            raise RuntimeError('耳机音频端点未就绪，请先在蓝牙设置连接耳机')
        return self.dev.EndpointVolume

    def refresh(self):
        try:
            self.items = devices()
            self.dev = headset(self.items)
            names = [f'{i+1}. {d.FriendlyName}' for i, d in enumerate(self.items)]
            old = self.combo.current()
            old_id = getattr(self, 'selected_id', None)
            if 0 <= old < len(getattr(self, 'combo_ids', [])):
                old_id = self.combo_ids[old]
            self.combo.configure(values=names)
            self.combo_ids = [d.id for d in self.items]
            chosen = old_id if old_id in self.combo_ids else (self.dev.id if self.dev else None)
            if chosen:
                self.combo.current(self.combo_ids.index(chosen))
            else:
                self.output.set('没有可用输出')
            default = AudioUtilities.GetSpeakers()
            self.default_text.set('系统默认：' + default.FriendlyName)
            self.status.set('● 音频端点已就绪' + (' · 当前默认输出' if self.dev and self.dev.id == default.id else '')
                            if self.dev else '○ 耳机未连接 / 音频端点未就绪')
            state = 'normal' if self.dev else 'disabled'
            self.slider.configure(state=state)
            self.mute.configure(state=state)
            if self.dev and not self.slider_is_dragging():
                self.updating = True
                try:
                    self.volume.set(round(self.require().GetMasterVolumeLevelScalar() * 100))
                    self.percent.set(f'{int(self.volume.get())}%')
                    self.mute_text.set('取消静音' if self.require().GetMute() else '静音')
                finally:
                    self.updating = False
        except Exception as e:
            self.dev = None
            self.slider.configure(state='disabled')
            self.mute.configure(state='disabled')
            self.status.set('音频接口暂不可用')
            self.notice.set(str(e))
            logging.exception('Refresh failed')
        self.after(2500, self.refresh)

    def slider_is_dragging(self):
        return bool(ctypes.windll.user32.GetAsyncKeyState(1) & 0x8000)

    def set_volume(self, value):
        if self.updating:
            return
        def apply():
            v = max(0, min(100, float(value)))
            self.require().SetMasterVolumeLevelScalar(v / 100, None)
            self.percent.set(f'{round(v)}%')
        self.safe(apply)

    def toggle_mute(self):
        v = self.require()
        mute = not v.GetMute()
        v.SetMute(mute, None)
        self.mute_text.set('取消静音' if mute else '静音')

    def save_volume(self):
        value = self.require().GetMasterVolumeLevelScalar()
        temp = self.data_dir / 'settings.tmp'
        temp.write_text(json.dumps({'volume': value}), encoding='utf-8')
        temp.replace(self.data_dir / 'settings.json')
        self.notice.set(f'已保存耳机音量 {round(value * 100)}%，不会自动应用。')

    def load_volume(self):
        path = self.data_dir / 'settings.json'
        if not path.exists():
            raise RuntimeError('尚未保存音量')
        v = float(json.loads(path.read_text(encoding='utf-8'))['volume'])
        if not 0 <= v <= 1:
            raise ValueError('音量配置无效')
        if v > .65 and not messagebox.askyesno('恢复音量', f'将恢复到 {round(v*100)}%，继续？'):
            return
        self.require().SetMasterVolumeLevelScalar(v, None)
        self.volume.set(round(v * 100))
        self.percent.set(f'{round(v * 100)}%')
        self.notice.set('已恢复保存的耳机音量。')

    def set_default(self):
        i = self.combo.current()
        if not 0 <= i < len(self.items):
            raise RuntimeError('请选择可用音频输出')
        previous = AudioUtilities.GetSpeakers().id
        target = self.items[i]
        if target.id == previous:
            self.notice.set('该设备已是多媒体默认输出。')
            return
        AudioUtilities.SetDefaultDevice(target.id, [ERole.eConsole, ERole.eMultimedia])
        if AudioUtilities.GetSpeakers().id != target.id:
            raise RuntimeError('Windows 未确认输出切换')
        self.previous = previous
        self.notice.set('已切换默认输出；通信设备设置保持不变。已打开的应用可能需要重新选择输出。')

    def restore_default(self):
        if not self.previous:
            raise RuntimeError('本次运行尚无可恢复的输出记录')
        if self.previous not in [d.id for d in devices()]:
            raise RuntimeError('原输出当前不可用')
        current = AudioUtilities.GetSpeakers().id
        AudioUtilities.SetDefaultDevice(self.previous, [ERole.eConsole, ERole.eMultimedia])
        self.previous = current
        self.notice.set('已恢复上次默认输出。')

    def refresh_battery(self):
        if self.battery_busy:
            return
        self.battery_busy = True
        self.battery_text.set('正在读取…')
        def worker():
            try:
                result = battery()
            except Exception:
                logging.exception('Battery failed')
                result = '暂时读取失败'
            self.events.put(result)
        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        try:
            while True:
                driver_value=self.events.get_nowait()
                if not self.ble_batteries:self.battery_text.set(driver_value)
                self.battery_busy = False
        except queue.Empty:
            pass
        try:
            while True:
                event = self.ble.events.get_nowait()
                self.on_ble_event(event)
        except queue.Empty:
            pass
        self.after(200, self.poll)

    def close(self):
        self.ble.close()
        self.destroy()

    def send_control(self, action, value=None):
        if not self.ble_connected:
            raise RuntimeError('耳机硬件接口尚未连接，请点击重新连接')
        if self.ble_busy:
            raise RuntimeError('上一条耳机指令尚在确认中')
        self.ble_busy = True
        self.control_text.set('正在等待耳机确认…')
        for b in self.mode_buttons:
            b.configure(state='disabled')
        if self.eq_window and self.eq_window.winfo_exists():
            self.eq_apply.configure(state='disabled')
            self.eq_read.configure(state='disabled')
        self.ble.submit(action, value)

    def open_eq(self):
        if self.eq_window and self.eq_window.winfo_exists():
            self.eq_window.lift()
            return
        win = self.eq_window = tk.Toplevel(self)
        if self._test_mode:win.withdraw()
        win.title('SVANAR · 10 段硬件 EQ')
        win.configure(bg=BG)
        win.geometry('920x650')
        win.minsize(850, 600)
        self.label(win, '耳机内置 EQ', 20, ACCENT).pack(anchor='w', padx=24, pady=(20, 6))
        self.label(win, '参数直接写入耳机；不是 Windows 音量或独立播放器音效。',
                   size=10, color=DIM).pack(anchor='w', padx=24)
        self.label(win, '每段 -10 至 +10 dB。拖动仅编辑草稿，点击“应用到耳机”后才写入。',
                   size=10, color=DIM).pack(anchor='w', padx=24, pady=(4, 12))
        f = tk.Frame(win, bg=CARD, padx=10, pady=15)
        f.pack(fill='both', expand=True, padx=24, pady=10)
        for i, hz in enumerate(FREQUENCIES):
            col = tk.Frame(f, bg=CARD)
            col.grid(row=0, column=i, sticky='nsew', padx=2)
            f.columnconfigure(i, weight=1)
            text = f'{hz//1000}k' if hz >= 1000 else str(hz)
            self.label(col, text, size=10, color=ACCENT).pack()
            tk.Scale(col, from_=10, to=-10, resolution=1, variable=self.eq_values[i],
                     orient='vertical', length=240, bg=CARD, fg=FG, troughcolor=BG,
                     highlightthickness=0, activebackground=ACCENT, sliderlength=22,
                     width=15, font=('Microsoft YaHei UI', 9)).pack(expand=True)
            self.label(col, 'dB', size=9, color=DIM).pack()
        f.rowconfigure(0, weight=1)
        row = tk.Frame(win, bg=BG)
        row.pack(fill='x', padx=24, pady=6)
        preset_combo=ttk.Combobox(row,state='readonly',values=[name for name,_ in PRESETS],width=20)
        preset_combo.current(0);preset_combo.pack(side='left',padx=(0,8))
        self.button(row,'载入所选预设（仅草稿）',lambda:self.eq_draft(PRESETS[preset_combo.current()][1])).pack(side='left')
        row = tk.Frame(win, bg=BG)
        row.pack(fill='x', padx=24, pady=8)
        self.eq_apply = self.button(row, '应用到耳机',
                                   lambda: self.send_control('eq', [v.get() for v in self.eq_values]), True)
        self.eq_apply.pack(side='left')
        self.eq_read = self.button(row, '重新读取', lambda: self.send_control('read'))
        self.eq_read.pack(side='left', padx=6)
        self.button(row, '保存自定义', self.save_eq).pack(side='left')
        self.button(row, '载入自定义', self.load_eq).pack(side='left', padx=6)
        state = 'normal' if self.ble_connected and not self.ble_busy else 'disabled'
        self.eq_apply.configure(state=state)
        self.eq_read.configure(state=state)
        self.label(win, variable=self.control_text, size=9, color=DIM,
                   wraplength=850).pack(fill='x', padx=24, pady=(0,12))
        win.update_idletasks()
        height = min(win.winfo_screenheight() - 100, win.winfo_reqheight() + 20)
        win.geometry(f'1000x{max(650, height)}')

    def eq_draft(self, gains):
        for var, value in zip(self.eq_values, gains):
            var.set(value)
        self.control_text.set('EQ 草稿已修改，点击应用才会写入耳机。')

    def save_eq(self):
        path = self.data_dir / 'eq.json'
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps([v.get() for v in self.eq_values]), encoding='utf-8')
        temp.replace(path)
        self.control_text.set('自定义 EQ 已保存到电脑。')

    def load_eq(self):
        from headphone_ble import eq_payload
        path = self.data_dir / 'eq.json'
        if not path.exists():
            raise RuntimeError('尚未保存自定义 EQ')
        gains = json.loads(path.read_text(encoding='utf-8'))
        eq_payload(gains)
        self.eq_draft(gains)


def self_test():
    ds = devices()
    d = headset(ds)
    result = {'active_output_count': len(ds), 'headset_found': d is not None,
              'default_is_headset': bool(d and AudioUtilities.GetSpeakers().id == d.id)}
    if d:
        v = d.EndpointVolume
        result.update(volume=round(v.GetMasterVolumeLevelScalar()*100, 2),
                      muted=bool(v.GetMute()), channels=v.GetChannelCount())
    result['battery'] = battery()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    assert d is not None, 'SVANAR active render endpoint not found'
    return result


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        self_test()
    else:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
        app = App(start_services='--smoke-ui' not in sys.argv)
        if '--smoke-ui' in sys.argv:
            app.open_eq();app.open_library();app.open_extras()
            app.update_idletasks()
            app.after(1000, app.close)
        app.mainloop()
