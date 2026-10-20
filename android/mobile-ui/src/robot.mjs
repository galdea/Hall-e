const NS='http://www.w3.org/2000/svg';
let nextId=0;
const element=(name,attrs={})=>{const e=document.createElementNS(NS,name);for(const [k,v]of Object.entries(attrs))e.setAttribute(k,String(v));return e;};

// Original artwork stays in place; shoulder and elbow joints carry its arms
// toward the chest without replacing the hands or character.
export function mountRobotRig(root,host,image,preference){
  const source=root.querySelector('.hall-e-art');
  const width=image.naturalWidth,height=image.naturalHeight,scale=360/height;
  const rig=element('g',{class:'robot-rig',transform:`translate(${-width*scale/2} -172) scale(${scale})`});
  const defs=root.querySelector('defs');
  const prefix=`robot-${++nextId}`;
  // Shoulder and elbow articulation lets the claws lift to the chest, instead
  // of making a small wrist swing. The original hands frame the red lens.
  const cuts=[
    {side:'left',full:'M0 38L28 39L35 47L31 57L26 65L25 79L22 100H0Z',lower:'M0 57.6L16.6 57L26 65L25 79L22 100H0Z',wristCut:'M0 81.25H100V100H0Z',thumb:'M16 82L20 81.8L23.8 87.8L23.5 91.7L20.5 91.6L17.5 87.8L14.8 85Z',fingers:'M6 85.5L9.5 84.8L13.2 86.4L16.5 86L19.4 87.2L20.5 90L19.4 94.1L17.1 97.3L13.8 96.6L10.5 94.1L7.9 91.1Z',shoulder:[300,690],elbow:[174,841],wrist:[170,1130],endWrist:[570,740],handCut:1115,thumbSource:[[205,1160],[235,1205],[260,1245]],thumbTarget:[[605,770],[625,830],[665,890]],fingerSource:[[100,1190],[132,1255],[177,1291],[230,1320]],fingerTarget:[[500,800],[535,710],[605,695],[665,735]]},
    {side:'right',full:'M76 42L100 40V100H82L79 82L80 65L76 61L76 55L72 49Z',lower:'M79.4 62L89 58.3L100 65.6V100H82L79 82Z',wristCut:'M0 82.7H100V100H0Z',thumb:'M82.8 83.2L87.8 83.8L90.5 86.3L90.1 89.2L87.4 91L84.3 88.4Z',fingers:'M86.1 86.3L89.1 85.1L92.3 86.2L95 85.8L98 87.2L98.5 90.4L97.1 94.1L94.6 97.1L91.4 96.7L88.8 94.2L86.2 91Z',shoulder:[875,704],elbow:[963,914],wrist:[1030,1150],endWrist:[760,750],handCut:1135,thumbSource:[[995,1170],[970,1210],[950,1250]],thumbTarget:[[725,770],[705,830],[665,890]],fingerSource:[[1090,1190],[1080,1255],[1045,1291],[1000,1320]],fingerTarget:[[820,790],[790,710],[725,695],[665,735]]},
  ];
  const angle=(a,b)=>Math.atan2(b[1]-a[1],b[0]-a[0]);
  const distance=(a,b)=>Math.hypot(b[0]-a[0],b[1]-a[1]);
  const wrap=a=>Math.atan2(Math.sin(a),Math.cos(a));
  // Solve both hinges around the unchanged source pivots; hands stay attached.
  for(const arm of cuts){
    const [sx,sy]=arm.shoulder,[tx,ty]=arm.endWrist;
    const first=distance(arm.shoulder,arm.elbow),second=distance(arm.elbow,arm.wrist),d=distance(arm.shoulder,arm.endWrist);
    const along=(first*first-second*second+d*d)/(2*d),height=Math.sqrt(Math.max(0,first*first-along*along)),ux=(tx-sx)/d,uy=(ty-sy)/d;
    const joints=[-1,1].map(sign=>[sx+along*ux-sign*height*uy,sy+along*uy+sign*height*ux]);
    const elbow=joints.sort((a,b)=>b[1]-a[1])[0];
    arm.upper=wrap(angle(arm.shoulder,elbow)-angle(arm.shoulder,arm.elbow))*180/Math.PI;
    arm.lowerAngle=wrap(angle(elbow,arm.endWrist)-angle(arm.elbow,arm.wrist)-arm.upper*Math.PI/180)*180/Math.PI;
  }
  const shape=(d,fill)=>element('path',{d,fill,transform:`scale(${width/100} ${height/100})`});
  const mask=id=>element('mask',{id,maskUnits:'userSpaceOnUse',x:0,y:0,width,height,'mask-type':'luminance'});
  const picture=id=>element('image',{href:'/hall-e.webp',width,height,preserveAspectRatio:'none',mask:`url(#${id})`});
  const body=mask(`${prefix}-body`);body.append(element('rect',{width,height,fill:'white'}));
  for(const part of cuts)body.append(shape(part.full,'black'),shape(part.thumb,'black'),shape(part.fingers,'black'));
  defs.append(body);
  const chassis=element('g',{'data-mechanism-part':'body'});
  chassis.append(picture(`${prefix}-body`));rig.append(chassis);
  const metal=element('pattern',{id:`${prefix}-joint-metal`,patternUnits:'userSpaceOnUse',width:64,height:64});
  metal.append(element('image',{href:'/hall-e.webp',x:-120,y:-1220,width,height}));defs.append(metal);
  // The photo has no hidden joint surfaces. Textured bearing sleeves reveal
  // as the same original finger pieces turn, keeping their hinges connected.
  const bearing=(a,b)=>{
    const g=element('g',{'data-finger-bearing':'',opacity:0}),d=`M${a.join(' ')}L${b.join(' ')}`;
    g.append(element('path',{d,stroke:'#11191a','stroke-width':38,'stroke-linecap':'round',fill:'none'}));
    g.append(element('path',{d,stroke:`url(#${prefix}-joint-metal)`,'stroke-width':30,'stroke-linecap':'round',fill:'none'}));
    g.append(element('path',{d,stroke:'#d8c3a055','stroke-width':2,'stroke-linecap':'round',fill:'none'}));
    g.append(element('circle',{cx:a[0],cy:a[1],r:20,fill:'#1b2424',stroke:'#b69a66','stroke-width':2}));
    g.append(element('circle',{cx:a[0],cy:a[1],r:8,fill:'#665331',stroke:'#c9b487','stroke-width':2}));
    return g;
  };
  const arms=[];
  for(const part of cuts){
    const upperMask=mask(`${prefix}-${part.side}-upper`),lowerMask=mask(`${prefix}-${part.side}-lower`);
    const wristMask=mask(`${prefix}-${part.side}-wrist`),thumbMasks=[0,1].map(i=>mask(`${prefix}-${part.side}-thumb-${i}`)),fingerMasks=[0,1,2].map(i=>mask(`${prefix}-${part.side}-finger-${i}`));
    upperMask.append(shape(part.full,'white'),shape(part.lower,'black'));
    lowerMask.append(shape(part.lower,'white'),shape(part.wristCut,'black'),shape(part.thumb,'black'),shape(part.fingers,'black'));
    wristMask.append(shape(part.lower,'white'),element('rect',{x:0,y:0,width,height:part.handCut,fill:'black'}),shape(part.thumb,'black'),shape(part.fingers,'black'));
    thumbMasks[0].append(shape(part.thumb,'white'),element('rect',{x:0,y:height*.887,width,height:height*.113,fill:'black'}));
    thumbMasks[1].append(shape(part.thumb,'white'),element('rect',{x:0,y:0,width,height:height*.887,fill:'black'}));
    fingerMasks[0].append(shape(part.fingers,'white'),shape(part.thumb,'black'),element('rect',{x:0,y:height*.915,width,height:height*.085,fill:'black'}));
    fingerMasks[1].append(shape(part.fingers,'white'),shape(part.thumb,'black'),element('rect',{x:0,y:0,width,height:height*.915,fill:'black'}),element('rect',{x:0,y:height*.941,width,height:height*.059,fill:'black'}));
    fingerMasks[2].append(shape(part.fingers,'white'),shape(part.thumb,'black'),element('rect',{x:0,y:0,width,height:height*.941,fill:'black'}));
    defs.append(upperMask,lowerMask,wristMask,...thumbMasks,...fingerMasks);
    const stage=element('g',{'data-mechanism-part':`${part.side}-arm`});
    const upper=element('g',{'data-robot-arm':part.side}),lower=element('g',{'data-robot-forearm':part.side});
    lower.append(picture(`${prefix}-${part.side}-lower`));
    const wrist=element('g',{'data-robot-wrist':part.side});wrist.append(picture(`${prefix}-${part.side}-wrist`));
    lower.append(wrist);upper.append(picture(`${prefix}-${part.side}-upper`),lower);stage.append(upper);
    const thumbParts=thumbMasks.map((_,i)=>{const g=element('g',{'data-robot-thumb-segment':`${part.side}-${i}`});g.append(bearing(part.thumbSource[i],part.thumbSource[i+1]),picture(`${prefix}-${part.side}-thumb-${i}`));wrist.append(g);return g;});
    const fingerParts=fingerMasks.map((_,i)=>{const g=element('g',{'data-robot-finger-segment':`${part.side}-${i}`});g.append(bearing(part.fingerSource[i],part.fingerSource[i+1]),picture(`${prefix}-${part.side}-finger-${i}`));wrist.append(g);return g;});
    rig.append(stage);
    arms.push({...part,upperElement:upper,lowerElement:lower,wristElement:wrist,thumbElements:thumbParts,fingerElements:fingerParts});
  }
  const lens=(attrs={})=>element('ellipse',{cx:.58*width,cy:.5745*height,rx:.0385*width,ry:.0322*height,...attrs});
  const gradient=element('radialGradient',{id:`${prefix}-glow`});
  for(const [offset,color,opacity]of [[0,'#fff0c7',.9],[.18,'#ff6840',.8],[.45,'#ff291c',.45],[1,'#ff291c',0]])gradient.append(element('stop',{offset,'stop-color':color,'stop-opacity':opacity}));
  defs.append(gradient);
  const lensMask=mask(`${prefix}-lens`);lensMask.append(lens({fill:'white'}));defs.append(lensMask);
  const glow=element('g',{class:'robot-chest-glow'});
  glow.append(lens({rx:.11*width,ry:.092*height,fill:`url(#${prefix}-glow)`}));
  const lit=picture(`${prefix}-lens`);lit.setAttribute('class','robot-lit-lens');glow.append(lit);
  chassis.append(lens({class:'robot-chest-idle',fill:'#160300',opacity:.45}),glow);
  source.replaceWith(rig);
  let ready=false,frame=0,position=0,started=0,from=0,target=0,disposed=false;
  const pose=value=>{
    position=value;
    const ease=value*value*(3-2*value);
    for(const arm of arms){
      arm.upperElement.setAttribute('transform',`rotate(${(arm.upper*ease).toFixed(3)} ${arm.shoulder.join(' ')})`);
      arm.lowerElement.setAttribute('transform',`rotate(${(arm.lowerAngle*ease).toFixed(3)} ${arm.elbow.join(' ')})`);
      arm.wristElement.setAttribute('transform',`rotate(${(-(arm.upper+arm.lowerAngle)*ease).toFixed(3)} ${arm.wrist.join(' ')})`);
      // Forward articulation keeps every phalanx on the previous joint all
      // the way through the gesture, rather than sliding bitmap strips.
      const mapSegments=(elements,source,target,narrow)=>{
        let joint=[...source[0]];
        elements.forEach((group,i)=>{
          const a=source[i],b=source[i+1],c=target[i],d=target[i+1];
          group.children[0].setAttribute('opacity',String(ease));
          const sourceAngle=angle(a,b),targetAngle=angle(c,d),direction=sourceAngle+wrap(targetAngle-sourceAngle)*ease;
          const length=distance(a,b)+(distance(c,d)-distance(a,b))*ease,size=length/distance(a,b);
          group.setAttribute('transform',`translate(${joint.join(' ')}) rotate(${direction*180/Math.PI}) scale(${size} ${1-(1-narrow)*ease}) rotate(${-sourceAngle*180/Math.PI}) translate(${-a[0]} ${-a[1]})`);
          joint=[joint[0]+Math.cos(direction)*length,joint[1]+Math.sin(direction)*length];
        });
      };
      mapSegments(arm.thumbElements,arm.thumbSource,arm.thumbTarget,.48);
      mapSegments(arm.fingerElements,arm.fingerSource,arm.fingerTarget,.65);
    }
  };
  function tick(now){
    if(disposed)return;
    if(!started)started=now;
    const t=Math.min(1,(now-started)/1800),p=t*t*(3-2*t);
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
