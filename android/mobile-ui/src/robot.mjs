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
    {side:'left',full:'M0 38L28 39L35 47L31 57L26 65L25 79L22 100H0Z',lower:'M0 57.6L16.6 57L26 65L25 79L22 100H0Z',wristCut:'M0 81.25H100V100H0Z',thumb:'M16 82L20 81.8L23.8 87.8L23.5 91.7L20.5 91.6L17.5 87.8L14.8 85Z',fingers:'M9.6 87.3H15.7V97H9.6Z',shoulder:[300,690],elbow:[174,841],wrist:[170,1130],endWrist:[590,820],handTurn:70,handCut:1115,thumbSource:[[205,1160],[235,1205],[260,1245]],thumbTarget:[[574,863],[620,905],[665,940]],fingerSource:[[140,1210],[140,1232],[140,1255],[140,1291],[140,1330]],fingerTarget:[[505,819],[500,735],[540,680],[605,680],[665,780]]},
    {side:'right',full:'M76 42L100 40V100H82L79 82L80 65L76 61L76 55L72 49Z',lower:'M79.4 62L89 58.3L100 65.6V100H82L79 82Z',wristCut:'M0 82.7H100V100H0Z',thumb:'M84.4 82.7L87.8 83.7L88.4 86.7L85.8 91L84.5 91.9L82.2 91.2L81.7 90.1L83.3 87.1L83 85.3Z',fingers:'M90.2 87.3H95V97H90.2Z',shoulder:[875,704],elbow:[963,914],wrist:[1030,1150],endWrist:[742,830],handTurn:-70,handCut:1135,thumbSource:[[995,1170],[970,1210],[950,1250]],thumbTarget:[[749,870],[710,905],[665,940]],fingerSource:[[1070,1210],[1070,1232],[1070,1255],[1070,1291],[1070,1330]],fingerTarget:[[812,813],[820,735],[780,680],[725,680],[665,780]]},
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
  // Original hinge artwork carries the gesture. Small inner pins only cover
  // the newly exposed seams; no long sleeve draws across the heart opening.
  const bearing=(a,b)=>{
    const g=element('g',{'data-finger-bearing':'',opacity:0});
    g.append(element('circle',{cx:a[0],cy:a[1],r:9,fill:'#1b2424',stroke:'#b69a66','stroke-width':1.5}));
    g.append(element('circle',{cx:a[0],cy:a[1],r:3,fill:'#665331'}));
    return g;
  };
  const arms=[];
  for(const part of cuts){
    const upperMask=mask(`${prefix}-${part.side}-upper`),lowerMask=mask(`${prefix}-${part.side}-lower`);
    const wristMask=mask(`${prefix}-${part.side}-wrist`),thumbMasks=[0,1].map(i=>mask(`${prefix}-${part.side}-thumb-${i}`)),fingerMasks=Array.from({length:20},(_,i)=>i).map(i=>mask(`${prefix}-${part.side}-finger-${i}`));
    upperMask.append(shape(part.full,'white'),shape(part.lower,'black'));
    lowerMask.append(shape(part.lower,'white'),shape(part.wristCut,'black'),shape(part.thumb,'black'),shape(part.fingers,'black'));
    wristMask.append(shape(part.lower,'white'),element('rect',{x:0,y:0,width,height:part.handCut,fill:'black'}),shape(part.thumb,'black'),shape(part.fingers,'black'));
    thumbMasks[0].append(shape(part.thumb,'white'),element('rect',{x:0,y:height*.887,width,height:height*.113,fill:'black'}));
    thumbMasks[1].append(shape(part.thumb,'white'),element('rect',{x:0,y:0,width,height:height*.887,fill:'black'}));
    const fingerCuts=Array.from({length:21},(_,i)=>1210+i*6);
    fingerMasks.forEach((m,i)=>{
      m.append(shape(part.fingers,'white'),shape(part.thumb,'black'));
      if(i)m.append(element('rect',{x:0,y:0,width,height:fingerCuts[i]-1.2,fill:'black'}));
      if(i<fingerMasks.length-1)m.append(element('rect',{x:0,y:fingerCuts[i+1]+1.2,width,height:height-fingerCuts[i+1],fill:'black'}));
    });
    defs.append(upperMask,lowerMask,wristMask,...thumbMasks,...fingerMasks);
    const stage=element('g',{'data-mechanism-part':`${part.side}-arm`});
    const upper=element('g',{'data-robot-arm':part.side}),lower=element('g',{'data-robot-forearm':part.side});
    lower.append(picture(`${prefix}-${part.side}-lower`));
    const wrist=element('g',{'data-robot-wrist':part.side});wrist.append(picture(`${prefix}-${part.side}-wrist`));
    lower.append(wrist);upper.append(picture(`${prefix}-${part.side}-upper`),lower);stage.append(upper);
    const thumbParts=thumbMasks.map((_,i)=>{const g=element('g',{'data-robot-thumb-segment':`${part.side}-${i}`});g.append(bearing(part.thumbSource[i],part.thumbSource[i+1]),picture(`${prefix}-${part.side}-thumb-${i}`));wrist.append(g);return g;});
    const fingerParts=fingerMasks.map((_,i)=>{const g=element('g',{'data-robot-finger-segment':`${part.side}-${i}`});g.append(picture(`${prefix}-${part.side}-finger-${i}`));wrist.append(g);return g;});
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
      arm.wristElement.setAttribute('transform',`rotate(${((-(arm.upper+arm.lowerAngle)+arm.handTurn)*ease).toFixed(3)} ${arm.wrist.join(' ')})`);
      // Forward articulation keeps every phalanx on the previous joint all
      // the way through the gesture, rather than sliding bitmap strips.
      const mapSegments=(elements,source,target,narrow)=>{
        const turn=arm.handTurn*Math.PI/180;
        const local=target.map(([x,y])=>{const dx=x-arm.endWrist[0],dy=y-arm.endWrist[1];return [arm.wrist[0]+dx*Math.cos(turn)+dy*Math.sin(turn),arm.wrist[1]-dx*Math.sin(turn)+dy*Math.cos(turn)];});
        let joint=[...source[0]];
        elements.forEach((group,i)=>{
          const a=source[i],b=source[i+1],c=local[i],d=local[i+1];
          group.children[0].setAttribute('opacity',String(ease));
          const sourceAngle=angle(a,b),targetAngle=angle(c,d),direction=sourceAngle+wrap(targetAngle-sourceAngle)*ease;
          const length=distance(a,b)+(distance(c,d)-distance(a,b))*ease,size=length/distance(a,b);
          group.setAttribute('transform',`translate(${joint.join(' ')}) rotate(${direction*180/Math.PI}) scale(${size} ${1-(1-(Array.isArray(narrow)?narrow[i]:narrow))*ease}) rotate(${-sourceAngle*180/Math.PI}) translate(${-a[0]} ${-a[1]})`);
          joint=[joint[0]+Math.cos(direction)*length,joint[1]+Math.sin(direction)*length];
        });
      };
      mapSegments(arm.thumbElements,arm.thumbSource,arm.thumbTarget,.8);
      // Bend the photographed index tine continuously. Fine connected surface
      // slices preserve the original metal and avoid broad bitmap bands that
      // projected past the real fingertips and crossed the chest.
      const curves=arm.side==='left'
        ? [[[505,819],[475,740],[490,675],[555,675]],[[555,675],[615,675],[645,720],[665,755]]]
        : [[[812,813],[845,740],[825,675],[775,675]],[[775,675],[720,675],[685,720],[665,755]]];
      const turn=arm.handTurn*Math.PI/180;
      const localPoint=([x,y])=>{const dx=x-arm.endWrist[0],dy=y-arm.endWrist[1];return [arm.wrist[0]+dx*Math.cos(turn)+dy*Math.sin(turn),arm.wrist[1]-dx*Math.sin(turn)+dy*Math.cos(turn)];};
      let joint=[arm.fingerSource[0][0],1210],previousDirection=Math.PI/2;
      const start=localPoint(curves[0][0]);
      joint=[joint[0]+(start[0]-joint[0])*ease,joint[1]+(start[1]-joint[1])*ease];
      arm.fingerElements.forEach((group,i)=>{
        const t=(i+.5)/arm.fingerElements.length,j=t<.5?0:1,u=t*2-j,v=1-u;
        const [a,b,c,d]=curves[j];
        const tangent=[0,1].map(k=>3*v*v*(b[k]-a[k])+6*v*u*(c[k]-b[k])+3*u*u*(d[k]-c[k]));
        const sourceX=arm.fingerSource[0][0],sourceY=1210+t*120;
        const localDX=tangent[0]*Math.cos(turn)+tangent[1]*Math.sin(turn),localDY=-tangent[0]*Math.sin(turn)+tangent[1]*Math.cos(turn);
        const rawDirection=Math.atan2(localDY,localDX);
        const unwrapped=previousDirection+wrap(rawDirection-previousDirection);
        previousDirection=unwrapped;
        const direction=Math.PI/2+(unwrapped-Math.PI/2)*ease;
        const length=6*(1+(Math.hypot(...tangent)/60-1)*ease);
        const center=[joint[0]+Math.cos(direction)*length/2,joint[1]+Math.sin(direction)*length/2];
        group.setAttribute('transform',`translate(${center.join(' ')}) rotate(${(direction-Math.PI/2)*180/Math.PI}) scale(${1-.3*ease} ${length/6}) translate(${-sourceX} ${-sourceY})`);
        joint=[joint[0]+Math.cos(direction)*length,joint[1]+Math.sin(direction)*length];
      });
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
