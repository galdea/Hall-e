import markup from './landing-intro.svg';
import {createMechanicalAssembly} from './landing-assembly.mjs';

// Landing assembly, packaged locally. The final image stays in the same SVG at
// exactly the assembled coordinates: there is no replacement or last-frame jump.
let shown = false;
export function mountIntro(host) {
  const robot = document.createElement('div'); robot.className = 'robot-art';
  const still = document.createElement('img');
  Object.assign(still, {src:'/hall-e.webp', alt:'Hall-e', width:164, height:198, className:'hero-character'});
  robot.append(still); host.append(robot);
  const preference = window.matchMedia('(prefers-reduced-motion: reduce)');
  if (shown || preference.matches) { shown = true; return () => robot.remove(); }
  shown = true; robot.hidden = true;
  const instrument = document.createElement('div'); instrument.className = 'instrument landing-intro';
  instrument.setAttribute('aria-label', 'WALL-E y HAL se ensamblan para formar Hall-e');
  const parsed = new DOMParser().parseFromString(markup, 'image/svg+xml');
  instrument.append(document.importNode(parsed.documentElement, true));
  const svg = instrument.querySelector('svg');
  let assembly, frame=0, previous=null, elapsed=0, disposed=false, settled=false, loadingTimer=0;
  function detachListeners() {
    document.removeEventListener('visibilitychange', visibility);
    preference.removeEventListener('change', reducedMotion);
  }
  function stopClock() { clearTimeout(loadingTimer); cancelAnimationFrame(frame); previous=null; }
  function fallback() {
    if (disposed) return;
    settled=true; stopClock(); assembly?.dispose(); detachListeners();
    instrument.remove(); robot.hidden=false;
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
  }
  function tick(now) {
    if (disposed || settled || document.hidden) { previous=null; return; }
    if(previous!==null) elapsed+=(now-previous)/1000; previous=now;
    if(elapsed>=assembly.duration) { settle(); return; }
    renderAt(elapsed); frame=requestAnimationFrame(tick);
  }
  function visibility() {
    cancelAnimationFrame(frame); previous=null;
    if(!disposed&&!settled&&assembly&&!document.hidden) frame=requestAnimationFrame(tick);
  }
  function reducedMotion() { if(preference.matches) fallback(); }
  document.addEventListener('visibilitychange', visibility);
  preference.addEventListener('change', reducedMotion);
  loadingTimer=setTimeout(fallback,3000);
  Promise.all(['/hall-e.webp','/wall-e.webp','/hal.webp'].map(async url=>{
    const image=new Image(); image.src=url; await image.decode(); return [url,image];
  })).then(images=>{
    if(disposed||settled) return;
    clearTimeout(loadingTimer); host.append(instrument);
    assembly=createMechanicalAssembly(new Map(images),instrument);
    instrument.classList.add('intro-playing'); renderAt(0);
    frame=requestAnimationFrame(tick);
  }).catch(error=>{console.warn('Hall-e opening animation unavailable',error);fallback();});
  return ()=>{ disposed=true; stopClock(); assembly?.dispose(); detachListeners(); instrument.remove(); robot.remove(); };
}
