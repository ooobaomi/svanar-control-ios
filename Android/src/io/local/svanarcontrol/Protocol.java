package io.local.svanarcontrol;

import java.util.Arrays;
import java.util.Locale;

public final class Protocol {
    public static final int[] FREQUENCIES={31,62,125,250,500,1000,2000,4000,8000,16000};
    public static final String[] MODES={"HiFi","降噪","通透"};
    public static int crc(byte[] bytes,int length) {
        int c=65535;
        for(int i=0;i<length;i++) {
            c^=(bytes[i]&255)<<8;
            for(int b=0;b<8;b++) c=((c&32768)!=0?(c<<1)^0x1021:c<<1)&65535;
        }
        return c;
    }
    public static byte[] frame(int command,byte[] payload) {
        if(payload.length>2041)throw new IllegalArgumentException("数据包过长");
        byte[] b=new byte[payload.length+7];b[0]=(byte)254;b[1]=(byte)command;
        b[3]=(byte)(payload.length>>8);b[4]=(byte)payload.length;
        System.arraycopy(payload,0,b,5,payload.length);
        int c=crc(b,b.length-2);b[b.length-2]=(byte)(c>>8);b[b.length-1]=(byte)c;return b;
    }
    public static byte[] decode(byte[] b) {
        if(b.length<7 || (b[0]&255)!=254 || b.length!=7+((b[3]&255)<<8)+(b[4]&255))throw new IllegalArgumentException("响应长度错误");
        if(crc(b,b.length-2)!=((b[b.length-2]&255)<<8 | b[b.length-1]&255))throw new IllegalArgumentException("响应校验失败");
        return Arrays.copyOfRange(b,5,b.length-2);
    }
    public static byte[] eq(int[] gains) {
        if(gains.length!=10)throw new IllegalArgumentException("需要 10 段 EQ");
        byte[] b=new byte[12];b[0]=101;b[1]=10;
        for(int i=0;i<10;i++) {if(gains[i]<-10||gains[i]>10)throw new IllegalArgumentException("EQ 超出 ±10 dB");b[i+2]=(byte)gains[i];}
        return b;
    }
    public static int[] readEQ(byte[] b) {
        if(b.length!=12 || b[1]!=10)throw new IllegalArgumentException("EQ 响应格式不匹配");
        int[] g=new int[10];for(int i=0;i<10;i++){g[i]=b[i+2];if(g[i]<-10||g[i]>10)throw new IllegalArgumentException("EQ 响应超出范围");}return g;
    }
    public static String identity(byte[] b) {
        if(b==null||b.length<11||b[2]!=0||b[3]!=2)return null;
        StringBuilder s=new StringBuilder();for(int i=5;i<11;i++){if(i>5)s.append(':');s.append(String.format(Locale.US,"%02X",(b[i]^173)&255));}return s.toString();
    }
    public static final class Stream {
        private byte[] buffer=new byte[0];
        public synchronized void clear(){buffer=new byte[0];}
        public synchronized java.util.List<byte[]> feed(byte[] data) {
            java.util.List<byte[]> out=new java.util.ArrayList<>();
            byte[] next=Arrays.copyOf(buffer,buffer.length+data.length);System.arraycopy(data,0,next,buffer.length,data.length);buffer=next;
            while(buffer.length>0){
                if((buffer[0]&255)!=254){buffer=Arrays.copyOfRange(buffer,1,buffer.length);continue;}
                if(buffer.length<5)break;
                int n=7+((buffer[3]&255)<<8)+(buffer[4]&255);
                if(n>2048){buffer=Arrays.copyOfRange(buffer,1,buffer.length);continue;}
                if(buffer.length<n)break;
                byte[] b=Arrays.copyOf(buffer,n);buffer=Arrays.copyOfRange(buffer,n,buffer.length);
                try{decode(b);out.add(b);}catch(IllegalArgumentException ignored){}
            }return out;
        }
    }
}
