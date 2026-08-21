import Foundation

/// 手机遥控界面。
///
/// 完全自包含 —— HTML/CSS/JS 全部内联, 不引任何外部资源。手机通过
/// Safari 打开, 「添加到主屏幕」后全屏运行, 看起来就是个原生 app。
///
/// 布局取自 Apple TV Remote / Google TV Remote 的取舍原则: 一个大方向盘
/// 占据视觉中心, 次要功能降级成一行图标, 不相关的收起来。
/// 我们比电视遥控多一个优势 —— 服务端知道前台是哪个 app, 所以「⋯」面板
/// 里只显示当下真正有用的动作。
enum RemoteUI {

    private static let css = #"""

:root{
  --bg:#f6f6f4; --card:#fff; --fg:#16161a; --sub:#8a8a90;
  --line:rgba(0,0,0,.07); --accent:#0a84ff; --shadow:0 1px 3px rgba(0,0,0,.08);
}
@media (prefers-color-scheme:dark){
  :root{ --bg:#101013; --card:#1c1c20; --fg:#f2f2f5; --sub:#8e8e96;
         --line:rgba(255,255,255,.09); --shadow:0 1px 3px rgba(0,0,0,.4); }
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;
  -webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
html,body{margin:0;height:100%;overflow:hidden;overscroll-behavior:none}
body{background:var(--bg);color:var(--fg);
     font:15px/1.4 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}

#app{height:100%;display:flex;flex-direction:column;
     padding:max(8px,env(safe-area-inset-top)) 18px max(14px,env(safe-area-inset-bottom))}

/* 顶栏: 当前 app */
#bar{display:flex;align-items:center;gap:8px;height:44px;flex:0 0 auto}
#dot{width:8px;height:8px;border-radius:50%;background:var(--sub);transition:background .2s}
#dot.on{background:#32d74b}
#appname{font-size:16px;font-weight:600;flex:1;overflow:hidden;
         text-overflow:ellipsis;white-space:nowrap}
#more{width:38px;height:38px;border:0;border-radius:12px;background:var(--card);
      color:var(--sub);font-size:20px;box-shadow:var(--shadow)}




/* 四角直达键: 圆盘内切于正方形, 四角本来是纯浪费的空间。
   放 app 图标, 一键直达 —— 就是遥控器上 Netflix/YouTube 那种直达键。 */
#padbox{position:relative;width:min(86vw,340px);aspect-ratio:1;
        display:flex;align-items:center;justify-content:center}
#corners{position:absolute;inset:0;pointer-events:none}
.corner{position:absolute;width:58px;height:58px;border:0;border-radius:18px;
        background:var(--card);box-shadow:var(--shadow);padding:0;overflow:hidden;
        pointer-events:auto;display:flex;align-items:center;justify-content:center;
        font-size:12px;font-weight:600;color:var(--sub)}
.corner img{width:38px;height:38px;display:block}
.corner.cur{box-shadow:0 0 0 2.5px var(--accent),var(--shadow)}
.c0{left:0;top:0} .c1{right:0;top:0} .c2{left:0;bottom:0} .c3{right:0;bottom:0}

/* 方向盘 */
#padwrap{flex:1 1 auto;display:flex;align-items:center;justify-content:center;min-height:0}
#pad{position:relative;width:76%;aspect-ratio:1;border-radius:50%;
     background:var(--card);box-shadow:var(--shadow)}
/* 中心键占 44%(28%~72%), 方向键必须待在环带里, 不能压到它上面 —— 
   之前方向键 34% 宽、距边 2%, 一直伸到 36%, 和中心键重叠 7%, 看着就乱 */
.dir{position:absolute;border:0;background:transparent;color:var(--sub);
     font-size:24px;line-height:1;display:flex;align-items:center;
     justify-content:center;border-radius:26px;transition:background .1s,color .1s}
.up   {top:3.5%;left:32%;width:36%;height:22%}   .up::before{content:"▲"}
.down {bottom:3.5%;left:32%;width:36%;height:22%} .down::before{content:"▼"}
.left {left:3.5%;top:32%;width:22%;height:36%}    .left::before{content:"◀"}
.right{right:3.5%;top:32%;width:22%;height:36%}   .right::before{content:"▶"}
/* 透明元素缩放几乎看不出来, 按下时给个实底才有反馈 */
.dir.press{background:var(--accent);color:#fff;transform:scale(.94)}

/* 中心键和外环之间留一道缝, 视觉上分开两个操作区 */
#ok{position:absolute;left:28%;top:28%;width:44%;height:44%;border:0;border-radius:50%;
    background:var(--accent);color:#fff;font-size:17px;font-weight:600;
    box-shadow:0 2px 10px rgba(10,132,255,.35),0 0 0 6px var(--bg);
    transition:transform .08s,box-shadow .08s}
#ok.press{transform:scale(.9);box-shadow:0 1px 4px rgba(10,132,255,.5),0 0 0 6px var(--bg)}
.fn.press,.corner.press,.chip.press,.app.press{transform:scale(.92);opacity:.7}
.fn,.corner,.chip{transition:transform .08s,opacity .08s}

/* 功能行 */
#row{flex:0 0 auto;display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:14px 0}
.fn{border:0;border-radius:16px;background:var(--card);box-shadow:var(--shadow);
    padding:12px 0;display:flex;flex-direction:column;align-items:center;gap:3px;color:var(--fg)}
.fn b{font-size:20px;font-weight:400;line-height:1}
.fn i{font-style:normal;font-size:11px;color:var(--sub)}

/* 语音条 */
#voicewrap{flex:0 0 auto}
#voice{width:100%;height:76px;border:0;border-radius:22px;background:var(--card);
       box-shadow:var(--shadow);display:flex;align-items:center;justify-content:center;
       gap:10px;font-size:17px;font-weight:600;color:var(--fg)}
#voice.rec{background:var(--accent);color:#fff;box-shadow:0 3px 18px rgba(10,132,255,.45)}
.mic{font-size:22px}

/* 面板 */
#sheet{position:fixed;inset:0;z-index:9}
#sheet.hidden{display:none}
#sheetbg{position:absolute;inset:0;background:rgba(0,0,0,.35)}
#sheetbody{position:absolute;left:0;right:0;bottom:0;background:var(--bg);
           border-radius:22px 22px 0 0;padding:10px 18px max(22px,env(safe-area-inset-bottom));
           animation:up .22s ease}
@keyframes up{from{transform:translateY(100%)}}
.handle{width:38px;height:4px;border-radius:2px;background:var(--line);margin:0 auto 14px}
#sheetbody h3{font-size:13px;color:var(--sub);font-weight:600;margin:16px 0 8px}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{border:0;border-radius:13px;background:var(--card);box-shadow:var(--shadow);
      padding:10px 15px;font-size:14px;color:var(--fg)}

"""#

    private static let js = #"""

const $=s=>document.querySelector(s);
// 页面可能挂在 / (Cookie 认证) 或 /<token>/ (老用法) 下,
// 所以所有请求都相对当前路径, 两种方式都能用
const BASE=location.pathname.replace(/\/+$/,"");
const fire=a=>fetch(`${BASE}/${a}`).catch(()=>{});

// 方向盘四向复用手柄的方向通道, 语义和手柄完全一致
const DIRS={stickUp:"scrollUp",stickDown:"scrollDown",
            stickLeft:"sessionPrev",stickRight:"sessionNext"};

function bind(el){
  const a=el.dataset.a; if(!a) return;
  const down=e=>{e.preventDefault();el.classList.add("press");fire(DIRS[a]||a);};
  // 至少亮 120ms —— 快速点按时如果立刻撤掉, 那一帧根本看不见
  const up=()=>setTimeout(()=>el.classList.remove("press"),120);
  el.addEventListener("touchstart",down,{passive:false});
  el.addEventListener("touchend",up); el.addEventListener("touchcancel",up);
  el.addEventListener("click",e=>{e.preventDefault();});
}
document.querySelectorAll("[data-a]").forEach(bind);

// 按住说话: touchcancel 和页面隐藏都要补发 pttStop,
// 否则修饰键会一直卡住(服务端还有 60 秒保险丝兜底)
let rec=false;
const voice=$("#voice"), vtext=$("#vtext");
const start=e=>{e.preventDefault();if(rec)return;rec=true;
  voice.classList.add("rec");vtext.textContent="松开出字";fire("pttStart");};
const stop=()=>{if(!rec)return;rec=false;
  voice.classList.remove("rec");vtext.textContent="按住说话";fire("pttStop");};
voice.addEventListener("touchstart",start,{passive:false});
voice.addEventListener("touchend",stop);
voice.addEventListener("touchcancel",stop);
document.addEventListener("visibilitychange",()=>{if(document.hidden)stop();});
window.addEventListener("pagehide",stop);

// 角键: 用真实 app 图标 (服务端从 bundle 里取), 加载失败退回短名文字
function corner(i,a){
  const b=document.createElement("button");
  b.className="corner c"+i; b.dataset.a=a.act; b.dataset.bid=a.id;
  const img=document.createElement("img");
  img.src=`${BASE}/icon/${a.id}`; img.alt=a.name;
  img.onerror=()=>{b.textContent=a.name;};
  b.appendChild(img); bind(b);
  return b;
}

// 面板
const sheet=$("#sheet");
$("#more").addEventListener("click",()=>sheet.classList.remove("hidden"));
$("#sheetbg").addEventListener("click",()=>sheet.classList.add("hidden"));

// 轮询前台 app, 动态刷新「⋯」面板里的专属动作
async function poll(){
  try{
    const r=await fetch(`${BASE}/state`);
    const s=await r.json();
    $("#appname").textContent=s.appName||"—";
    $("#dot").classList.toggle("on",!!s.inTarget);

    // 功能行跟着前台 app 换 —— Chrome 下是后退/刷新/关标签, 微信下是未读等等
    const row=s.row||[], rbox=$("#row");
    const rsig=row.map(x=>x.id).join("|");
    if(rbox.dataset.sig!==rsig){
      rbox.dataset.sig=rsig; rbox.innerHTML="";
      row.forEach(x=>{
        const b=document.createElement("button");
        b.className="fn"; b.dataset.a=x.id;
        b.innerHTML=`<b>${x.icon}</b><i>${x.name}</i>`;
        bind(b); rbox.appendChild(b);
      });
    }

    const apps=s.apps||[], cbox=$("#corners");
    // 顺序和数量都由服务端(设置页的四角配置)决定, 前端照摆就行
    const direct = apps.slice(0,4);
    const sig = direct.map(a=>a.id).join("|")+"/"+apps.length;
    if(cbox.dataset.sig!==sig){
      cbox.dataset.sig=sig; cbox.innerHTML="";
      direct.forEach((a,i)=>cbox.appendChild(corner(i,a)));
      if(apps.length>4){   // 白名单超过四个又没手动指定时, 右下角给个入口
        const b=document.createElement("button");
        b.className="corner c3"; b.textContent="更多";
        b.addEventListener("click",()=>sheet.classList.remove("hidden"));
        cbox.appendChild(b);
      }
      // 面板里的完整列表
      const pick=$("#pick"); pick.innerHTML="";
      apps.forEach(a=>{
        const c=document.createElement("button");
        c.className="chip"; c.textContent=a.name; c.dataset.a=a.act;
        bind(c); pick.appendChild(c);
      });
    }
    cbox.querySelectorAll(".corner").forEach(b=>
      b.classList.toggle("cur",b.dataset.bid===s.app));
    const box=$("#extras");
    if(box.dataset.for!==s.app){
      box.dataset.for=s.app; box.innerHTML="";
      (s.extras||[]).forEach(x=>{
        const b=document.createElement("button");
        b.className="chip"; b.textContent=x.name; b.dataset.a=x.id;
        bind(b); box.appendChild(b);
      });
      $("#extrah").style.display=(s.extras||[]).length?"":"none";
    }
  }catch(e){ $("#appname").textContent="连接断开"; $("#dot").classList.remove("on"); }
}
poll(); setInterval(poll,1500);

"""#

    /// 配对页。URL 只剩 IP:端口, 手输 6 位码一次, 之后靠 Cookie 记住。
    static func pairPage() -> String {
        """
        <!DOCTYPE html>
        <html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <title>JoyCoding 配对</title>
        <style>\(css)
        #pairwrap{height:100%;display:flex;flex-direction:column;align-items:center;
                  justify-content:center;gap:20px;padding:30px}
        #pairwrap h1{font-size:22px;margin:0}
        #pairwrap p{color:var(--sub);font-size:14px;margin:0;text-align:center;line-height:1.6}
        #code{width:100%;max-width:300px;height:70px;border:0;border-radius:20px;
              background:var(--card);box-shadow:var(--shadow);color:var(--fg);
              font-size:30px;letter-spacing:10px;text-align:center;font-weight:600}
        #go{width:100%;max-width:300px;height:56px;border:0;border-radius:18px;
            background:var(--accent);color:#fff;font-size:17px;font-weight:600}
        #msg{color:#ff453a;font-size:14px;min-height:20px}
        </style></head><body>
        <div id="pairwrap">
          <h1>🎮 JoyCoding</h1>
          <p>在 Mac 上打开 JoyCoding 设置 → 手机遥控<br>输入那里显示的 6 位配对码</p>
          <input id="code" inputmode="numeric" pattern="[0-9]*" maxlength="6" placeholder="······">
          <button id="go">配对</button>
          <div id="msg"></div>
        </div>
        <script>
        const code=document.getElementById("code"), msg=document.getElementById("msg");
        code.focus();
        async function pair(){
          const v=code.value.trim();
          if(v.length!==6){msg.textContent="请输入 6 位数字";return;}
          try{
            const r=await fetch(`/pair/${v}`);
            const j=await r.json();
            if(j.ok){ location.href="/"; } else { msg.textContent=j.msg||"配对失败"; code.value=""; }
          }catch(e){ msg.textContent="连不上 Mac"; }
        }
        document.getElementById("go").addEventListener("click",pair);
        code.addEventListener("input",()=>{msg.textContent="";if(code.value.length===6)pair();});
        </script></body></html>
        """
    }

    static func page() -> String {
        """
        <!DOCTYPE html>
        <html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="default">
        <title>JoyCoding</title>
        <style>\(css)</style>
        </head><body>
        <div id="app">
          <header id="bar">
            <span id="dot"></span>
            <span id="appname">连接中…</span>
            <button id="more" aria-label="更多">⋯</button>
          </header>

          <section id="padwrap">
            <div id="padbox">
              <div id="corners"></div>
              <div id="pad">
              <button class="dir up"    data-a="stickUp"></button>
              <button class="dir down"  data-a="stickDown"></button>
              <button class="dir left"  data-a="stickLeft"></button>
              <button class="dir right" data-a="stickRight"></button>
              <button id="ok" data-a="confirm">发送</button>
              </div>
            </div>
          </section>

          <section id="row"></section>

          <section id="voicewrap">
            <button id="voice"><span class="mic">🎤</span><span id="vtext">按住说话</span></button>
          </section>
        </div>

        <div id="sheet" class="hidden">
          <div id="sheetbg"></div>
          <div id="sheetbody">
            <div class="handle"></div>
            <h3 id="pickh">切换到</h3>
            <div class="chips" id="pick"></div>
            <h3 id="extrah">当前 app 可用</h3>
            <div class="chips" id="extras"></div>
          </div>
        </div>
        <script>\(js)</script>
        </body></html>
        """
    }
}
