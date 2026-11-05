package io.local.svanarcontrol;
import org.json.*;
import java.util.*;
/** Versioned, bounded local-data format. Import never changes the headset. */
public final class EqLibrary {
    public static final int MAX=64,MAX_BYTES=65536;
    public static final class Profile {
        public final String id,name;
        private final int[] gains;
        public Profile(String id,String name,int[] values){
            if(id==null||!id.matches("[A-Za-z0-9_-]{1,64}"))throw new IllegalArgumentException("收藏 ID 格式无效");
            if(name==null||name.trim().isEmpty()||name.trim().length()>40||name.matches("(?s).*\\p{Cntrl}.*"))throw new IllegalArgumentException("名称须为 1–40 字且不含控制字符");
            Protocol.eq(values);this.id=id;this.name=name.trim();gains=values.clone();
        }
        public int[] values(){return gains.clone();}
    }
    public final LinkedHashMap<String,Profile> profiles=new LinkedHashMap<>();
    public final String[] links=new String[3];
    public EqLibrary copy(){EqLibrary n=new EqLibrary();n.profiles.putAll(profiles);System.arraycopy(links,0,n.links,0,3);return n;}
    public void add(Profile p){if(!profiles.containsKey(p.id)&&profiles.size()>=MAX)throw new IllegalArgumentException("最多保存 64 套收藏");profiles.put(p.id,p);}
    public void remove(String id){profiles.remove(id);for(int i=0;i<3;i++)if(id.equals(links[i]))links[i]=null;}
    public int[][] gainsForLinks(){int[][] r=new int[3][];for(int i=0;i<3;i++){Profile p=profiles.get(links[i]);if(p!=null)r[i]=p.values();}return r;}
    private static int integer(Object v){
        if(!(v instanceof Number))throw new IllegalArgumentException("数值字段必须为整数");Number n=(Number)v;double d=n.doubleValue();int i=n.intValue();if(Double.isNaN(d)||Double.isInfinite(d)||d!=i)throw new IllegalArgumentException("数值字段必须为整数");return i;
    }
    private static String string(Object v){if(!(v instanceof String))throw new IllegalArgumentException("文本字段类型无效");return (String)v;}
    public String encode()throws JSONException{
        JSONObject root=new JSONObject();root.put("format","svanar-eq");root.put("version",1);
        JSONArray hz=new JSONArray();for(int v:Protocol.FREQUENCIES)hz.put(v);root.put("frequencies",hz);
        JSONArray items=new JSONArray();for(Profile p:profiles.values()){JSONObject o=new JSONObject();o.put("id",p.id);o.put("name",p.name);JSONArray gains=new JSONArray();for(int g:p.values())gains.put(g);o.put("gains",gains);items.put(o);}root.put("profiles",items);
        JSONObject bindings=new JSONObject();for(int i=0;i<3;i++)if(links[i]!=null){if(!profiles.containsKey(links[i]))throw new IllegalArgumentException("绑定指向缺失收藏");bindings.put(String.valueOf(i),links[i]);}root.put("links",bindings);return root.toString(2);
    }
    public static EqLibrary decode(String text)throws JSONException{
        if(text==null||text.getBytes(java.nio.charset.StandardCharsets.UTF_8).length>MAX_BYTES)throw new IllegalArgumentException("文件超过 64 KiB");
        int depth=0;boolean quoted=false,escaped=false;
        for(int i=0;i<text.length();i++){char c=text.charAt(i);if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;}else if(c=='"')quoted=true;else if(c=='{'||c=='['){if(++depth>16)throw new IllegalArgumentException("JSON 嵌套过深");}else if(c=='}'||c==']')depth--;}
        JSONTokener tokener=new JSONTokener(text);Object value=tokener.nextValue();if(!(value instanceof JSONObject)||tokener.nextClean()!=0)throw new IllegalArgumentException("需要单个 JSON 对象");JSONObject root=(JSONObject)value;
        if(!"svanar-eq".equals(root.get("format"))||integer(root.get("version"))!=1)throw new IllegalArgumentException("不是支持的 SVANAR EQ 文件版本");
        JSONArray hz=root.getJSONArray("frequencies");if(hz.length()!=10)throw new IllegalArgumentException("频段数量不匹配");for(int i=0;i<10;i++)if(integer(hz.get(i))!=Protocol.FREQUENCIES[i])throw new IllegalArgumentException("频段定义不匹配");
        JSONArray items=root.getJSONArray("profiles");if(items.length()>MAX)throw new IllegalArgumentException("收藏超过 64 套");EqLibrary result=new EqLibrary();
        for(int i=0;i<items.length();i++){JSONObject o=items.getJSONObject(i);JSONArray a=o.getJSONArray("gains");if(a.length()!=10)throw new IllegalArgumentException("EQ 必须有 10 段");int[] gains=new int[10];for(int j=0;j<10;j++)gains[j]=integer(a.get(j));Profile p=new Profile(string(o.get("id")),string(o.get("name")),gains);if(result.profiles.containsKey(p.id))throw new IllegalArgumentException("文件包含重复收藏 ID");result.add(p);}
        JSONObject bindings=root.getJSONObject("links");Iterator<String> keys=bindings.keys();while(keys.hasNext()){String key=keys.next();if(!key.matches("[012]"))throw new IllegalArgumentException("模式绑定无效");String id=string(bindings.get(key));if(!result.profiles.containsKey(id))throw new IllegalArgumentException("绑定指向缺失收藏");result.links[Integer.parseInt(key)]=id;}
        return result;
    }
    public EqLibrary merge(EqLibrary imported){
        EqLibrary n=copy();Map<String,String> ids=new HashMap<>();
        for(Profile p:imported.profiles.values()){
            Profile old=n.profiles.get(p.id);String id=p.id;
            if(old!=null&&(!old.name.equals(p.name)||!Arrays.equals(old.values(),p.values())))id=UUID.randomUUID().toString();
            n.add(new Profile(id,p.name,p.values()));ids.put(p.id,id);
        }
        for(int i=0;i<3;i++)if(imported.links[i]!=null)n.links[i]=ids.get(imported.links[i]);return n;
    }
    /** Runs using Android's real org.json implementation, including malformed-input rejection. */
    public static void selfTest()throws Exception{
        EqLibrary a=new EqLibrary();a.add(new Profile("test","测试收藏",new int[]{-10,-5,-1,0,1,2,3,5,8,10}));a.links[1]="test";
        EqLibrary b=decode(a.encode());if(!Arrays.equals(a.profiles.get("test").values(),b.profiles.get("test").values())||!"test".equals(b.links[1]))throw new AssertionError("JSON roundtrip");
        String valid=a.encode();String[] invalid={valid.replace("\"version\": 1","\"version\": 99"),valid.replace("-10,","-10.5,"),valid.replace("-10,","-11,"),valid+" false",valid.replace("\"test\"","\"bad id\"")};
        for(String bad:invalid){boolean rejected=false;try{decode(bad);}catch(Exception expected){rejected=true;}if(!rejected)throw new AssertionError("Invalid EQ accepted");}
        EqLibrary collision=new EqLibrary();collision.add(new Profile("test","不同内容",new int[10]));collision.links[0]="test";EqLibrary merged=a.merge(collision);if(merged.profiles.size()!=2||"test".equals(merged.links[0]))throw new AssertionError("Merge overwrote existing");
        boolean deepRejected=false;try{decode("[[[[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]]]]");}catch(Exception expected){deepRejected=true;}if(!deepRejected)throw new AssertionError("Unbounded nesting");
        b.remove("test");if(b.links[1]!=null)throw new AssertionError("Dangling link");
    }
}
