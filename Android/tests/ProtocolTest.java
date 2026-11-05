package io.local.svanarcontrol;
import java.util.*;
public final class ProtocolTest {
    static void check(boolean b){if(!b)throw new AssertionError();}
    static String hex(byte[] b){StringBuilder s=new StringBuilder();for(byte n:b)s.append(String.format("%02x",n&255));return s.toString();}
    public static void main(String[] args){
        check(hex(Protocol.frame(6,new byte[0])).equals("fe06000000c66b"));
        int[] gains={-10,-5,-1,0,1,2,3,5,8,10};check(Arrays.equals(gains,Protocol.readEQ(Protocol.eq(gains))));
        byte[] f=Protocol.frame(6,new byte[]{2,0});check(Arrays.equals(Protocol.decode(f),new byte[]{2,0}));
        Protocol.Stream s=new Protocol.Stream();check(s.feed(Arrays.copyOf(f,4)).isEmpty());check(s.feed(Arrays.copyOfRange(f,4,f.length)).size()==1);
        f[5]^=1;try{Protocol.decode(f);throw new AssertionError("corrupt accepted");}catch(IllegalArgumentException expected){}
        try{Protocol.eq(new int[9]);throw new AssertionError("bad length accepted");}catch(IllegalArgumentException expected){}
        byte[] adv={0,1,0,2,1,(byte)0xbf,(byte)0x99,(byte)0xfb,(byte)0xd5,0x37,0x11};check("12:34:56:78:9A:BC".equals(Protocol.identity(adv)));
        check(Presets.NAMES.length==14 && Presets.GAINS.length==14);
        for(int[] preset:Presets.GAINS)check(Arrays.equals(preset,Protocol.readEQ(Protocol.eq(preset))));
        Extras e=new Extras();e.accept(2,new byte[]{1,1,1,0,0,0});e.accept(9,new byte[]{0});
        check(Boolean.TRUE.equals(e.gameSupported)&&Boolean.FALSE.equals(e.game)&&e.ldac==null);
        e.accept(13,new byte[]{1,1,0,0,0,0,0,0,0,0,0,0,0,0});check(Boolean.FALSE.equals(e.ldac));
        e.accept(13,new byte[]{1,1,1,0,0,0,0,0,0,0,0,0});check(Boolean.TRUE.equals(e.ldac));
        e.accept(11,new byte[]{1,0,0});check(e.describe().contains("AAC / 16 bit / 44.1 kHz"));
        e.accept(11,new byte[]{99,99,99});check(e.describe().contains("未知(99)"));
        byte[] unknown={0};e.accept(12,unknown);unknown[0]=1;check(e.raw.get(12)[0]==0);
        TouchMap touch=TouchMap.parse(new byte[]{1,1,1,1,2,3,2,1,1});check(touch.list().size()==3&&touch.get(1,2).action==3);
        check(TouchMap.parse(touch.bytes()).same(touch));check(Arrays.equals(TouchMap.setting(2,4,7),new byte[]{2,4,7}));
        for(byte[] bad:new byte[][]{new byte[0],new byte[]{1,1},new byte[]{0,1,1},new byte[]{1,5,1},new byte[]{1,1,99},new byte[]{1,1,1,1,1,1}}){boolean rejected=false;try{TouchMap.parse(bad);}catch(IllegalArgumentException expected){rejected=true;}check(rejected);}
        e.accept(5,new byte[]{0,0,1,0,2,0});check(e.strengthReport().contains("档位字段 0"));
        System.out.println("PASS: CRC golden vector, signed EQ, mode frame, fragmented notification, corrupted packet rejection, range checks, manufacturer identity, touch triples/invalid/duplicate rejection, strength capability parsing");
    }
}
