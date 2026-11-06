"""Windows-native companion panels. Hardware writes go only through Bridge."""
import copy
from pathlib import Path
import tkinter as tk
from tkinter import ttk,filedialog,simpledialog,messagebox
import eq_library as eq
from device_features import Features,ACTIONS,touch_name

BG,CARD,FG,DIM,ACCENT='#101719','#1b2629','#eef5f1','#9baead','#9ce5bb'

class CompanionMixin:
    def init_companion(self):
        self.store=eq.Store(self.data_dir/'profiles.json');self.features=Features();self.touch_map={}
        self.library_window=None;self.extras_window=None;self.profile_ids=[];self.touch_ids=[]
        self.link_active=tk.BooleanVar(self,value=self.store.enabled)
        self.touch_message=tk.StringVar(self,value='先读取触控映射；只开放耳机实际返回的手势。')
        self.ble_batteries=None

    def sync_links(self):self.ble.set_links(self.store.enabled,self.store.mode_links())

    def _message(self,text):self.control_text.set(text);self.notice.set(text)

    def _popup(self,title,width=850,height=720):
        win=tk.Toplevel(self)
        if self._test_mode:win.withdraw()
        win.title(title);win.configure(bg=BG)
        win.geometry(f'{min(width,win.winfo_screenwidth()-80)}x{min(height,win.winfo_screenheight()-100)}')
        canvas=tk.Canvas(win,bg=BG,highlightthickness=0);bar=ttk.Scrollbar(win,orient='vertical',command=canvas.yview)
        bar.pack(side='right',fill='y');canvas.pack(side='left',fill='both',expand=True);canvas.configure(yscrollcommand=bar.set)
        body=tk.Frame(canvas,bg=BG,padx=20,pady=16);item=canvas.create_window((0,0),window=body,anchor='nw')
        body.bind('<Configure>',lambda e:canvas.configure(scrollregion=canvas.bbox('all')))
        canvas.bind('<Configure>',lambda e:canvas.itemconfigure(item,width=e.width))
        def wheel(e):
            if not isinstance(e.widget,(tk.Scale,ttk.Combobox)):canvas.yview_scroll(-int(e.delta/120),'units')
        win.bind('<MouseWheel>',wheel)
        return win,body

    def _row(self,parent):
        row=tk.Frame(parent,bg=parent['bg']);row.pack(fill='x',pady=5);return row

    def open_library(self):
        if self.library_window and self.library_window.winfo_exists():self.library_window.lift();return
        win,body=self._popup('SVANAR 1.3 · EQ 收藏、文件与模式联动',860,760);self.library_window=win
        self.label(body,'EQ 收藏与联动',19,ACCENT).pack(anchor='w')
        self.label(body,'保存／载入／导入和绑定仅改本机配置，不会立即写耳机。',10,DIM,wraplength=720,justify='left').pack(anchor='w',pady=8)
        self.profile_combo=ttk.Combobox(body,state='readonly');self.profile_combo.pack(fill='x',pady=8)
        row=self._row(body)
        for title,fn in [('另存为收藏',self.new_profile),('载入收藏草稿',self.load_profile),('覆盖所选收藏',self.overwrite_profile)]:self.button(row,title,fn).pack(side='left',padx=(0,8))
        row=self._row(body)
        self.button(row,'重命名收藏',self.rename_profile).pack(side='left');self.button(row,'删除所选收藏',self.delete_profile).pack(side='left',padx=8)
        row=self._row(body)
        self.button(row,'导出 EQ 文件',self.export_library,True).pack(side='left');self.button(row,'导入 EQ 文件',self.import_library).pack(side='left',padx=8)
        self.label(body,'模式绑定',15,ACCENT).pack(anchor='w',pady=(18,8));self.link_combos={}
        for mode,label in ((0,'HiFi'),(1,'降噪'),(2,'通透')):
            row=self._row(body);self.label(row,label,11).pack(side='left',padx=(0,12))
            combo=ttk.Combobox(row,state='readonly');combo.pack(side='left',fill='x',expand=True)
            combo.bind('<<ComboboxSelected>>',lambda e,m=mode:self.safe(lambda:self.bind_profile(m)))
            self.link_combos[mode]=combo
        tk.Checkbutton(body,text='模式变化时应用绑定 EQ（控制连接期间）',variable=self.link_active,command=lambda:self.safe(self.toggle_links),bg=BG,fg=FG,selectcolor=CARD,activebackground=BG,activeforeground=ACCENT,font=('Microsoft YaHei UI',11)).pack(anchor='w',pady=12)
        self.label(body,'默认关闭；首次连接只读取，未绑定的模式不改 EQ。App 切换和耳机模式变化会查询确认后联动；约每 5 秒检测一次。',10,DIM,wraplength=720,justify='left').pack(anchor='w')
        self.label(body,variable=self.control_text,size=10,color=ACCENT,wraplength=720,justify='left').pack(fill='x',pady=15)
        self.refresh_library()

    def refresh_library(self,selected=None):
        if not(self.library_window and self.library_window.winfo_exists()):return
        old=self.profile_combo.current()
        if selected is None and 0<=old<len(self.profile_ids):selected=self.profile_ids[old]
        profiles=self.store.library['profiles'];self.profile_ids=[p['id'] for p in profiles]
        counts={p['name']:sum(q['name']==p['name'] for q in profiles) for p in profiles}
        labels=[p['name']+((' · '+p['id'][:6]) if counts[p['name']]>1 else '') for p in profiles]
        self.profile_combo.configure(values=labels)
        if self.profile_ids:self.profile_combo.current(self.profile_ids.index(selected) if selected in self.profile_ids else 0)
        else:self.profile_combo.set('')
        for mode,combo in self.link_combos.items():
            combo.configure(values=['未绑定']+labels);pid=self.store.library['links'].get(str(mode));combo.current(self.profile_ids.index(pid)+1 if pid in self.profile_ids else 0)
        self.link_active.set(self.store.enabled)

    def selected_profile(self):
        i=self.profile_combo.current()
        if not 0<=i<len(self.profile_ids):raise ValueError('请先保存或选择收藏')
        return next(p for p in self.store.library['profiles'] if p['id']==self.profile_ids[i])

    def _save_library(self,value,enabled=None,selected=None):
        self.store.save(value,enabled);self.sync_links();self.refresh_library(selected)

    def new_profile(self):
        name=simpledialog.askstring('另存为 EQ 收藏','名称（1–40 字）：',parent=self.library_window)
        if name is None:return
        library,pid=eq.add(self.store.library,name,[v.get() for v in self.eq_values]);self._save_library(library,selected=pid);self._message('当前 EQ 草稿已保存为收藏，未写入耳机。')

    def load_profile(self):self.eq_draft(self.selected_profile()['gains'])

    def overwrite_profile(self):
        p=self.selected_profile()
        if messagebox.askyesno('覆盖收藏',f'用当前草稿覆盖“{p["name"]}”？相关绑定会使用新曲线。',parent=self.library_window):
            library,pid=eq.add(self.store.library,p['name'],[v.get() for v in self.eq_values],p['id']);self._save_library(library,selected=pid);self._message('收藏已更新，当前耳机 EQ 未改动。')

    def rename_profile(self):
        p=self.selected_profile();name=simpledialog.askstring('重命名收藏','名称（1–40 字）：',initialvalue=p['name'],parent=self.library_window)
        if name is not None:
            library,pid=eq.add(self.store.library,name,p['gains'],p['id']);self._save_library(library,selected=pid);self._message('收藏已重命名。')

    def delete_profile(self):
        p=self.selected_profile()
        if messagebox.askyesno('删除收藏',f'删除“{p["name"]}”及相关绑定？',parent=self.library_window):self._save_library(eq.remove(self.store.library,p['id']));self._message('收藏及相关模式绑定已删除。')

    def export_library(self):
        data=eq.encode(self.store.library)
        path=filedialog.asksaveasfilename(parent=self.library_window,title='导出 EQ 收藏和模式绑定',initialfile='svanar-eq-backup.json',defaultextension='.json',filetypes=[('SVANAR EQ JSON','*.json')],confirmoverwrite=True)
        if not path:return
        if Path(path).resolve()==self.store.path.resolve():raise ValueError('请选择不同于本机配置文件的导出路径')
        eq.atomic_write(path,data);self._message('EQ 文件已导出；兼容 Android / iOS v1.3。')

    def import_library(self):
        path=filedialog.askopenfilename(parent=self.library_window,title='导入 SVANAR EQ JSON',filetypes=[('SVANAR EQ JSON','*.json'),('全部文件','*.*')])
        if not path:return
        with open(path,'rb') as f:incoming=eq.decode(f.read(eq.MAX_BYTES+1))
        merged=eq.merge(self.store.library,incoming)
        if messagebox.askyesno('导入 EQ 收藏',f'导入 {len(incoming["profiles"])} 套收藏并合入模式绑定？\n同 ID 不同内容会保留为新收藏；自动联动关闭，不立即改耳机。',parent=self.library_window):
            self._save_library(merged,enabled=False);self._message('收藏已导入，自动联动关闭；耳机配置未改动。')

    def bind_profile(self,mode):
        i=self.link_combos[mode].current();library=copy.deepcopy(self.store.library)
        if i==0:library['links'].pop(str(mode),None)
        elif 0<i<=len(self.profile_ids):library['links'][str(mode)]=self.profile_ids[i-1]
        else:return
        self._save_library(library);self._message('模式绑定已保存，未立即写入耳机。')

    def toggle_links(self):
        try:self._save_library(self.store.library,enabled=self.link_active.get())
        except Exception:self.link_active.set(self.store.enabled);raise
        self._message('模式联动已'+('开启；首次连接仍只读。' if self.store.enabled else '关闭。'))

    def open_extras(self):
        if self.extras_window and self.extras_window.winfo_exists():self.extras_window.lift();return
        win,body=self._popup('SVANAR 1.3 · 游戏、诊断与触控',880,780);self.extras_window=win
        self.label(body,'扩展功能',19,ACCENT).pack(anchor='w')
        row=self._row(body);self.extra_read=self.button(row,'读取扩展信息',lambda:self.send_control('extras'));self.extra_read.pack(side='left')
        self.strength_read=self.button(row,'检查降噪 / 通透强度',lambda:self.send_control('strength'));self.strength_read.pack(side='left',padx=8)
        row=self._row(body);self.game_on=self.button(row,'开启游戏模式',lambda:self.send_control('game',True));self.game_on.pack(side='left');self.game_off=self.button(row,'关闭游戏模式',lambda:self.send_control('game',False));self.game_off.pack(side='left',padx=8)
        self.diagnostic=tk.Text(body,height=12,bg=CARD,fg=FG,relief='flat',wrap='word',font=('Microsoft YaHei UI',10));self.diagnostic.pack(fill='x',pady=8)
        self.button(body,'复制诊断信息',self.copy_diagnostics).pack(anchor='w')
        self.label(body,'触控重映射',15,ACCENT).pack(anchor='w',pady=(20,8))
        self.touch_read=self.button(body,'读取触控映射',lambda:self.send_control('touch_read'));self.touch_read.pack(anchor='w')
        self.label(body,variable=self.touch_message,size=10,color=DIM,wraplength=750,justify='left').pack(fill='x',pady=8)
        self.touch_combo=ttk.Combobox(body,state='readonly');self.touch_combo.pack(fill='x',pady=4);self.touch_combo.bind('<<ComboboxSelected>>',lambda e:self.choose_touch())
        self.action_combo=ttk.Combobox(body,state='readonly',values=ACTIONS);self.action_combo.current(0);self.action_combo.pack(fill='x',pady=4)
        row=self._row(body);self.touch_write=self.button(row,'写入所选触控',self.write_touch);self.touch_write.pack(side='left');self.touch_restore=self.button(row,'恢复原触控备份',self.restore_touch);self.touch_restore.pack(side='left',padx=8)
        self.label(body,'当前 S050 曾两次未回应触控查询，写入未开放；灵敏度及强度尚无可用接口。此程序不含固件刷写。',10,DIM,wraplength=750,justify='left').pack(fill='x',pady=10)
        self.label(body,variable=self.control_text,size=10,color=ACCENT,wraplength=750,justify='left').pack(fill='x',pady=8)
        self.render_features();self.render_touches();self.update_control_buttons()

    def render_features(self):
        if self.extras_window and self.extras_window.winfo_exists():
            self.diagnostic.configure(state='normal');self.diagnostic.delete('1.0','end');self.diagnostic.insert('1.0',self.features.describe());self.diagnostic.configure(state='disabled')

    def copy_diagnostics(self):self.clipboard_clear();self.clipboard_append(self.features.describe());self._message('耳机诊断已复制。')

    def render_touches(self):
        if not(self.extras_window and self.extras_window.winfo_exists()):return
        self.touch_ids=list(self.touch_map);self.touch_combo.configure(values=[touch_name(self.touch_map[i]) for i in self.touch_ids])
        if self.touch_ids:self.touch_combo.current(0);self.choose_touch()
        else:self.touch_combo.set('')

    def choose_touch(self):
        i=self.touch_combo.current()
        if 0<=i<len(self.touch_ids):self.action_combo.current(self.touch_map[self.touch_ids[i]][2])

    def write_touch(self):
        i=self.touch_combo.current()
        if not 0<=i<len(self.touch_ids):raise ValueError('先读取有效触控映射')
        old=self.touch_map[self.touch_ids[i]];action=self.action_combo.current()
        if messagebox.askyesno('写入触控',touch_name(old)+' → '+ACTIONS[action]+'\n首次修改前会保存备份，写入后检查回读。',parent=self.extras_window):self.send_control('touch_set',(old[0],old[1],action))

    def restore_touch(self):
        if messagebox.askyesno('恢复原映射','恢复首次修改前按本耳机身份保存的全部触控映射？',parent=self.extras_window):self.send_control('touch_restore')

    def update_control_buttons(self):
        state='normal' if self.ble_connected and not self.ble_busy else 'disabled'
        for b in self.mode_buttons:b.configure(state=state)
        if self.eq_window and self.eq_window.winfo_exists():self.eq_apply.configure(state=state);self.eq_read.configure(state=state)
        if self.extras_window and self.extras_window.winfo_exists():
            for b in (self.extra_read,self.strength_read,self.touch_read):b.configure(state=state)
            game=state if self.features.game_supported is True and self.features.game is not None else 'disabled'
            self.game_on.configure(state=game);self.game_off.configure(state=game)
            touch=state if self.touch_map else 'disabled';self.touch_write.configure(state=touch);self.touch_restore.configure(state=touch)

    def on_ble_event(self,event):
        self.ble_connected=bool(event.get('connected',self.ble_connected))
        if not self.ble_connected:
            self.ble_busy=False;self.mode_text.set('当前模式：未连接控制接口');self.features=Features();self.touch_map={};self.ble_batteries=None;self.render_features();self.render_touches()
        elif 'busy' in event:self.ble_busy=event['busy']
        if event.get('done'):self.ble_busy=False
        if 'mode' in event:self.mode_text.set('当前模式：'+{0:'HiFi',1:'降噪',2:'通透'}[event['mode']]+' · 耳机回读')
        if 'eq' in event:
            self.eq_readback=list(event['eq'])
            for var,value in zip(self.eq_values,event['eq']):var.set(value)
        if 'features' in event:self.features=Features(event['features']);self.render_features()
        if 'touches' in event:self.touch_map=event['touches'];self.touch_message.set('触控映射已读取；首次修改前备份，写入后回读。');self.render_touches()
        if event.get('touch_error'):self.touch_map={};self.touch_message.set(event['touch_error']);self.render_touches()
        if 'left' in event or 'right' in event:
            self.ble_batteries='左耳 '+(str(event['left'])+'%' if event.get('left') is not None else '—')+' / 右耳 '+(str(event['right'])+'%' if event.get('right') is not None else '—')
            self.battery_text.set(self.ble_batteries)
        if 'message' in event:self.control_text.set(event['message'])
        self.update_control_buttons()
