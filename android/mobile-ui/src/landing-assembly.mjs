const NS='http://www.w3.org/2000/svg';
let sequence=0;
const svg=(tag,attrs={})=>{const node=document.createElementNS(NS,tag);for(const [key,value]of Object.entries(attrs))node.setAttribute(key,String(value));return node;};
const clamp=x=>Math.max(0,Math.min(1,x));
const smooth=x=>{x=clamp(x);return x*x*(3-2*x);};
// Startup moves the live rig wrappers; settling never replaces a bitmap or pose.
export function createMechanicalAssembly(decoded,root){
  const mechanism=root.querySelector('.mechanism'),defs=mechanism.querySelector('defs'),layer=mechanism.querySelector('.assembly-parts'),id=`assembly-${++sequence}`;
  const parts=[...root.querySelectorAll('[data-mechanism-part]')].map(node=>({node,side:node.dataset.mechanismPart}));
  const aura=svg('radialGradient',{id:`${id}-aura`});
  for(const [offset,opacity]of [[0,.2],[.4,.06],[1,0]])aura.append(svg('stop',{offset,'stop-color':'#84e6d0','stop-opacity':opacity}));defs.append(aura);
  const field=svg('g',{'aria-hidden':'true'});field.append(svg('ellipse',{cx:24,cy:35,rx:150,ry:170,fill:`url(#${id}-aura)`}));const orbit=svg('g');
  orbit.append(svg('ellipse',{cx:24,cy:35,rx:120,ry:52,stroke:'#77c6ba','stroke-opacity':.3,'stroke-width':.6,'stroke-dasharray':'76 24 5 15',fill:'none'}));
  orbit.append(svg('ellipse',{cx:24,cy:35,rx:77,ry:140,stroke:'#d0a56c','stroke-opacity':.25,'stroke-width':.7,'stroke-dasharray':'100 140',fill:'none'}));field.append(orbit);layer.append(field);
  return {duration:4.5,dispose(){field.remove();aura.remove();for(const {node}of parts){node.removeAttribute('transform');node.removeAttribute('opacity');}},render(time){
    const finish=smooth((time-3.2)/1.3);field.setAttribute('opacity',String((1-finish)*smooth(time/.6)));orbit.setAttribute('transform',`rotate(${time*31} 24 35)`);
    for(const {node,side}of parts){const arm=side!=='body',delay=arm?.55:0,t=clamp((time-delay)/(arm?3.6:3.8)),remaining=Math.pow(1-t,3),direction=side==='left-arm'?-1:1;node.setAttribute('transform',`translate(${arm?direction*70*remaining:0} ${arm?50*remaining:55*remaining})`);node.setAttribute('opacity',String(smooth(t/.38)));}
    root.dataset.assemblyPhase=time<1.3?'awakening':time<3.3?'forming':'settling';
  }};
}
