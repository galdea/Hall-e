const NS='http://www.w3.org/2000/svg';
let nextId=0;
const element=(name,attrs={})=>{const e=document.createElementNS(NS,name);for(const [k,v]of Object.entries(attrs))e.setAttribute(k,String(v));return e;};

// Original artwork stays as the fixed head/chassis; an authored mechanical
// heart pose blends into the articulated arms without replacing the character.
export function mountRobotRig(root,host,image,preference){
  const source=root.querySelector('.hall-e-art');
  const width=image.naturalWidth,height=image.naturalHeight,scale=360/height;
  const rig=element('g',{class:'robot-rig',transform:`translate(${-width*scale/2} -172) scale(${scale})`});
  const defs=root.querySelector('defs');
  const prefix=`robot-${++nextId}`;
  // Shoulder and elbow articulation lets the claws lift to the chest, instead
  // of making a small wrist swing. The original hands frame the red lens.
  const cuts=[
    {side:'left',full:'M0 38L28 39L35 47L31 57L26 65L25 79L22 100H0Z',lower:'M0 66L16 59L25 65L25 79L22 100H0Z',shoulder:[300,690],elbow:[229,892],upper:-13,lowerAngle:-113},
    {side:'right',full:'M76 42L100 40V100H82L79 82L80 65L76 61L76 55L72 49Z',lower:'M80 64L89 60L100 67V100H82L79 82Z',shoulder:[875,704],elbow:[957,914],upper:-21,lowerAngle:143},
  ];
  const shape=(d,fill)=>element('path',{d,fill,transform:`scale(${width/100} ${height/100})`});
  const mask=id=>element('mask',{id,maskUnits:'userSpaceOnUse',x:0,y:0,width,height,'mask-type':'luminance'});
  const picture=id=>element('image',{href:'/hall-e.webp',width,height,preserveAspectRatio:'none',mask:`url(#${id})`});
  const body=mask(`${prefix}-body`);body.append(element('rect',{width,height,fill:'white'}));
  for(const part of cuts)body.append(shape(part.full,'black'));
  defs.append(body);rig.append(picture(`${prefix}-body`));
  const arms=[];
  for(const part of cuts){
    const upperMask=mask(`${prefix}-${part.side}-upper`),lowerMask=mask(`${prefix}-${part.side}-lower`);
    upperMask.append(shape(part.full,'white'),shape(part.lower,'black'));lowerMask.append(shape(part.lower,'white'));defs.append(upperMask,lowerMask);
    const upper=element('g',{'data-robot-arm':part.side}),lower=element('g',{'data-robot-forearm':part.side});
    lower.append(picture(`${prefix}-${part.side}-lower`));upper.append(picture(`${prefix}-${part.side}-upper`),lower);rig.append(upper);arms.push({...part,upperElement:upper,lowerElement:lower});
  }
  // The authored heart pose has actual segmented fingers, not crossed claws.
  // Only the mid-body plate is composited; the original head and wheels stay put.
  const heartMask=mask(`${prefix}-heart-arms`);
  heartMask.append(shape('M0 39H100V78H79L73 73H35L27 78H0Z','white'));
  defs.append(heartMask);
  const heart=element('g',{'data-heart-hands':'true',opacity:0});
  heart.append(element('image',{href:'/hall-e-heart.webp',width,height,preserveAspectRatio:'none',mask:`url(#${prefix}-heart-arms)`}));
  rig.append(heart);
  const lens=(attrs={})=>element('ellipse',{cx:.58*width,cy:.5745*height,rx:.0385*width,ry:.0322*height,...attrs});
  const gradient=element('radialGradient',{id:`${prefix}-glow`});
  for(const [offset,color,opacity]of [[0,'#fff0c7',.9],[.18,'#ff6840',.8],[.45,'#ff291c',.45],[1,'#ff291c',0]])gradient.append(element('stop',{offset,'stop-color':color,'stop-opacity':opacity}));
  defs.append(gradient);
  const lensMask=mask(`${prefix}-lens`);lensMask.append(lens({cx:.56*width,fill:'white'}));defs.append(lensMask);
  const glow=element('g',{class:'robot-chest-glow'});
  glow.append(lens({cx:.56*width,rx:.11*width,ry:.092*height,fill:`url(#${prefix}-glow)`}));
  const lit=picture(`${prefix}-lens`);lit.setAttribute('href','/hall-e-heart.webp');lit.setAttribute('class','robot-lit-lens');glow.append(lit);
  rig.append(lens({class:'robot-chest-idle',fill:'#160300',opacity:.45}),glow);
  source.replaceWith(rig);
  let ready=false,frame=0,position=0,started=0,from=0,target=0,disposed=false;
  const pose=value=>{
    position=value;
    const blend=Math.max(0,Math.min(1,(value-.35)/.65)),smoothBlend=blend*blend*(3-2*blend);
    for(const arm of arms){
      arm.upperElement.setAttribute('transform',`rotate(${(arm.upper*value).toFixed(3)} ${arm.shoulder.join(' ')})`);
      arm.lowerElement.setAttribute('transform',`rotate(${(arm.lowerAngle*Math.max(0,(value-.08)/.92)).toFixed(3)} ${arm.elbow.join(' ')})`);
      arm.upperElement.setAttribute('opacity',String(1-smoothBlend));
    }
    heart.setAttribute('opacity',String(smoothBlend));
    heart.setAttribute('transform',`translate(0 ${(1-smoothBlend)*38})`);
  };
  function tick(now){
    if(disposed)return;
    if(!started)started=now;
    const t=Math.min(1,(now-started)/1150),p=t*t*(3-2*t);
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
