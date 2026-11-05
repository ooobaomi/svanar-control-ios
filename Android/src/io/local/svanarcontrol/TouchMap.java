package io.local.svanarcontrol;
import java.util.*;
public final class TouchMap {
    public static final String[] GESTURES={"", "单击","双击","三击","长按"};
    public static final String[] ACTIONS={"无操作","播放 / 暂停","上一曲","下一曲","音量增加","音量减小","语音助手","模式切换","接听电话","挂断电话"};
    public static final class Entry {
        public final int ear,gesture,action;
        Entry(int e,int g,int a){ear=e;gesture=g;action=a;}
        public String name(){return (ear==1?"左耳":"右耳")+" · "+GESTURES[gesture];}
    }
    private final SortedMap<Integer,Entry> entries=new TreeMap<>();
    public static void validate(int e,int g,int a){if(e<1||e>2||g<1||g>4||a<0||a>=ACTIONS.length)throw new IllegalArgumentException("触控映射包含未知耳侧、手势或动作");}
    public static byte[] setting(int e,int g,int a){validate(e,g,a);return new byte[]{(byte)e,(byte)g,(byte)a};}
    public static TouchMap parse(byte[] raw){
        if(raw==null||raw.length==0||raw.length>24||raw.length%3!=0)throw new IllegalArgumentException("触控查询格式不匹配，保留只读");
        TouchMap result=new TouchMap();
        for(int i=0;i<raw.length;i+=3){int e=raw[i]&255,g=raw[i+1]&255,a=raw[i+2]&255;validate(e,g,a);int k=e*10+g;
            if(result.entries.containsKey(k))throw new IllegalArgumentException("触控查询含重复手势");result.entries.put(k,new Entry(e,g,a));}
        return result;
    }
    public Entry get(int e,int g){return entries.get(e*10+g);}
    public List<Entry> list(){return new ArrayList<>(entries.values());}
    public byte[] bytes(){byte[] r=new byte[entries.size()*3];int i=0;for(Entry e:entries.values()){r[i++]=(byte)e.ear;r[i++]=(byte)e.gesture;r[i++]=(byte)e.action;}return r;}
    public boolean sameKeys(TouchMap other){return entries.keySet().equals(other.entries.keySet());}
    public boolean same(TouchMap other){return Arrays.equals(bytes(),other.bytes());}
    public String describe(){StringBuilder s=new StringBuilder();for(Entry e:entries.values())s.append(e.name()).append(" → ").append(ACTIONS[e.action]).append('\n');return s.toString();}
}
