import markup from './landing-intro.svg';
import {createMechanicalAssembly} from './landing-assembly.mjs';

// This is the landing page's mechanical assembly, packaged locally. It never
// covers Record, and plays only once per cold app launch, not on tab navigation.
let shown = false;
export function mountIntro(host) {
  const still = document.createElement('img');
  still.src = '/hall-e.webp';
  still.alt = 'Hall-e';
  still.width = 164;
  still.height = 198;
  still.className = 'hero-character';
  const robot = document.createElement('div');
  robot.className = 'robot-art';
  robot.append(still);
  host.append(robot);
  const preference = window.matchMedia('(prefers-reduced-motion: reduce)');
  if (shown || preference.matches) { shown = true; return () => robot.remove(); }
  shown = true;
  const instrument = document.createElement('div');
  instrument.className = 'instrument landing-intro';
  instrument.setAttribute('aria-label', 'WALL-E y HAL se ensamblan para formar Hall-e');
  // Only the trusted, build-time SVG from our landing source is parsed here.
  const parsed = new DOMParser().parseFromString(markup, 'image/svg+xml');
  instrument.append(document.importNode(parsed.documentElement, true));
  const skip = document.createElement('button');
  skip.type = 'button';
  skip.className = 'intro-skip';
  skip.textContent = 'Omitir animación';
  let assembly, frame = 0, previous = null, elapsed = 0, disposed = false;
  let loadingTimer = 0;
  function finish() {
    disposed = true;
    clearTimeout(loadingTimer);
    cancelAnimationFrame(frame);
    assembly?.dispose();
    instrument.remove();
    skip.remove();
    robot.hidden = false;
    document.removeEventListener('visibilitychange', visibility);
    preference.removeEventListener('change', finish);
  }
  function tick(now) {
    if (disposed || document.hidden) { previous = null; return; }
    if (previous !== null) elapsed += (now - previous) / 1000;
    previous = now;
    if (elapsed >= assembly.duration) { finish(); return; }
    assembly.render(elapsed);
    frame = requestAnimationFrame(tick);
  }
  function visibility() {
    cancelAnimationFrame(frame);
    previous = null;
    if (!disposed && assembly && !document.hidden) frame = requestAnimationFrame(tick);
  }
  skip.addEventListener('click', finish);
  document.addEventListener('visibilitychange', visibility);
  preference.addEventListener('change', finish);
  // A missing optional asset must never leave the home surface waiting.
  loadingTimer = setTimeout(finish, 3000);
  Promise.all(['/hall-e.webp', '/wall-e.webp', '/hal.webp'].map(async url => {
    const image = new Image(); image.src = url; await image.decode(); return [url, image];
  })).then(images => {
    if (disposed) return;
    clearTimeout(loadingTimer);
    robot.hidden = true;
    host.append(instrument, skip);
    assembly = createMechanicalAssembly(new Map(images), instrument);
    instrument.classList.add('intro-playing');
    assembly.render(0);
    frame = requestAnimationFrame(tick);
  }).catch(error => { console.warn('Hall-e opening animation unavailable', error); finish(); });
  return () => { finish(); robot.remove(); };
}
