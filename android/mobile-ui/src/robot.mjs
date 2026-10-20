const NS='http://www.w3.org/2000/svg';
let nextId=0;
const element=(name,attrs={})=>{const e=document.createElementNS(NS,name);for(const [k,v]of Object.entries(attrs))e.setAttribute(k,String(v));return e;};

// Articulated cuts of the original landing artwork. No replacement character,
// floating lens, or alternate robot pose is loaded on recording transitions.
export function mountRobotRig(root,host,image,preference){
  const source=root.querySelector('.hall-e-art');
  const width=360*image.naturalWidth/image.naturalHeight;
  const rig=element('g',{class:'robot-rig',transform:`translate(${-width/2} -172) scale(${width/100} 3.6)`});
  const defs=root.querySelector('defs');
  const prefix=`robot-${++nextId}`;
  const cuts=[['left','M0 66L16 59L25 65L25 79L22 100H0Z',20,65,-24],['right','M80 64L89 60L100 67V100H82L79 82Z',83,65,24]];
  const picture=mask=>element('image',{href:'/hall-e.webp',width:100,height:100,preserveAspectRatio:'none',mask:`url(#${mask})`});
  const body=element('mask',{id:`${prefix}-body`,maskUnits:'userSpaceOnUse',x:0,y:0,width:100,height:100,'mask-type':'luminance'});
  body.append(element('rect',{width:100,height:100,fill:'white'}));
  const arms=[];
  for(const [side,d,x,y,angle]of cuts){
    body.append(element('path',{d,fill:'black'}));
    const mask=element('mask',{id:`${prefix}-${side}`,maskUnits:'userSpaceOnUse',x:0,y:0,width:100,height:100,'mask-type':'luminance'});
    mask.append(element('path',{d,fill:'white'}));defs.append(mask);
    const arm=element('g',{'data-robot-arm':side});arm.append(picture(`${prefix}-${side}`));rig.append(arm);arms.push({arm,x,y,angle});
  }
  defs.append(body);rig.append(picture(`${prefix}-body`));
  const gradient=element('radialGradient',{id:`${prefix}-glow`});
  for(const [offset,color,opacity]of [[0,'#fff0c7',.9],[.18,'#ff6840',.8],[.45,'#ff291c',.45],[1,'#ff291c',0]])gradient.append(element('stop',{offset,'stop-color':color,'stop-opacity':opacity}));
  defs.append(gradient);
  const lensMask=element('mask',{id:`${prefix}-lens`,maskUnits:'userSpaceOnUse',x:0,y:0,width:100,height:100,'mask-type':'luminance'});
  lensMask.append(element('ellipse',{cx:58,cy:57.45,rx:3.85,ry:3.22,fill:'white'}));defs.append(lensMask);
  const glow=element('g',{class:'robot-chest-glow'});
  glow.append(element('ellipse',{cx:58,cy:57.45,rx:11,ry:9.2,fill:`url(#${prefix}-glow)`}));
  const lit=picture(`${prefix}-lens`);lit.setAttribute('class','robot-lit-lens');glow.append(lit);
  rig.append(element('ellipse',{class:'robot-chest-idle',cx:58,cy:57.45,rx:3.85,ry:3.22,fill:'#160300',opacity:.45}),glow);
  source.replaceWith(rig);
  let ready=false,frame=0,position=0,started=0,from=0,target=0,disposed=false;
  const pose=value=>{position=value;for(const {arm,x,y,angle}of arms)arm.setAttribute('transform',`rotate(${(angle*value).toFixed(3)} ${x} ${y})`);};
  function tick(now){
    if(disposed)return;
    if(!started)started=now;
    const t=Math.min(1,(now-started)/850),p=t*t*(3-2*t);
    pose(from+(target-from)*p);
    if(t<1)frame=requestAnimationFrame(tick);else frame=0;
  }
  function update(){
    if(!ready||disposed)return;
    const next=host.dataset.engaged==='true'?1:0;
    if(preference.matches){cancelAnimationFrame(frame);frame=0;target=next;pose(target);return;}
    if(next===target&&frame)return;
    cancelAnimationFrame(frame);frame=0;target=next;from=position;started=0;
    if(position!==target)frame=requestAnimationFrame(tick);
  }
  const observer=new MutationObserver(update);observer.observe(host,{attributes:true,attributeFilter:['data-engaged']});
  preference.addEventListener('change',update);
  return {ready(){ready=true;update();},dispose(){disposed=true;cancelAnimationFrame(frame);observer.disconnect();preference.removeEventListener('change',update);}};
}
