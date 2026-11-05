package io.local.svanarcontrol;

import android.Manifest;
import android.app.*;
import android.bluetooth.BluetoothDevice;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import java.util.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;

public final class MainActivity extends Activity implements BleController.Listener {
    private static final int BG=0xff101719,CARD=0xff1b2629,FG=0xffeef5f1,DIM=0xff9baead,ACCENT=0xff9ce5bb;
    private LinearLayout root,results,eqPanel;
    private TextView status,modeLabel,batteryLabel,eqStatus;
    private Button apply,read,extraRead,gameOn,gameOff;
    private TextView extraLabel;
    private Extras extraInfo=new Extras();
    private final List<Button> modes=new ArrayList<>();
    private final Map<String,Button> found=new LinkedHashMap<>();
    private final SeekBar[] bands=new SeekBar[10];
    private final TextView[] gainLabels=new TextView[10];
    private BleController ble;
    private boolean connected=false,busy=false;
    private int[] readback;
    private int restoreVolume=1;
    private SharedPreferences prefs;
    private EqLibrary library=new EqLibrary();
    private Spinner favorites,touchKeys,touchActions;
    private TextView linksLabel,touchLabel,strengthLabel;
    private Button touchRead,touchWrite,touchRestore,strengthRead;
    private CheckBox linkEnabled;
    private boolean rebuilding=false,ioBusy=false;
    private String pendingExport;
    private final List<String> favoriteIds=new ArrayList<>();
    private List<TouchMap.Entry> touchEntries=new ArrayList<>();
    private final ExecutorService files=Executors.newSingleThreadExecutor();


    public void onCreate(Bundle state){
        super.onCreate(state);prefs=getSharedPreferences("svanar",MODE_PRIVATE);ble=new BleController(this,this);
        String loadError=null;
        try{String saved=prefs.getString("library_v1",null);if(saved!=null)library=EqLibrary.decode(saved);}catch(Exception e){loadError="收藏文件读取异常，原数据保留："+e.getMessage();}
        if(state!=null)pendingExport=state.getString("pending_export");
        getWindow().setStatusBarColor(BG);getWindow().setNavigationBarColor(BG);
        ScrollView scroll=new ScrollView(this);scroll.setBackgroundColor(BG);scroll.setFillViewport(true);
        root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(20),dp(18),dp(20),dp(28));scroll.addView(root);setContentView(scroll);
        root.setOnApplyWindowInsetsListener((v,insets)->{android.graphics.Insets i;
            if(Build.VERSION.SDK_INT>=30){i=insets.getInsets(WindowInsets.Type.systemBars());v.setPadding(dp(20),dp(18)+i.top,dp(20),dp(28)+i.bottom);}
            return insets;
        });
        text(root,"SVANAR",36,ACCENT);text(root,"CONTROL / Android 耳机伴侣",13,DIM);
        status=text(root,"点击扫描耳机开始；不需要 root",13,ACCENT);
        LinearLayout c=card();text(c,"HIFIMAN SVANAR WIRELESS",18,FG);
        text(c,"先在系统蓝牙设置连接耳机音频，再扫描下方控制接口。请关闭电脑端或其他手机上的耳机控制 App。",12,DIM);
        LinearLayout row=row(c);button(row,"扫描耳机",()->scan());button(row,"蓝牙设置",()->startActivity(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS)));
        results=column(c);batteryLabel=text(c,"左耳 —    右耳 —",19,ACCENT);
        row=row(c);button(row,"刷新状态",()->ble.refresh(true));button(row,"断开控制",()->ble.disconnect(true));
        c=card();text(c,"聆听模式",18,FG);modeLabel=text(c,"未连接控制接口",15,ACCENT);
        row=row(c);for(int n=0;n<3;n++){final int m=n;Button b=button(row,Protocol.MODES[n],()->ble.setMode(m));b.setEnabled(false);modes.add(b);}
        text(c,"双耳佩戴后切换；写入后查询回读一致才显示成功。",12,DIM);
        strengthRead=button(c,"检查降噪 / 通透强度能力",()->ble.readStrength());strengthRead.setEnabled(false);
        strengthLabel=text(c,"强度能力尚未读取；不会用 EQ 或音量冒充降噪强度。",12,DIM);
        c=card();text(c,"触控重映射",18,FG);
        touchRead=button(c,"读取触控映射",()->ble.readTouches());touchRead.setEnabled(false);
        LinearLayout touchPanel=disclosure(c,"展开 / 收起触控设置");
        touchLabel=text(touchPanel,"请先读取；只允许修改耳机返回的手势。",12,DIM);
        touchKeys=new Spinner(this);touchPanel.addView(touchKeys);
        touchActions=new Spinner(this);touchActions.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,TouchMap.ACTIONS));touchPanel.addView(touchActions);
        touchKeys.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int pos,long id){if(pos<touchEntries.size())touchActions.setSelection(touchEntries.get(pos).action);}});
        touchWrite=button(touchPanel,"写入所选触控",()->confirmTouch());touchWrite.setEnabled(false);
        touchRestore=button(touchPanel,"恢复首次修改前的触控备份",()->new AlertDialog.Builder(this).setTitle("恢复此耳机的触控备份？").setMessage("会恢复首次修改前保存的全部触控映射，并逐项回读确认。").setNegativeButton("取消",null).setPositiveButton("恢复",(d,w)->ble.restoreTouches()).show());touchRestore.setEnabled(false);
        text(touchPanel,"写入前按耳机身份保存原映射。通话动作会影响接听／挂断，请按实际使用选择。",12,DIM);
        c=card();text(c,"扩展功能 / 编码诊断",18,FG);
        extraRead=button(c,"读取扩展信息",()->ble.readExtras());extraRead.setEnabled(false);
        extraLabel=text(c,"读取耳机能力后显示固件、编码与游戏模式。未确认支持的功能保持禁用。",12,DIM);
        extraLabel.setVisibility(View.GONE);button(c,"展开 / 收起诊断",()->extraLabel.setVisibility(extraLabel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE));
        row=row(c);gameOn=button(row,"开启游戏模式",()->ble.setGame(true));gameOff=button(row,"关闭游戏模式",()->ble.setGame(false));
        gameOn.setEnabled(false);gameOff.setEnabled(false);
        button(c,"复制诊断信息",()->{((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("SVANAR 诊断",extraInfo.describe()));status("已复制最近一次耳机回读诊断");});
        text(c,"游戏模式可能影响音质；这里只显示耳机报告，手机实际协商编码请在系统蓝牙设置查看。不会将 AAC 标成 LDAC。",12,DIM);
        c=card();text(c,"10 段耳机内置 EQ",18,FG);text(c,"每段 ±10 dB。滑块和预设仅编辑草稿，点击应用后才写入耳机。",12,DIM);
        button(c,"展开 / 收起 EQ",()->eqPanel.setVisibility(eqPanel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE));
        eqPanel=column(c);eqPanel.setVisibility(View.GONE);
        text(eqPanel,"14 组通用调音预设（非测量校准）",13,ACCENT);
        Spinner presets=new Spinner(this);ArrayAdapter<String> adapter=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,Presets.NAMES);presets.setAdapter(adapter);eqPanel.addView(presets);
        button(eqPanel,"载入所选预设（仅草稿）",()->draft(Presets.GAINS[presets.getSelectedItemPosition()]));
        for(int n=0;n<10;n++){
            final int index=n;row=row(eqPanel);int hz=Protocol.FREQUENCIES[n];text(row,hz>=1000?(hz/1000)+" kHz":hz+" Hz",14,DIM);
            gainLabels[n]=text(row,"0 dB",14,ACCENT);
            SeekBar s=bands[n]=new SeekBar(this);s.setMax(20);s.setProgress(10);eqPanel.addView(s,new LinearLayout.LayoutParams(-1,dp(44)));
            s.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
                public void onProgressChanged(SeekBar bar,int p,boolean user){gainLabels[index].setText(String.format(Locale.US,"%+d dB",p-10));if(user)eqStatus.setText("EQ 草稿已修改，尚未写入耳机");}
                public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){}
            });s.setContentDescription(hz+" Hz EQ");
        }
        row=row(eqPanel);apply=button(row,"应用到耳机",()->ble.setEQ(values()));read=button(row,"重新读取",()->ble.refresh(true));
        row=row(eqPanel);button(row,"保存自定义",()->save());button(row,"载入自定义",()->load());
        eqStatus=text(eqPanel,"等待耳机回读 EQ",12,DIM);apply.setEnabled(false);read.setEnabled(false);
        c=card();text(c,"EQ 收藏 / 文件 / 模式联动",18,FG);
        LinearLayout libraryPanel=disclosure(c,"展开 / 收起收藏与联动");
        text(libraryPanel,"收藏保存当前滑块草稿；载入、导入和绑定不会立即写耳机。文件选择器会断开控制，返回后重新连接即可。",12,DIM);
        favorites=new Spinner(this);libraryPanel.addView(favorites);
        row=row(libraryPanel);button(row,"另存为收藏",()->nameProfile(false));button(row,"载入收藏草稿",()->{EqLibrary.Profile p=selectedProfile();if(p!=null)draft(p.values());});
        row=row(libraryPanel);button(row,"覆盖所选收藏",()->overwriteProfile());button(row,"重命名收藏",()->nameProfile(true));
        button(libraryPanel,"删除所选收藏",()->deleteProfile());
        row=row(libraryPanel);button(row,"导出 EQ 文件",()->exportLibrary());button(row,"导入 EQ 文件",()->importLibrary());
        linksLabel=text(libraryPanel,"",13,ACCENT);
        row=row(libraryPanel);for(int i=0;i<3;i++){final int mode=i;button(row,"绑定 "+Protocol.MODES[i],()->bindProfile(mode));}
        button(libraryPanel,"清空模式绑定",()->{EqLibrary n=library.copy();Arrays.fill(n.links,null);storeLibrary(n,false);});
        linkEnabled=new CheckBox(this);linkEnabled.setText("模式变化时应用绑定 EQ（前台连接期间）");linkEnabled.setTextColor(FG);libraryPanel.addView(linkEnabled);
        linkEnabled.setChecked(prefs.getBoolean("auto_link",false));
        linkEnabled.setOnCheckedChangeListener((b,active)->{if(rebuilding)return;if(!prefs.edit().putBoolean("auto_link",active).commit()){rebuilding=true;b.setChecked(!active);rebuilding=false;status("联动开关保存失败");return;}syncLinks();status(active?"模式联动已启用；首次连接只读，后续模式变化才应用":"模式联动已关闭");});
        text(libraryPanel,"开启后，App 切换模式和耳机手动切换模式均会联动；按回读确认。首次连接不自动改 EQ，未绑定模式不改 EQ。",12,DIM);
        refreshLibrary();syncLinks();
        c=card();text(c,"媒体音量",18,FG);AudioManager audio=(AudioManager)getSystemService(AUDIO_SERVICE);
        SeekBar volume=new SeekBar(this);volume.setMax(audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));volume.setProgress(audio.getStreamVolume(AudioManager.STREAM_MUSIC));c.addView(volume);
        volume.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar b,int p,boolean user){if(user)audio.setStreamVolume(AudioManager.STREAM_MUSIC,p,0);}
            public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){}
        });
        button(c,"静音 / 恢复",()->{int current=audio.getStreamVolume(AudioManager.STREAM_MUSIC);if(current>0){restoreVolume=current;audio.setStreamVolume(AudioManager.STREAM_MUSIC,0,0);}else audio.setStreamVolume(AudioManager.STREAM_MUSIC,Math.min(restoreVolume,volume.getMax()),0);volume.setProgress(audio.getStreamVolume(AudioManager.STREAM_MUSIC));});
        text(c,"音量作用于系统媒体输出。音频路由由 Android 管理。",12,DIM);
        if(loadError!=null)status(loadError);
        files.execute(()->{try{EqLibrary.selfTest();android.util.Log.i("SvanarLibrary","PASS: JSON roundtrip, malformed/range/fraction/version rejection, collision merge, dangling link removal");}catch(Throwable e){android.util.Log.e("SvanarLibrary","SELFTEST FAILED",e);}});
        text(root,"SVANAR Control 1.3 · 非官方应用\n仅本地蓝牙通信，无互联网权限；切到后台会断开控制，耳机音频连接不受此操作影响。",11,DIM);
    }
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private TextView text(LinearLayout parent,String value,int size,int color){TextView t=new TextView(this);t.setText(value);t.setTextColor(color);t.setTextSize(size);t.setPadding(0,dp(5),0,dp(5));parent.addView(t);return t;}
    private LinearLayout column(LinearLayout parent){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.VERTICAL);parent.addView(l,new LinearLayout.LayoutParams(-1,-2));return l;}
    private LinearLayout disclosure(LinearLayout parent,String title){LinearLayout panel=new LinearLayout(this);panel.setOrientation(LinearLayout.VERTICAL);panel.setVisibility(View.GONE);button(parent,title,()->panel.setVisibility(panel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE));parent.addView(panel,new LinearLayout.LayoutParams(-1,-2));return panel;}
    private LinearLayout row(LinearLayout parent){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);parent.addView(l,new LinearLayout.LayoutParams(-1,-2));return l;}
    private LinearLayout card(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.VERTICAL);l.setPadding(dp(16),dp(12),dp(16),dp(12));GradientDrawable d=new GradientDrawable();d.setColor(CARD);d.setCornerRadius(dp(18));l.setBackground(d);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.topMargin=dp(16);root.addView(l,p);return l;}
    private Button button(LinearLayout parent,String title,Runnable action){Button b=new Button(this);b.setText(title);b.setTextSize(13);b.setTextColor(ACCENT);b.setAllCaps(false);b.setOnClickListener(v->{try{action.run();}catch(Exception e){status("操作未完成："+e.getMessage());}});LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(parent.getOrientation()==LinearLayout.HORIZONTAL?0:-1,dp(52));if(parent.getOrientation()==LinearLayout.HORIZONTAL)p.weight=1;parent.addView(b,p);return b;}
    private void scan(){
        List<String> needed=new ArrayList<>();
        String[] required=Build.VERSION.SDK_INT>=31?new String[]{Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT}:new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
        for(String p:required)if(checkSelfPermission(p)!=PackageManager.PERMISSION_GRANTED)needed.add(p);
        if(!needed.isEmpty()){requestPermissions(needed.toArray(new String[0]),40);return;}
        found.clear();results.removeAllViews();ble.scan();
    }
    public void onRequestPermissionsResult(int request,String[] permissions,int[] grants){super.onRequestPermissionsResult(request,permissions,grants);if(request==40){for(int g:grants)if(g!=PackageManager.PERMISSION_GRANTED){status("蓝牙扫描权限尚未授予，可到系统设置中开启");return;}if(grants.length>0)scan();}}
    public void status(String text){if(status!=null)status.setText(text);}
    public void device(BluetoothDevice device,String identity,int rssi){
        if(found.containsKey(identity))return;
        Button b=button(results,"连接 SVANAR · "+identity.substring(identity.length()-5)+" · "+rssi+" dBm",()->ble.connect(device,identity));found.put(identity,b);
    }
    public void state(boolean ready,boolean busy){connected=ready;this.busy=busy;for(Button b:modes)b.setEnabled(ready&&!busy);apply.setEnabled(ready&&!busy);read.setEnabled(ready&&!busy);for(SeekBar b:bands)b.setEnabled(!busy);extraRead.setEnabled(ready&&!busy);touchRead.setEnabled(ready&&!busy);strengthRead.setEnabled(ready&&!busy);touchWrite.setEnabled(ready&&!busy&&!touchEntries.isEmpty());touchRestore.setEnabled(ready&&!busy&&!touchEntries.isEmpty());updateExtraButtons();}
    private void updateExtraButtons(){boolean enabled=connected&&!busy&&Boolean.TRUE.equals(extraInfo.gameSupported)&&extraInfo.game!=null;gameOn.setEnabled(enabled);gameOff.setEnabled(enabled);}
    public void extras(Extras info){extraInfo=info;if(extraLabel!=null){extraLabel.setText(info.describe());strengthLabel.setText(info.strengthReport());updateExtraButtons();}}
    public void snapshot(Integer mode,int[] eq,Integer left,Integer right){
        if(mode!=null)modeLabel.setText("当前模式："+Protocol.MODES[mode]+" · 耳机回读");
        if(!connected){modeLabel.setText("未连接控制接口");batteryLabel.setText("左耳 —    右耳 —");readback=null;return;}
        if(eq!=null){readback=eq.clone();draft(eq);eqStatus.setText("草稿与最近一次耳机回读一致");}
        if(left!=null||right!=null)batteryLabel.setText("左耳 "+(left==null?"—":left+"%")+"    右耳 "+(right==null?"—":right+"%"));
    }
    public void touchUnavailable(String reason){touchLabel.setText(reason);touchWrite.setEnabled(false);touchRestore.setEnabled(false);}
    public void touches(TouchMap info){
        touchEntries=info==null?new ArrayList<>():info.list();
        String[] names=new String[touchEntries.size()];for(int i=0;i<names.length;i++)names[i]=touchEntries.get(i).name();
        touchKeys.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,names));
        if(!touchEntries.isEmpty())touchActions.setSelection(touchEntries.get(0).action);
        touchLabel.setText(info==null?"控制断开后需重新读取触控映射。":info.describe());
        touchWrite.setEnabled(connected&&!busy&&info!=null);touchRestore.setEnabled(connected&&!busy&&info!=null);
    }
    private void confirmTouch(){
        int index=touchKeys.getSelectedItemPosition();if(index<0||index>=touchEntries.size()){status("请先读取触控映射");return;}
        TouchMap.Entry e=touchEntries.get(index);int action=touchActions.getSelectedItemPosition();
        new AlertDialog.Builder(this).setTitle("写入触控映射？").setMessage(e.name()+" → "+TouchMap.ACTIONS[action]+"\n写入前会保存此耳机的原映射，写入后查询回读。").setNegativeButton("取消",null).setPositiveButton("确认写入",(d,w)->ble.setTouch(e.ear,e.gesture,action)).show();
    }
    private EqLibrary.Profile selectedProfile(){int i=favorites.getSelectedItemPosition();if(i<0||i>=favoriteIds.size()){status("请先另存一套 EQ 收藏");return null;}return library.profiles.get(favoriteIds.get(i));}
    private void refreshLibrary(){
        String selected=null;int pos=favorites.getSelectedItemPosition();if(pos>=0&&pos<favoriteIds.size())selected=favoriteIds.get(pos);
        favoriteIds.clear();favoriteIds.addAll(library.profiles.keySet());List<String> names=new ArrayList<>();Map<String,Integer> counts=new HashMap<>();for(EqLibrary.Profile p:library.profiles.values())counts.put(p.name,counts.containsKey(p.name)?counts.get(p.name)+1:1);for(String id:favoriteIds){String name=library.profiles.get(id).name;names.add(counts.get(name)>1?name+" · "+id.substring(0,Math.min(6,id.length())):name);}
        favorites.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,names));if(selected!=null&&favoriteIds.contains(selected))favorites.setSelection(favoriteIds.indexOf(selected));
        StringBuilder b=new StringBuilder();for(int i=0;i<3;i++){EqLibrary.Profile p=library.profiles.get(library.links[i]);b.append(Protocol.MODES[i]).append(" → ").append(p==null?"未绑定":p.name).append('\n');}linksLabel.setText(b.toString());
    }
    private void syncLinks(){ble.setModeLinks(linkEnabled.isChecked(),library.gainsForLinks());}
    private boolean storeLibrary(EqLibrary candidate,boolean disableAuto){
        try{
            String encoded=candidate.encode();if(encoded.getBytes(StandardCharsets.UTF_8).length>EqLibrary.MAX_BYTES)throw new IllegalArgumentException("收藏库超过 64 KiB");
            SharedPreferences.Editor edit=prefs.edit().putString("library_v1",encoded);if(disableAuto)edit.putBoolean("auto_link",false);
            if(!edit.commit())throw new IOException("保存失败，原收藏未覆盖");library=candidate;
            if(disableAuto){rebuilding=true;linkEnabled.setChecked(false);rebuilding=false;}
            refreshLibrary();syncLinks();android.util.Log.i("SvanarLibrary","STORED profiles="+library.profiles.size()+" auto="+linkEnabled.isChecked());return true;
        }catch(Exception e){status("收藏操作未完成："+e.getMessage());return false;}
    }
    private void nameProfile(boolean rename){
        EqLibrary.Profile existing=rename?selectedProfile():null;if(rename&&existing==null)return;
        EditText name=new EditText(this);name.setSingleLine(true);name.setHint("收藏名称（1–40 字）");if(existing!=null)name.setText(existing.name);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle(rename?"重命名收藏":"保存当前 EQ 草稿为收藏").setView(name).setNegativeButton("取消",null).setPositiveButton("保存",null).create();
        dialog.setOnShowListener(d->dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{try{
            String id=existing==null?UUID.randomUUID().toString():existing.id;EqLibrary.Profile p=new EqLibrary.Profile(id,name.getText().toString(),existing==null?values():existing.values());EqLibrary n=library.copy();n.add(p);
            if(storeLibrary(n,false)){favorites.setSelection(favoriteIds.indexOf(id));status(rename?"收藏已重命名":"EQ 草稿已保存为收藏，未写入耳机");dialog.dismiss();}
        }catch(Exception e){name.setError(e.getMessage());}}));dialog.show();
    }
    private void overwriteProfile(){EqLibrary.Profile p=selectedProfile();if(p==null)return;new AlertDialog.Builder(this).setTitle("用当前草稿覆盖收藏？").setMessage(p.name+"；绑定此收藏的模式也将使用新曲线。").setNegativeButton("取消",null).setPositiveButton("覆盖",(d,w)->{EqLibrary n=library.copy();n.add(new EqLibrary.Profile(p.id,p.name,values()));if(storeLibrary(n,false))status("收藏已更新；当前耳机 EQ 未改动");}).show();}
    private void deleteProfile(){EqLibrary.Profile p=selectedProfile();if(p==null)return;new AlertDialog.Builder(this).setTitle("删除收藏？").setMessage(p.name+"；相关模式绑定会一并清除。").setNegativeButton("取消",null).setPositiveButton("删除",(d,w)->{EqLibrary n=library.copy();n.remove(p.id);if(storeLibrary(n,false))status("收藏及相关绑定已删除");}).show();}
    private void bindProfile(int mode){EqLibrary.Profile p=selectedProfile();if(p==null)return;EqLibrary n=library.copy();n.links[mode]=p.id;if(storeLibrary(n,false))status(Protocol.MODES[mode]+" 已绑定 "+p.name+"，尚未写入耳机");}
    private void exportLibrary(){
        if(ioBusy)return;try{pendingExport=library.encode();Intent i=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json").putExtra(Intent.EXTRA_TITLE,"svanar-eq-backup.json");startActivityForResult(i,71);ioBusy=true;}catch(Exception e){pendingExport=null;status("导出未启动："+e.getMessage());}
    }
    private void importLibrary(){if(ioBusy)return;try{Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");startActivityForResult(i,72);ioBusy=true;}catch(Exception e){status("导入未启动："+e.getMessage());}}
    private void onMain(Runnable work){runOnUiThread(()->{if(!isFinishing()&&!isDestroyed())work.run();});}
    protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);if(request!=71&&request!=72)return;
        if(result!=RESULT_OK||data==null||data.getData()==null){ioBusy=false;pendingExport=null;status("文件操作已取消");return;}
        final android.net.Uri uri=data.getData();final String exported=pendingExport;pendingExport=null;
        files.execute(()->{try{
            if(request==71){if(exported==null)throw new IOException("导出快照丢失，请重新导出");try(OutputStream out=getContentResolver().openOutputStream(uri,"w")){if(out==null)throw new IOException("文件尚未打开");out.write(exported.getBytes(StandardCharsets.UTF_8));}onMain(()->status("EQ 收藏及模式绑定已导出；返回后可重新连接耳机"));}
            else{
                byte[] bytes;try(InputStream in=getContentResolver().openInputStream(uri);ByteArrayOutputStream out=new ByteArrayOutputStream()){
                    if(in==null)throw new IOException("文件尚未打开");byte[] buf=new byte[4096];int count;while((count=in.read(buf))!=-1){if(out.size()+count>EqLibrary.MAX_BYTES)throw new IOException("文件超过 64 KiB");out.write(buf,0,count);}bytes=out.toByteArray();}
                String text=StandardCharsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString();final EqLibrary imported=EqLibrary.decode(text);
                onMain(()->new AlertDialog.Builder(this).setTitle("导入 "+imported.profiles.size()+" 套 EQ 收藏？").setMessage("合并收藏，不覆盖同 ID 的不同内容；文件中的模式绑定会合入，自动联动会关闭。不会修改耳机 EQ。").setNegativeButton("取消",null).setPositiveButton("确认导入",(d,w)->{try{if(storeLibrary(library.merge(imported),true))status("EQ 文件已导入，自动联动关闭；当前耳机未改动");}catch(Exception e){status("导入未完成："+e.getMessage());}}).show());
            }
        }catch(Exception e){android.util.Log.w("SvanarLibrary","FILE_REJECTED "+e.getMessage());onMain(()->status("文件操作未完成："+e.getMessage()+"；原收藏保留"));}finally{onMain(()->ioBusy=false);}});
    }
    protected void onSaveInstanceState(Bundle out){super.onSaveInstanceState(out);if(pendingExport!=null)out.putString("pending_export",pendingExport);}
    private int[] values(){int[] g=new int[10];for(int i=0;i<10;i++)g[i]=bands[i].getProgress()-10;return g;}
    private void draft(int[] gains){for(int i=0;i<10;i++)bands[i].setProgress(gains[i]+10);if(eqStatus!=null)eqStatus.setText("草稿已更新，点击应用后写入");}
    private void save(){int[] g=values();StringBuilder s=new StringBuilder();for(int v:g){if(s.length()>0)s.append(',');s.append(v);}prefs.edit().putString("eq",s.toString()).apply();status("自定义 EQ 已保存到手机");}
    private void load(){String s=prefs.getString("eq","");String[] p=s.split(",");if(p.length!=10){status("尚未保存自定义 EQ");return;}try{int[] g=new int[10];for(int i=0;i<10;i++)g[i]=Integer.parseInt(p[i]);Protocol.eq(g);draft(g);}catch(Exception e){status("EQ 保存数据无效");}}
    protected void onStop(){super.onStop();ble.disconnect(true);}
    protected void onDestroy(){ble.close();files.shutdown();super.onDestroy();}
}
