package io.local.svanarcontrol;
import java.nio.charset.StandardCharsets;
import java.util.*;
/** Independent parser for documented-by-observation vendor responses; unknowns stay unknown. */
public final class Extras {
    public final Map<Integer,byte[]> raw=new LinkedHashMap<>();
    public Boolean gameSupported,game,ldac;
    public void accept(int cmd,byte[] p){
        raw.put(cmd,p.clone());
        if(cmd==2 && p.length>=6)gameSupported=(p[2]&127)==1;
        if(cmd==9 && p.length==1 && (p[0]==0||p[0]==1))game=p[0]==1;
        if(cmd==13 && p.length>=3)ldac=(p[2]&127)==1;
    }
    public static String hex(byte[] p){StringBuilder s=new StringBuilder();for(byte b:p)s.append(String.format(Locale.US,"%02X ",b&255));return s.toString().trim();}
    public String strengthReport(){
        byte[] flags=raw.get(2),pairs=raw.get(5),current=raw.get(6);
        String a=flags!=null&&flags.length>=6?((flags[4]&127)==1?"声明支持":"未声明支持"):"未读取";
        String b=flags!=null&&flags.length>=6?((flags[5]&127)==1?"声明支持":"未声明支持"):"未读取";
        Integer anc=null,pass=null;
        if(pairs!=null&&pairs.length%2==0)for(int i=0;i<pairs.length;i+=2){if(pairs[i]==1)anc=pairs[i+1]&127;if(pairs[i]==2)pass=pairs[i+1]&127;}
        return "降噪强度："+a+"；档位字段 "+(anc==null?"—":anc)+"\n通透强度："+b+"；档位字段 "+(pass==null?"—":pass)
            +(current!=null&&current.length==2?"\n当前模式 / 强度原始值："+hex(current):"")
            +"\n只有声明和档位证据、写入协议均确认后才开放强度调节；不会用 EQ 或音量冒充强度。";
    }
    public String describe(){
        StringBuilder s=new StringBuilder("最近一次耳机回读（非手机系统编码状态）\n");
        byte[] p=raw.get(12);
        if(p!=null && p.length>8){
            String model=new String(p,0,p.length-8,StandardCharsets.UTF_8).replaceAll("[\\p{Cntrl}]","").trim();
            s.append("型号：").append(model).append("\n固件字节：").append(hex(Arrays.copyOfRange(p,p.length-8,p.length-4)))
             .append("\n充电盒版本字节：").append(hex(Arrays.copyOfRange(p,p.length-4,p.length))).append('\n');
        }
        p=raw.get(11);
        if(p!=null && p.length>=3){
            String[] codecs={"SBC","AAC","LDAC","aptX","aptX Adaptive","aptX Lossless","aptX HD","LHDC 4","LHDC 5","LC3","LC3 Plus","L2HC"};
            String[] depth={"16 bit","24 bit","32 bit"};String[] rate={"44.1 kHz","48 kHz","96 kHz","192 kHz","88.2 kHz","384 kHz"};
            int c=p[0]&127,d=p[1]&127,r=p[2]&127;
            s.append("耳机编码报告：").append(c<codecs.length?codecs[c]:"未知("+c+")").append(" / ")
             .append(d<depth.length?depth[d]:"位深未知").append(" / ").append(r<rate.length?rate[r]:"采样率未知").append('\n');
        }
        s.append("LDAC 能力标志：").append(ldac==null?"未取得":ldac?"支持":"未声明支持").append('\n');
        s.append("游戏 / 低延迟：").append(game==null?"未取得":game?"开启":"关闭").append('\n');
        p=raw.get(2);
        if(p!=null && p.length>=6){String[] names={"自定义界面","降噪模式","游戏模式","LE Audio","降噪强度","通透强度"};
            for(int i=0;i<6;i++)s.append(names[i]).append('：').append((p[i]&127)==1?"支持":"未声明").append(i==5?"\n":" / ");
        }
        s.append(strengthReport()).append("\n\n原始响应（诊断）\n");for(Map.Entry<Integer,byte[]> e:raw.entrySet())s.append(String.format(Locale.US,"%02X: ",e.getKey())).append(hex(e.getValue())).append('\n');
        return s.toString();
    }
}
