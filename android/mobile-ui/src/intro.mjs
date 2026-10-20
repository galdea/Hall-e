import markup from './landing-intro.svg';
import {createMechanicalAssembly} from './landing-assembly.mjs';
import {mountRobotRig} from './robot.mjs';

// Landing assembly, packaged locally. The final image stays in the same SVG at
// exactly the assembled coordinates: there is no replacement or last-frame jump.
let shown = false;
export function mountIntro(host) {
  const robot = document.createElement('div'); robot.className = 'robot-art';
  const still = document.createElement('img');
  Object.assign(still, {src:'/hall-e.webp', alt:'Hall-e', width:197, height:238, className:'hero-character'});
  robot.append(still); host.append(robot);
  const preference = window.matchMedia('(prefers-reduced-motion: reduce)');
  const playOpening=!shown&&!preference.matches; shown=true; robot.hidden=playOpening;
  const instrument = document.createElement('div'); instrument.className = 'instrument landing-intro';
  instrument.setAttribute('role','img');instrument.setAttribute('aria-label','Hall-e');
  const parsed = new DOMParser().parseFromString(markup, 'image/svg+xml');
  instrument.append(document.importNode(parsed.documentElement, true));
  const svg = instrument.querySelector('svg');
  let assembly, rig, frame=0, previous=null, elapsed=0, disposed=false, settled=false, loadingTimer=0, acceleration=null;
  function detachListeners() {
    document.removeEventListener('visibilitychange', visibility);
    preference.removeEventListener('change', reducedMotion);
  }
  function stopClock() { clearTimeout(loadingTimer); cancelAnimationFrame(frame); previous=null; }
  function fallback() {
    if (disposed) return;
    settled=true; stopClock(); assembly?.dispose(); detachListeners();
    instrument.remove(); rig?.dispose();robot.hidden=false;
  }
  function renderAt(time) {
    assembly.render(time);
    const t=Math.max(0,Math.min(1,(time-8.6)/2.5)); const p=t*t*(3-2*t);
    svg.setAttribute('viewBox', `${254*p} ${66*p} ${1000-508*p} ${620-172*p}`);
  }
  function settle() {
    renderAt(assembly.duration);
    settled=true; stopClock(); assembly.dispose(); detachListeners();
    // The source-mask union and this whole image have identical bounds/pixels.
    instrument.classList.remove('intro-playing');
    instrument.dataset.assemblyPhase='complete';
    rig.ready();
  }
  function tick(now) {
    if (disposed || settled || document.hidden) { previous=null; return; }
    if(host.dataset.engaged==='true'&&!acceleration)acceleration={at:now,from:elapsed};
    if(acceleration){const t=Math.min(1,(now-acceleration.at)/650);elapsed=acceleration.from+(assembly.duration-acceleration.from)*(t*t*(3-2*t));}
    else if(previous!==null) elapsed+=(now-previous)/1000; previous=now;
    if(elapsed>=assembly.duration) { settle(); return; }
    renderAt(elapsed); frame=requestAnimationFrame(tick);
  }
  function visibility() {
    cancelAnimationFrame(frame); previous=null;
    if(!disposed&&!settled&&assembly&&!document.hidden) frame=requestAnimationFrame(tick);
  }
  function reducedMotion() { if(preference.matches&&assembly&&!settled) settle(); }
  document.addEventListener('visibilitychange', visibility);
  preference.addEventListener('change', reducedMotion);
  loadingTimer=setTimeout(fallback,3000);
  Promise.all(['/hall-e.webp','/wall-e.webp','/hal.webp'].map(async url=>{
    const image=new Image(); image.src=url; await image.decode(); return [url,image];
  })).then(images=>{
    if(disposed||settled) return;
    clearTimeout(loadingTimer); host.append(instrument);robot.hidden=true;
    if(playOpening&&!preference.matches)assembly=createMechanicalAssembly(new Map(images),instrument);
    rig=mountRobotRig(svg,host,images[0][1],preference);
    if(assembly){instrument.classList.add('intro-playing');renderAt(0);frame=requestAnimationFrame(tick);}
    else{settled=true;svg.setAttribute('viewBox','254 66 492 448');instrument.dataset.assemblyPhase='complete';rig.ready();detachListeners();}
  }).catch(error=>{console.warn('Hall-e opening animation unavailable',error);fallback();});
  return ()=>{ disposed=true; stopClock(); assembly?.dispose(); rig?.dispose();detachListeners(); instrument.remove(); robot.remove(); };
}
