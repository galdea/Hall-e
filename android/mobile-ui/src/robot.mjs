const NS='http://www.w3.org/2000/svg';
let nextId=0;
const element=(name,attrs={})=>{const e=document.createElementNS(NS,name);for(const [k,v]of Object.entries(attrs))e.setAttribute(k,String(v));return e;};
// One connected set of shoulder, elbow and hand pieces throughout the motion.
// No pose replacement, arm crossfade, or rectangular mid-body plate.
export function mountRobotRig(root,host,image,preference){
  const source=root.querySelector('.hall-e-art');
  const width=image.naturalWidth,height=image.naturalHeight,scale=360/height;
  const rig=element('g',{class:'robot-rig',transform:`translate(${-width*scale/2} -172) scale(${scale})`});
  const defs=root.querySelector('defs'),prefix=`robot-${++nextId}`;
  const path=(d,fill)=>element('path',{d,fill});
  const mask=id=>element('mask',{id,maskUnits:'userSpaceOnUse',x:-400,y:-300,width:width+800,height:height+900,'mask-type':'luminance'});
  const picture=(id,asset='/hall-e-heart.webp')=>element('image',{href:asset,width,height,preserveAspectRatio:'none',mask:`url(#${id})`});
  const arms=[
    {side:'left',shoulder:[300,690],elbow:[153,1008],restElbow:[229,892],wrist:[432,783],restLower:112,restWrist:-70,hand:'M398 731L420 600H690V1000L494 850Z',
      lower:'M51 927Q58 871 128 833L219 798L310 722L439 670L492 642L553 625L590 639L624 670L647 704L634 729L609 727L579 691L548 699L527 722L519 751L524 780L546 808L581 831L616 852L642 878L637 900L621 908L585 885L536 872L488 850L444 856L389 901L313 971L242 1031L192 1053L135 1049L82 1024L50 984Z'},
    {side:'right',shoulder:[875,704],elbow:[1073,1008],restElbow:[957,914],wrist:[842,791],restLower:-112,restWrist:70,hand:'M809 851L640 990H600V590H900L902 735Z',
      lower:'M1140 957L1125 1008L1086 1047L1024 1057L968 1032L904 984L850 932L815 872L786 848L751 863L711 887L677 905L652 910L638 894L645 875L682 852L719 835L752 812L769 784L770 749L755 721L736 702L712 692L685 719L669 730L651 727L642 711L651 688L676 655L717 631L749 632L781 648L821 681L845 733L867 782L925 809L1000 842L1076 868L1124 899Z'},
  ];
  const body=mask(`${prefix}-body`);body.append(element('rect',{width,height,fill:'white'}));
  for(const d of ['M0 521L321 535L401 645L356 782L298 892L287 1084L252 1372H0Z','M872 576L1147 549V1372H940L906 1125L918 892L872 837L872 755L826 672Z'])body.append(path(d,'black'));
  defs.append(body);
  const chassis=element('g',{'data-mechanism-part':'body'});chassis.append(picture(`${prefix}-body`,'/hall-e.webp'));rig.append(chassis);
  const metal=element('pattern',{id:`${prefix}-arm-metal`,patternUnits:'userSpaceOnUse',width:64,height:80});
  metal.append(element('image',{href:'/hall-e.webp',x:-470,y:-630,width,height}));defs.append(metal);
  for(const arm of arms){
    const upperMask=mask(`${prefix}-${arm.side}-upper`),lowerMask=mask(`${prefix}-${arm.side}-lower`),handMask=mask(`${prefix}-${arm.side}-hand`),forearmMask=mask(`${prefix}-${arm.side}-forearm`);
    const upperShape=arm.side==='left'?'M0 521L321 535L401 645L356 782L298 892L287 1084L252 1372H0Z':'M872 576L1147 549V1372H940L906 1125L918 892L872 837L872 755L826 672Z';
    const oldLower=arm.side==='left'?'M0 906L184 809L287 892L287 1084L252 1372H0Z':'M918 878L1021 823L1147 919V1372H940L906 1125Z';
    upperMask.append(path(upperShape,'white'),path(oldLower,'black'));lowerMask.append(path(arm.lower,'white'));
    handMask.append(path(arm.hand,'white'));forearmMask.append(path(arm.lower,'white'),path(arm.hand,'black'));defs.append(upperMask,lowerMask,handMask,forearmMask);
    const stage=element('g',{'data-mechanism-part':`${arm.side}-arm`});
    const upper=element('g',{'data-robot-arm':arm.side}),lower=element('g',{'data-robot-forearm':arm.side});
    const link=element('g');
    link.append(element('path',{d:`M${arm.shoulder.join(' ')}L${arm.elbow.join(' ')}`,stroke:'#111a1b','stroke-width':65,'stroke-linecap':'round'}));
    link.append(element('path',{d:`M${arm.shoulder.join(' ')}L${arm.elbow.join(' ')}`,stroke:`url(#${prefix}-arm-metal)`,'stroke-width':46,'stroke-linecap':'round'}));
    link.append(element('path',{d:`M${arm.shoulder.join(' ')}L${arm.elbow.join(' ')}`,stroke:'#b2a18588','stroke-width':4,'stroke-linecap':'round'}));
    const jointMask=mask(`${prefix}-${arm.side}-joint`);jointMask.append(element('circle',{cx:174,cy:841,r:48,fill:'white'}));defs.append(jointMask);
    const socket=element('g',{transform:`translate(${arm.elbow[0]-174} ${arm.elbow[1]-841})`});socket.append(picture(`${prefix}-${arm.side}-joint`,'/hall-e.webp'));
    const hand=element('g',{'data-robot-wrist':arm.side}),handClip=element('g',{mask:`url(#${prefix}-${arm.side}-hand)`});handClip.append(picture(`${prefix}-${arm.side}-lower`));hand.append(handClip);
    const wristMask=mask(`${prefix}-${arm.side}-wrist-joint`);wristMask.append(element('circle',{cx:arm.wrist[0],cy:arm.wrist[1],r:30,fill:'white'}));defs.append(wristMask);
    lower.append(picture(`${prefix}-${arm.side}-forearm`),hand,picture(`${prefix}-${arm.side}-wrist-joint`));upper.append(link,picture(`${prefix}-${arm.side}-upper`,'/hall-e.webp'),socket,lower);stage.append(upper);rig.append(stage);
    arm.lowerElement=lower;arm.handElement=hand;arm.link=link;arm.socket=socket;
  }
  const lens=(attrs={})=>element('ellipse',{cx:.58*width,cy:.5745*height,rx:.0385*width,ry:.0322*height,...attrs});
  const gradient=element('radialGradient',{id:`${prefix}-glow`});
  for(const [offset,color,opacity]of [[0,'#fff0c7',.9],[.18,'#ff6840',.8],[.45,'#ff291c',.45],[1,'#ff291c',0]])gradient.append(element('stop',{offset,'stop-color':color,'stop-opacity':opacity}));defs.append(gradient);
  const lensMask=mask(`${prefix}-lens`);lensMask.append(lens({fill:'white'}));defs.append(lensMask);
  const glow=element('g',{class:'robot-chest-glow'});glow.append(lens({rx:.11*width,ry:.092*height,fill:`url(#${prefix}-glow)`}));
  const lit=picture(`${prefix}-lens`,'/hall-e.webp');lit.setAttribute('class','robot-lit-lens');glow.append(lit);
  chassis.append(lens({class:'robot-chest-idle',fill:'#160300',opacity:.45}),glow);source.replaceWith(rig);
  let ready=false,frame=0,position=0,started=0,from=0,target=0,disposed=false;
  const pose=value=>{
    position=value;
    const e=Math.max(0,(value-.08)/.92),elbowEase=e*e*(3-2*e),blend=value*value*(3-2*value),spread=Math.sin(Math.PI*value)**2*32;
    for(const arm of arms){
      const dx=(arm.restElbow[0]-arm.elbow[0])*(1-blend)+(arm.side==='left'?-1:1)*spread,dy=(arm.restElbow[1]-arm.elbow[1])*(1-blend),length=.86+.14*blend;
      arm.lowerElement.setAttribute('transform',`translate(${dx} ${dy}) translate(${arm.elbow.join(' ')}) rotate(${arm.restLower*(1-elbowEase)}) scale(${length}) translate(${-arm.elbow[0]} ${-arm.elbow[1]})`);
      arm.handElement.setAttribute('transform',`rotate(${arm.restWrist*(1-blend)} ${arm.wrist.join(' ')})`);
      arm.socket.setAttribute('transform',`translate(${arm.elbow[0]+dx-174} ${arm.elbow[1]+dy-841})`);
      for(const rail of arm.link.children)rail.setAttribute('d',`M${arm.shoulder.join(' ')}L${arm.elbow[0]+dx} ${arm.elbow[1]+dy}`);
    }
  };
  pose(0);
  function tick(now){if(disposed)return;if(!started)started=now;const t=Math.min(1,(now-started)/1800);pose(from+(target-from)*t);if(t<1)frame=requestAnimationFrame(tick);else frame=0;}
  function update(){
    if(!ready||disposed)return;const next=host.dataset.engaged==='true'?1:0;
    if(preference.matches){cancelAnimationFrame(frame);frame=0;target=next;pose(target);return;}
    if(next===target&&frame)return;cancelAnimationFrame(frame);frame=0;target=next;from=position;started=0;if(position!==target)frame=requestAnimationFrame(tick);
  }
  const observer=new MutationObserver(update);observer.observe(host,{attributes:true,attributeFilter:['data-engaged']});preference.addEventListener('change',update);
  return {ready(){ready=true;update();},dispose(){disposed=true;cancelAnimationFrame(frame);observer.disconnect();preference.removeEventListener('change',update);}};
}
