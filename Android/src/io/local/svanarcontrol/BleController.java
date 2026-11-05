package io.local.svanarcontrol;

import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Context;
import android.os.*;
import java.util.*;
import java.util.concurrent.*;

@SuppressWarnings({"deprecation","MissingPermission"})
public final class BleController {
    public interface Listener {
        void status(String text);
        void device(BluetoothDevice d,String identity,int rssi);
        void state(boolean ready,boolean busy);
        void snapshot(Integer mode,int[] eq,Integer left,Integer right);
        void extras(Extras info);
        void touches(TouchMap info);
        void touchUnavailable(String reason);
    }
    private static final boolean TRACE_WIRE=false;
    private static UUID uuid(String shortId){return UUID.fromString("0000"+shortId+"-0000-1000-8000-00805f9b34fb");}
    private static final UUID SERVICE=uuid("ff77"),TX=uuid("ff88"),RX=uuid("ff99"),CCCD=uuid("2902");
    private final Context context;
    private final Listener listener;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final BlockingQueue<byte[]> replies=new LinkedBlockingQueue<>();
    private final BlockingQueue<Integer> writes=new LinkedBlockingQueue<>();
    private final Protocol.Stream stream=new Protocol.Stream();
    private volatile BluetoothGatt gatt;
    private BluetoothGattCharacteristic tx;
    private BluetoothLeScanner scanner;
    private volatile boolean ready=false,busy=false,connecting=false;
    private volatile int generation=0;
    private Extras extra=new Extras();
    private String identity="";
    private int lastSeenMode=-1;
    private static final class Links {
        final boolean enabled;final int[][] gains=new int[3][];
        Links(boolean active,int[][] source){enabled=active;for(int i=0;i<3;i++)if(source[i]!=null){Protocol.eq(source[i]);gains[i]=source[i].clone();}}
    }
    private volatile Links links=new Links(false,new int[3][]);
    public void setModeLinks(boolean enabled,int[][] gains){links=new Links(enabled,gains);}

    private final Runnable stopScan=()->stopScan();
    private Runnable connectionDeadline;
    private final Runnable poll=new Runnable(){public void run(){if(ready&&!busy)refresh(false);main.postDelayed(this,5000);}};

    public BleController(Context c,Listener l){context=c;listener=l;main.postDelayed(poll,5000);}
    private void status(String t){android.util.Log.i("SvanarState",t);main.post(()->listener.status(t));}
    private void state(){boolean r=ready,b=busy||connecting;main.post(()->listener.state(r,b));}
    public boolean ready(){return ready;}
    public void scan(){
        if(ready||connecting){status("请先断开控制连接，再扫描");return;}
        try{
            BluetoothManager manager=(BluetoothManager)context.getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter a=manager==null?null:manager.getAdapter();
            if(a==null||!a.isEnabled()){status("请先在系统设置开启蓝牙");return;}
            stopScan();scanner=a.getBluetoothLeScanner();
            scanner.startScan(null,new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scanCallback);
            status("正在扫描耳机，持续 20 秒…");main.postDelayed(stopScan,20000);
        }catch(Exception e){status("扫描未完成："+e.getMessage());}
    }
    public void stopScan(){main.removeCallbacks(stopScan);if(scanner!=null){try{scanner.stopScan(scanCallback);}catch(Exception ignored){}scanner=null;status("扫描已结束；列表为空时请唤醒耳机并断开其他控制 App 后重试");}}
    private final ScanCallback scanCallback=new ScanCallback(){
        public void onScanResult(int type,ScanResult result){
            if(result.getScanRecord()==null)return;
            String id=Protocol.identity(result.getScanRecord().getManufacturerSpecificData(58914));
            if(id!=null)main.post(()->listener.device(result.getDevice(),id,result.getRssi()));
        }
        public void onScanFailed(int error){status("蓝牙扫描失败，系统代码 "+error);stopScan();}
    };
    public void connect(BluetoothDevice device,String targetIdentity){
        if(ready||connecting||busy)return;
        stopScan();disconnect(false);extra=new Extras();identity=targetIdentity;lastSeenMode=-1;main.post(()->listener.extras(extra));connecting=true;state();status("正在连接耳机硬件接口…");
        try{
            gatt=device.connectGatt(context,false,callback,BluetoothDevice.TRANSPORT_LE);
            connectionDeadline=()->{if(connecting){disconnect(false);status("连接超时，请关闭电脑或手机上其他耳机控制 App 后重试");}};
            main.postDelayed(connectionDeadline,18000);
        }catch(Exception e){disconnect(false);status("连接失败："+e.getMessage());}
    }
    public void disconnect(boolean announce){
        generation++;lastSeenMode=-1;main.post(()->listener.touches(null));ready=false;busy=false;connecting=false;stopScan();
        if(connectionDeadline!=null)main.removeCallbacks(connectionDeadline);
        BluetoothGatt old=gatt;gatt=null;tx=null;stream.clear();replies.clear();
        if(old!=null){try{old.disconnect();old.close();}catch(Exception ignored){}}
        state();main.post(()->listener.snapshot(null,null,null,null));
        if(announce)status("已断开控制；音频连接仍由系统管理");
    }
    public void close(){main.removeCallbacksAndMessages(null);disconnect(false);worker.shutdownNow();}
    private final BluetoothGattCallback callback=new BluetoothGattCallback(){
        public void onConnectionStateChange(BluetoothGatt g,int code,int newState){
            if(g!=gatt)return;
            if(code!=BluetoothGatt.GATT_SUCCESS||newState==BluetoothProfile.STATE_DISCONNECTED){disconnect(false);status("耳机控制连接已断开，代码 "+code);return;}
            if(newState==BluetoothProfile.STATE_CONNECTED&&!g.discoverServices()){disconnect(false);status("服务发现启动失败");}
        }
        public void onServicesDiscovered(BluetoothGatt g,int code){
            if(g!=gatt)return;
            BluetoothGattService s=g.getService(SERVICE);
            if(code!=0||s==null){disconnect(false);status("未找到已验证的耳机控制服务");return;}
            tx=s.getCharacteristic(TX);BluetoothGattCharacteristic rx=s.getCharacteristic(RX);
            if(tx==null||rx==null||(tx.getProperties()&BluetoothGattCharacteristic.PROPERTY_WRITE)==0||(rx.getProperties()&BluetoothGattCharacteristic.PROPERTY_NOTIFY)==0){disconnect(false);status("蓝牙控制特征不匹配");return;}
            BluetoothGattDescriptor descriptor=rx.getDescriptor(CCCD);
            if(descriptor==null||!g.setCharacteristicNotification(rx,true)){disconnect(false);status("通知订阅失败");return;}
            boolean sent;
            if(Build.VERSION.SDK_INT>=33)sent=g.writeDescriptor(descriptor,BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)==BluetoothStatusCodes.SUCCESS;
            else{descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);sent=g.writeDescriptor(descriptor);}
            if(!sent){disconnect(false);status("通知描述符写入失败");}
        }
        public void onDescriptorWrite(BluetoothGatt g,BluetoothGattDescriptor d,int code){
            if(g!=gatt||!d.getUuid().equals(CCCD))return;
            if(code!=0){disconnect(false);status("耳机拒绝通知订阅，代码 "+code);return;}
            if(connectionDeadline!=null)main.removeCallbacks(connectionDeadline);
            connecting=false;ready=true;state();refresh(true);
        }
        public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c){if(Build.VERSION.SDK_INT<33)receive(g,c,c.getValue());}
        public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c,byte[] value){receive(g,c,value);}
        public void onCharacteristicWrite(BluetoothGatt g,BluetoothGattCharacteristic c,int code){
        if(g==gatt){writes.offer(code);if(code!=0){disconnect(false);status("耳机写入失败，代码 "+code);}}
        }
    };
    private void receive(BluetoothGatt g,BluetoothGattCharacteristic c,byte[] data){if(g!=gatt||!c.getUuid().equals(RX)||data==null)return;for(byte[] b:stream.feed(data)){if(TRACE_WIRE)android.util.Log.i("SvanarWire","RX "+Extras.hex(b));replies.offer(b);}}
    private byte[] request(int command,byte[] payload,int session)throws Exception{
        BluetoothGatt g=gatt;BluetoothGattCharacteristic t=tx;
        if(!ready||g==null||t==null||generation!=session)throw new IllegalStateException("耳机已断开");
        replies.clear();writes.clear();byte[] frame=Protocol.frame(command,payload);if(TRACE_WIRE)android.util.Log.i("SvanarWire","TX "+Extras.hex(frame));
        boolean sent;
        if(Build.VERSION.SDK_INT>=33)sent=g.writeCharacteristic(t,frame,BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)==BluetoothStatusCodes.SUCCESS;
        else{t.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);t.setValue(frame);sent=g.writeCharacteristic(t);}
        if(!sent)throw new IllegalStateException("系统未接受蓝牙写入");
        Integer ack=writes.poll(4,TimeUnit.SECONDS);
        if(ack==null){disconnect(false);throw new TimeoutException("蓝牙写入确认超时，请重新连接");}
        if(ack!=0)throw new IllegalStateException("蓝牙写入返回错误 "+ack);
        long end=System.nanoTime()+TimeUnit.SECONDS.toNanos(4);
        while(System.nanoTime()<end){
            if(session!=generation)throw new IllegalStateException("控制连接已断开");
            byte[] r=replies.poll(100,TimeUnit.MILLISECONDS);
            if(r!=null&&(r[1]&255)==command)return Protocol.decode(r);
        }
        disconnect(false);throw new TimeoutException("耳机响应超时，已断开以避免迟到响应串包");
    }
    private byte[] query(int command,int session)throws Exception{return request(command,new byte[0],session);}
    private int readMode(int session)throws Exception{byte[] p=query(6,session);if(p.length!=2||p[0]<0||p[0]>2)throw new IllegalArgumentException("模式响应无效");return p[0];}
    private interface Work{void run(int session)throws Exception;}
    private synchronized void run(Work action){
        if(!ready||busy)return;busy=true;state();final int session=generation;
        worker.execute(()->{try{action.run(session);}catch(Exception e){if(generation==session)status("操作未完成："+e.getMessage());else if(e instanceof TimeoutException)status(e.getMessage());}finally{if(generation==session){busy=false;state();}}});
    }
    private void snapshot(int session,Integer mode,int[] eq,Integer left,Integer right){main.post(()->{if(session==generation)listener.snapshot(mode,eq,left,right);});}
    public void refresh(boolean includeEQ){run(session->{
        int mode=readMode(session);boolean changed=lastSeenMode>=0&&lastSeenMode!=mode;lastSeenMode=mode;if(changed)applyLinked(session,mode);int[] eq=includeEQ?Protocol.readEQ(query(8,session)):null;byte[] b=query(3,session);
        Integer left=b.length>0&&(b[0]&127)<=100?b[0]&127:null,right=b.length>1&&(b[1]&127)<=100?b[1]&127:null;
        snapshot(session,mode,eq,left,right);if(includeEQ)status("已读取耳机模式、EQ 与左右耳电量");
    });}
    private void publishExtras(Extras e){
        final Extras snapshot=new Extras();for(Map.Entry<Integer,byte[]> r:e.raw.entrySet())snapshot.accept(r.getKey(),r.getValue());
        android.util.Log.i("SvanarCaps",snapshot.describe());main.post(()->listener.extras(snapshot));
    }
    public void readExtras(){run(session->{
        status("正在读取功能、游戏状态、编码和固件信息…");
        for(int command:new int[]{2,5,6,9,11,12,13}){extra.accept(command,query(command,session));publishExtras(extra);}
        status("扩展信息读取完成；只发送查询，未改耳机配置");
    });}
    public void setGame(boolean enabled){
        if(!Boolean.TRUE.equals(extra.gameSupported)||extra.game==null){status("请先读取扩展信息并确认耳机支持游戏模式");return;}
        run(session->{
            request(9,new byte[]{(byte)(enabled?1:0)},session);Thread.sleep(600);
            byte[] p=query(9,session);extra.accept(9,p);publishExtras(extra);
            if(p.length!=1||p[0]!=(enabled?1:0))throw new IllegalStateException("游戏模式回读不一致");
            status("游戏模式已"+(enabled?"开启":"关闭")+"，耳机回读一致");
        });
    }
    public void setMode(int mode){if(mode<0||mode>2)return;run(session->{
        status("正在切换到 "+Protocol.MODES[mode]+"…");
        for(int attempt=0;attempt<2;attempt++){
            request(6,new byte[]{(byte)mode,0},session);
            for(int i=0;i<4;i++){Thread.sleep(700);int actual=readMode(session);snapshot(session,actual,null,null,null);if(actual==mode){lastSeenMode=actual;status("耳机已确认："+Protocol.MODES[mode]);applyLinked(session,mode);return;}}
            Thread.sleep(1000);
        }throw new IllegalStateException("模式回读未匹配，请双耳佩戴后重试");
    });}
    private void applyLinked(int session,int mode)throws Exception{
        Links config=links;if(!config.enabled||config.gains[mode]==null)return;
        int[] target=config.gains[mode];int[] before=Protocol.readEQ(query(8,session));
        if(!Arrays.equals(before,target)){
            status("模式已确认，正在应用绑定 EQ…");request(8,Protocol.eq(target),session);Thread.sleep(500);
            int[] actual=Protocol.readEQ(query(8,session));snapshot(session,null,actual,null,null);
            if(!Arrays.equals(actual,target))throw new IllegalStateException("模式已切换，但绑定 EQ 回读未匹配");
        }else snapshot(session,null,before,null,null);
        status(Protocol.MODES[mode]+" 与绑定 EQ 已回读确认");
    }
    public void readStrength(){run(session->{for(int command:new int[]{2,5,6}){extra.accept(command,query(command,session));publishExtras(extra);}status("降噪 / 通透强度能力已读取，未写入配置");});}
    private void publishTouches(int session,TouchMap map){android.util.Log.i("SvanarTouch",Extras.hex(map.bytes())+"\n"+map.describe());main.post(()->{if(session==generation)listener.touches(map);});}
    public void readTouches(){run(session->{try{TouchMap map=TouchMap.parse(query(4,session));publishTouches(session,map);status("触控映射已读取；只开放耳机返回的手势");}catch(Exception e){main.post(()->listener.touchUnavailable("本次触控查询未成功："+e.getMessage()+"。未取得可验证映射，写入保持禁用。"));throw e;}});}
    private TouchMap backupTouches(int session)throws Exception{
        String target=identity;TouchMap map=TouchMap.parse(query(4,session));
        if(session!=generation||!target.equals(identity))throw new IllegalStateException("备份前连接已变更");
        if(!BluetoothAdapter.checkBluetoothAddress(identity))throw new IllegalStateException("耳机身份未确认");
        android.content.SharedPreferences p=context.getSharedPreferences("touch_backups",Context.MODE_PRIVATE);
        if(!p.contains(identity)&&!p.edit().putString(identity,android.util.Base64.encodeToString(map.bytes(),android.util.Base64.NO_WRAP)).commit())throw new IllegalStateException("触控备份保存失败，未执行写入");
        return map;
    }
    private TouchMap writeTouch(int session,TouchMap before,int ear,int gesture,int action)throws Exception{
        TouchMap.Entry old=before.get(ear,gesture);if(old==null)throw new IllegalArgumentException("耳机未返回此手势");
        if(old.action==action)return before;
        request(4,TouchMap.setting(ear,gesture,action),session);Thread.sleep(450);TouchMap actual=TouchMap.parse(query(4,session));publishTouches(session,actual);
        TouchMap.Entry got=actual.get(ear,gesture);
        if(got==null||got.action!=action)throw new IllegalStateException("触控写入回读不一致，原映射备份已保留");
        if(!before.sameKeys(actual))throw new IllegalStateException("触控手势集合改变，请重新读取并检查");
        for(TouchMap.Entry e:before.list())if(e.ear!=ear||e.gesture!=gesture){TouchMap.Entry current=actual.get(e.ear,e.gesture);if(current==null||current.action!=e.action)throw new IllegalStateException("其他手势发生变化，请使用恢复备份");}
        return actual;
    }
    public void setTouch(int ear,int gesture,int action){TouchMap.validate(ear,gesture,action);run(session->{TouchMap before=backupTouches(session);TouchMap after=writeTouch(session,before,ear,gesture,action);publishTouches(session,after);status("触控映射已保存，回读一致；实际手势请在耳机上确认");});}
    public void restoreTouches(){run(session->{
        String value=context.getSharedPreferences("touch_backups",Context.MODE_PRIVATE).getString(identity,null);if(value==null)throw new IllegalStateException("此耳机尚无触控修改备份");
        TouchMap target=TouchMap.parse(android.util.Base64.decode(value,android.util.Base64.DEFAULT));TouchMap current=TouchMap.parse(query(4,session));
        if(!target.sameKeys(current))throw new IllegalStateException("备份与当前耳机手势不匹配，未执行恢复");
        for(TouchMap.Entry e:target.list())current=writeTouch(session,current,e.ear,e.gesture,e.action);
        if(!target.same(current))throw new IllegalStateException("恢复回读未匹配");publishTouches(session,current);status("首次修改前的触控备份已恢复，全部回读一致");
    });}
    public void setEQ(int[] gains){final int[] values=gains.clone();run(session->{
        status("正在写入硬件 EQ…");request(8,Protocol.eq(values),session);Thread.sleep(500);
        int[] actual=Protocol.readEQ(query(8,session));snapshot(session,null,actual,null,null);
        if(!Arrays.equals(actual,values))throw new IllegalStateException("EQ 回读不一致，请重新读取");status("10 段硬件 EQ 已写入，回读一致");
    });}
}
