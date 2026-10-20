const NS='http://www.w3.org/2000/svg';
let sequence=0;
const svg=(tag,attrs={})=>{const node=document.createElementNS(NS,tag);for(const [key,value]of Object.entries(attrs))node.setAttribute(key,String(value));return node;};
const clamp=x=>Math.max(0,Math.min(1,x));
const smooth=x=>{x=clamp(x);return x*x*(3-2*x);};
// Real textured components settle along short, weighted paths into the original
// artwork. Every final mask is complementary, so the assembled rig never swaps.
export function createMechanicalAssembly(decoded,root){
  const mechanism=root.querySelector('.mechanism'),defs=mechanism.querySelector('defs'),layer=mechanism.querySelector('.assembly-parts');
  const image=decoded.get('/hall-e.webp'),w=image.naturalWidth,h=image.naturalHeight,scale=360/h,id=`assembly-${++sequence}`;
  const fit=svg('g',{transform:`translate(${-w*scale/2} -172) scale(${scale})`});
  const parts=[
    {name:'beacon',d:'M43 0H65V9H43Z',delay:1.15,x:0,y:-180,turn:8},
    {name:'left-optic',d:'M0 7H54V39H0Z',delay:.55,x:-130,y:-135,turn:-7},
    {name:'right-optic',d:'M54 6H100V40H54Z',delay:.7,x:125,y:-115,turn:6},
    {name:'neck',d:'M35 35H72V48H35Z',delay:.4,x:0,y:-70,turn:0},
    {name:'left-arm',d:'M0 38L28 39L35 47L31 57L26 65L25 79L22 100H0Z',delay:.7,x:-180,y:70,turn:-12},
    {name:'right-arm',d:'M76 42L100 40V100H82L79 82L80 65L76 61L76 55L72 49Z',delay:.85,x:180,y:50,turn:11},
    {name:'left-track',d:'M24 75H51V100H24Z',delay:.45,x:-55,y:185,turn:-3},
    {name:'right-track',d:'M51 75H80V100H51Z',delay:.6,x:60,y:170,turn:4},
    {name:'chassis',d:'M0 0H100V100H0Z',delay:0,x:0,y:35,turn:0},
  ];
  const preceding=[];
  for(const [i,part]of parts.entries()){
    const mask=svg('mask',{id:`${id}-${i}`,maskUnits:'userSpaceOnUse',x:0,y:0,width:w,height:h,'mask-type':'luminance'});
    const shape=(d,fill)=>svg('path',{d,fill,transform:`scale(${w/100} ${h/100})`});
    mask.append(shape(part.d,'white'));for(const d of preceding)mask.append(shape(d,'black'));preceding.push(part.d);defs.append(mask);
    const group=svg('g',{'data-assembly-part':part.name});group.append(svg('image',{href:'/hall-e.webp',width:w,height:h,mask:`url(#${id}-${i})`}));fit.append(group);part.element=group;
  }
  const aura=svg('radialGradient',{id:`${id}-aura`});
  for(const [offset,opacity]of [[0,.2],[.4,.06],[1,0]])aura.append(svg('stop',{offset,'stop-color':'#84e6d0','stop-opacity':opacity}));defs.append(aura);
  const field=svg('g',{'aria-hidden':'true'});field.append(svg('ellipse',{cx:24,cy:35,rx:150,ry:170,fill:`url(#${id}-aura)`}));
  const orbit=svg('g');
  orbit.append(svg('ellipse',{cx:24,cy:35,rx:120,ry:52,stroke:'#77c6ba','stroke-opacity':.3,'stroke-width':.6,'stroke-dasharray':'76 24 5 15',fill:'none'}));
  orbit.append(svg('ellipse',{cx:24,cy:35,rx:77,ry:140,stroke:'#d0a56c','stroke-opacity':.25,'stroke-width':.7,'stroke-dasharray':'100 140',fill:'none'}));field.append(orbit);layer.append(field,fit);
  return {duration:4.5,dispose(){field.remove();fit.remove();for(const n of [...defs.children])if(n.id.startsWith(id+'-'))n.remove();},render(time){
    const finish=smooth((time-3.2)/1.3);field.setAttribute('opacity',String((1-finish)*smooth(time/.6)));orbit.setAttribute('transform',`rotate(${time*31} 24 35)`);
    for(const part of parts){const t=clamp((time-part.delay)/2.65),p=1-Math.pow(1-t,3),remaining=1-p;part.element.setAttribute('transform',`translate(${part.x*remaining} ${part.y*remaining}) rotate(${part.turn*remaining} ${w/2} ${h/2})`);part.element.setAttribute('opacity',String(smooth(t/.42)));}
    root.dataset.assemblyPhase=time<1.3?'awakening':time<3.3?'forming':'settling';
  }};
}
