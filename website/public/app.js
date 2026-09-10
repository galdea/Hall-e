import { createMechanicalAssembly } from './mechanical-assembly.js?v=4';

(() => {
  'use strict';

  const body = document.body;
  const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
  const toggle = document.querySelector('.motion-toggle');
  const replay = document.querySelector('.replay');
  const instrument = document.querySelector('.instrument');
  const dialog = document.querySelector('.install-dialog');
  let paused = false;
  let playing = false;
  let animationFrame = 0;
  let previousTime = null;
  let elapsed = 0;
  let assembly = null;
  let artworkReady = false;

  function stopClock() {
    cancelAnimationFrame(animationFrame);
    animationFrame = 0;
    previousTime = null;
  }

  function finishIntro() {
    playing = false;
    stopClock();
    // The seated pieces have the same coordinates and crop as the static image.
    // A single-frame handoff preserves the approved final portrait exactly.
    body.classList.remove('intro-playing');
    instrument.dataset.assemblyPhase = 'complete';
  }

  function tick(timestamp) {
    if (!playing || paused || document.hidden || motionPreference.matches) {
      stopClock();
      return;
    }
    if (previousTime !== null) elapsed += (timestamp - previousTime) / 1000;
    previousTime = timestamp;
    if (elapsed >= assembly.duration) {
      finishIntro();
      return;
    }
    assembly.render(elapsed);
    animationFrame = requestAnimationFrame(tick);
  }

  function syncClock() {
    stopClock();
    if (playing && !paused && !document.hidden && !motionPreference.matches) animationFrame = requestAnimationFrame(tick);
  }

  function syncMotionControls() {
    toggle.setAttribute('aria-pressed', String(paused));
    const label = paused ? 'Resume motion' : 'Pause motion';
    toggle.setAttribute('aria-label', label);
    toggle.querySelector('span').textContent = label;
    toggle.hidden = motionPreference.matches || !artworkReady;
    replay.hidden = motionPreference.matches || !artworkReady;
    body.classList.toggle('motion-paused', paused);
    syncClock();
  }

  function playIntro() {
    if (motionPreference.matches || !artworkReady) return;
    elapsed = 0;
    playing = true;
    paused = false;
    assembly.render(0);
    body.classList.add('intro-playing');
    syncMotionControls();
  }

  function applyMotionPreference() {
    const reduced = motionPreference.matches;
    finishIntro();
    body.classList.toggle('still', reduced);
    paused = false;
    syncMotionControls();
    if (!reduced) playIntro();
  }

  toggle.addEventListener('click', () => {
    paused = !paused;
    syncMotionControls();
  });
  replay.addEventListener('click', playIntro);
  motionPreference.addEventListener('change', applyMotionPreference);
  applyMotionPreference();

  // Pause the animation clock while the page is hidden, preserving a manual pause.
  function syncVisibility() {
    body.classList.toggle('tab-inactive', document.hidden);
    syncClock();
  }
  document.addEventListener('visibilitychange', syncVisibility);
  syncVisibility();

  // Decode every character before starting: a slow connection must not make the
  // characters arrive invisibly. The final portrait and download links are
  // already in the HTML and remain available without this enhancement.
  const artworkURLs = [...new Set([...document.querySelectorAll('[data-character-art]')]
    .map((element) => element.getAttribute('href')))];
  Promise.all(artworkURLs.map(async (url) => {
    const image = new Image();
    image.src = url;
    await image.decode();
    return [url, image];
  })).then((images) => {
    assembly = createMechanicalAssembly(new Map(images));
    artworkReady = true;
    syncMotionControls();
    if (!paused) playIntro();
  }).catch(() => {
    // Keep the static composition if any of the optional animation assets fail.
    artworkReady = false;
    finishIntro();
    syncMotionControls();
  });

  // Native links remain working fallbacks when JavaScript or dialog support is absent.
  if (typeof dialog.showModal === 'function') {
    for (const id of ['install-help', 'first-launch-help']) {
      document.getElementById(id).addEventListener('click', (event) => {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
        event.preventDefault();
        dialog.showModal();
      });
    }
    dialog.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
    dialog.addEventListener('click', (event) => {
      if (event.target !== dialog) return;
      const bounds = dialog.getBoundingClientRect();
      if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
    });
  }
})();
