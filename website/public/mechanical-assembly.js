const SVG_NS = 'http://www.w3.org/2000/svg';
const DISASSEMBLE_AT = 2.6;
const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));
const mix = (from, to, progress) => from + (to - from) * progress;
const smooth = (value) => value * value * (3 - 2 * value);
const easeOut = (value) => 1 - (1 - value) ** 3;
const between = (time, start, end) => clamp((time - start) / (end - start));
const point = (from, to, progress) => ({ x: mix(from.x, to.x, progress), y: mix(from.y, to.y, progress) });
const rect = (x, y, width, height) => ['rect', { x, y, width, height }];
const path = (d) => ['path', { d }];
const ellipse = (cx, cy, rx, ry) => ['ellipse', { cx, cy, rx, ry }];

// Authored cuts follow the eyes, joints, housings, chassis and tracks. Earlier
// masks take priority; the last one receives every remaining source pixel.
const wallParts = [
  { name: 'left-optic', shape: path('M0 0H60L59 27H0Z'), anchor: [49, 16] },
  { name: 'right-optic', shape: path('M60 0H100V27H59Z'), anchor: [68, 13] },
  { name: 'neck-piston', shape: path('M36 24L65 23L63 41L38 42Z'), anchor: [50, 32] },
  { name: 'left-arm', shape: path('M18 40L34 42L52 64L51 73L36 70L18 51Z'), anchor: [35, 54] },
  { name: 'right-arm', shape: path('M72 40L100 44V67L82 65L77 53Z'), anchor: [84, 51] },
  { name: 'left-track', shape: path('M0 59L28 56L47 73L50 100H0Z'), anchor: [28, 79] },
  { name: 'right-track', shape: path('M74 54H100V100H55L57 77Z'), anchor: [80, 76] },
  { name: 'upper-chassis', shape: path('M18 35L79 34L78 54L43 57L23 47Z'), anchor: [54, 43] },
  { name: 'front-chassis', shape: path('M23 49H79L76 76L43 81L24 70Z'), anchor: [57, 64] },
  { name: 'chassis-frame', shape: rect(0, 0, 100, 100), anchor: [49, 60] },
];
const halParts = [
  { name: 'red-lens', shape: ellipse(53, 31, 12.8, 14.8), anchor: [53, 31] },
  { name: 'lens-housing', shape: ellipse(53, 31, 16.8, 18.4), anchor: [53, 31] },
  { name: 'top-cover', shape: rect(0, 0, 100, 14), anchor: [52, 7] },
  { name: 'left-rail', shape: path('M0 0H35V100H0Z'), anchor: [33, 43] },
  { name: 'right-rail', shape: path('M69 0H100V100H69Z'), anchor: [70, 43] },
  { name: 'speaker-panel', shape: rect(35, 65, 34, 21), anchor: [53, 75] },
  { name: 'base-plate', shape: rect(0, 86, 100, 14), anchor: [53, 93] },
  { name: 'internal-frame', shape: rect(0, 0, 100, 100), anchor: [53, 55] },
];

// A destination for each source component, in matching array order. Assembly
// order is independent of mask priority: frame, armor, head, optics, then beacon.
const destinations = [
  { shape: ellipse(41, 24.5, 8.2, 7.4), anchor: [41, 24.5], order: 13 },
  { shape: ellipse(65, 21.4, 7.6, 7.4), anchor: [65, 21.4], order: 14 },
  { shape: path('M38 35L68 33L71 47L65 51L38 48Z'), anchor: [52, 42.5], order: 4 },
  { shape: path('M0 38L33 39L39 46L32 59L20 64L0 62Z'), anchor: [25, 50], order: 5 },
  { shape: path('M71 42L100 40V64L79 66L71 56Z'), anchor: [79, 52], order: 6 },
  { shape: path('M0 62H20L32 57L34 76L28 100H0Z'), anchor: [12, 75], order: 9 },
  { shape: path('M80 62H100V100H73L72 80Z'), anchor: [86, 75], order: 10 },
  { shape: path('M17 8H50L54 16V35L47 38L25 39L16 33Z'), anchor: [37, 25], order: 11 },
  { shape: path('M23 76H78V100H23Z'), anchor: [52, 84], order: 1 },
  { shape: path('M29 45H43L47 68L44 78L27 77Z'), anchor: [38, 58], order: 2 },
  { shape: ellipse(58.3, 57.6, 5, 6.4), anchor: [58.3, 57.6], order: 15 },
  { shape: path('M50 8L85 6L88 31L80 35L55 36L54 16Z'), anchor: [68, 24], order: 12 },
  { shape: path('M43 0H65V9H43Z'), anchor: [53, 5], order: 17 },
  { shape: path('M0 0H17L22 15L25 39H0Z'), anchor: [20, 24], order: 7 },
  { shape: path('M85 0H100V40L81 39L80 35L88 31Z'), anchor: [82, 21], order: 8 },
  { shape: path('M37 46H71L76 59L72 69L69 75L44 74L37 63Z'), anchor: [56, 62], order: 3 },
  { shape: path('M28 68H77L80 81H27Z'), anchor: [53, 76], order: 16 },
  { shape: rect(0, 0, 100, 100), anchor: [50, 47], order: 0 },
];

function svg(tag, attributes = {}) {
  const element = document.createElementNS(SVG_NS, tag);
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, String(value));
  return element;
}

function setVisible(element, visible) {
  // SVG descendants can override inherited visibility. Display removes the
  // complete subtree, including components left seated by an earlier replay.
  if (element.hasAttribute('data-motion-hidden') === visible) element.toggleAttribute('data-motion-hidden', !visible);
}

function maskFor(id, shape, preceding, definitions) {
  const mask = svg('mask', { id, maskUnits: 'userSpaceOnUse', x: 0, y: 0, width: 100, height: 100, 'mask-type': 'luminance' });
  mask.append(svg(shape[0], { ...shape[1], fill: 'white' }));
  for (const prior of preceding) mask.append(svg(prior[0], { ...prior[1], fill: 'black' }));
  definitions.append(mask);
  return id;
}

function imageBounds(element, image) {
  const width = Number(element.getAttribute('width'));
  const height = Number(element.getAttribute('height'));
  const scale = Math.min(width / image.naturalWidth, height / image.naturalHeight);
  const fittedWidth = image.naturalWidth * scale;
  const fittedHeight = image.naturalHeight * scale;
  return {
    x: Number(element.getAttribute('x')) + (width - fittedWidth) / 2,
    y: Number(element.getAttribute('y')) + (height - fittedHeight) / 2,
    width: fittedWidth,
    height: fittedHeight,
    url: element.getAttribute('href'),
  };
}

function anchorIn(bounds, anchor) {
  return { x: bounds.x + bounds.width * anchor[0] / 100, y: bounds.y + bounds.height * anchor[1] / 100 };
}

function partArtwork(bounds, mask, anchor, portrait = false) {
  const local = svg('g', { transform: `translate(${-anchor.x} ${-anchor.y})` });
  const clipped = svg('g', portrait ? { 'clip-path': 'url(#portraitWindow)' } : {});
  const fitted = svg('g', { transform: `translate(${bounds.x} ${bounds.y}) scale(${bounds.width / 100} ${bounds.height / 100})` });
  fitted.append(svg('image', { href: bounds.url, width: 100, height: 100, preserveAspectRatio: 'none', mask: `url(#${mask})` }));
  clipped.append(fitted);
  local.append(clipped);
  return local;
}

function createParts(decoded, mechanism, partsLayer) {
  const definitions = mechanism.querySelector('defs');
  const targetElement = mechanism.querySelector('.hall-e-art');
  const targetBounds = imageBounds(targetElement, decoded.get(targetElement.getAttribute('href')));
  const previousTargets = [];
  const parts = [];
  let destinationIndex = 0;
  for (const [name, side, components] of [['wall-e', -1, wallParts], ['hal', 1, halParts]]) {
    const sourceElement = mechanism.querySelector(`.${name}-art`);
    const bounds = imageBounds(sourceElement, decoded.get(sourceElement.getAttribute('href')));
    const previousSources = [];
    for (const component of components) {
      const index = destinationIndex++;
      const destination = destinations[index];
      const sourceAnchor = anchorIn(bounds, component.anchor);
      const targetAnchor = anchorIn(targetBounds, destination.anchor);
      const sourceMask = maskFor(`source-part-${index}`, component.shape, previousSources, definitions);
      const targetMask = maskFor(`target-part-${index}`, destination.shape, previousTargets, definitions);
      previousSources.push(component.shape);
      previousTargets.push(destination.shape);
      const element = svg('g', { class: 'assembly-part', 'data-mechanical-part': component.name, 'data-source': name });
      const source = partArtwork(bounds, sourceMask, sourceAnchor);
      const target = partArtwork(targetBounds, targetMask, targetAnchor, true);
      element.append(source, target);
      partsLayer.append(element);
      const start = { x: side * 213 + sourceAnchor.x, y: sourceAnchor.y };
      const spread = {
        x: clamp(start.x + (component.anchor[0] - 50) * 1.35 + side * 20, -390, 390),
        y: clamp(start.y + (component.anchor[1] - 48) * 1.2, -211, 175),
      };
      const direction = Math.atan2(targetAnchor.y - 5, targetAnchor.x || side);
      const distance = 40 + (index % 4) * 10;
      const staging = { x: targetAnchor.x + Math.cos(direction) * distance, y: targetAnchor.y + Math.sin(direction) * distance };
      parts.push({
        element, source, target, start, spread, staging, targetAnchor, side,
        delay: (index % 4) * 0.085,
        turn: (index % 2 === 0 ? -1 : 1) * (16 + index % 5 * 4),
        lockAt: 6.4 + destination.order * 0.14,
      });
    }
  }
  return parts;
}

function curve(from, controlA, controlB, to, progress) {
  const inverse = 1 - progress;
  return {
    x: inverse ** 3 * from.x + 3 * inverse ** 2 * progress * controlA.x + 3 * inverse * progress ** 2 * controlB.x + progress ** 3 * to.x,
    y: inverse ** 3 * from.y + 3 * inverse ** 2 * progress * controlA.y + 3 * inverse * progress ** 2 * controlB.y + progress ** 3 * to.y,
  };
}

function pose(element, position, rotation = 0, yaw = 0, scale = 1) {
  const angle = rotation * Math.PI / 180;
  const tilt = yaw * Math.PI / 180;
  const horizontal = Math.max(0.045, Math.abs(Math.cos(tilt))) * scale;
  const shear = Math.sin(tilt) * 0.12;
  const cosine = Math.cos(angle);
  const sine = Math.sin(angle);
  const matrix = [cosine * horizontal, sine * horizontal, (cosine * shear - sine) * scale, (sine * shear + cosine) * scale, position.x, position.y];
  element.setAttribute('transform', `matrix(${matrix.map((value) => value.toFixed(4)).join(' ')})`);
}

function renderPart(part, time) {
  const detach = between(time, DISASSEMBLE_AT + part.delay, 4.05 + part.delay);
  const transit = between(time, 4.05 + part.delay, 6.2 + part.delay * 0.5);
  const locking = between(time, part.lockAt, part.lockAt + 0.95);
  let position;
  let rotation;
  let yaw;
  let scale = 1;
  if (transit === 0) {
    const progress = smooth(detach);
    position = point(part.start, part.spread, progress);
    rotation = part.turn * progress;
    yaw = part.side * 26 * progress;
  } else if (transit < 1) {
    position = curve(part.spread,
      { x: part.spread.x - part.side * 86, y: part.spread.y - 38 },
      { x: part.staging.x + part.side * 88, y: part.staging.y - 45 },
      part.staging, smooth(transit));
    // Reconfigure the housing at its narrow, edge-on orientation, without a
    // whole-character dissolve. Source and target keep one continuous path.
    const firstHalf = transit < 0.5;
    const fold = smooth(firstHalf ? transit * 2 : (transit - 0.5) * 2);
    yaw = part.side * (firstHalf ? mix(26, 87.4, fold) : mix(87.4, 22, fold));
    rotation = mix(part.turn, -part.turn * 0.45, smooth(transit));
    scale = firstHalf ? mix(1, 0.9, fold) : mix(1.08, 1, fold);
  } else {
    // A small final axial seat gives each component weight without a springy bounce.
    const travel = locking < 0.88 ? easeOut(locking / 0.88) * 1.012 : mix(1.012, 1, smooth((locking - 0.88) / 0.12));
    position = point(part.staging, part.targetAnchor, travel);
    rotation = -part.turn * 0.45 * (1 - smooth(locking));
    yaw = part.side * 22 * (1 - smooth(locking));
  }
  setVisible(part.source, transit < 0.5);
  setVisible(part.target, transit >= 0.5);
  pose(part.element, position, rotation, yaw, scale);
}

/** Construct once after decoding; render only transforms and visibility on replay. */
export function createMechanicalAssembly(decoded) {
  const mechanism = document.querySelector('.mechanism');
  const instrument = document.querySelector('.instrument');
  const partsLayer = mechanism.querySelector('.assembly-parts');
  const caption = mechanism.querySelector('.assembly-status text');
  const heart = mechanism.querySelector('.heart-flight');
  const mind = mechanism.querySelector('.mind-flight');
  const parts = createParts(decoded, mechanism, partsLayer);
  const frame = svg('g', { class: 'assembly-frame' });
  heart.before(frame);
  frame.append(heart, mind, partsLayer);
  let fittedScale = 1;
  let lastTime = 0;

  function frameAt(time) {
    // Keep the loose pieces inside the available width. Ease back to the exact
    // portrait scale before the final seat, so the static handoff cannot jump.
    const progress = smooth(between(time, 4.35, 9.7));
    frame.setAttribute('transform', `scale(${mix(fittedScale, 1, progress).toFixed(5)})`);
  }

  function measureFrame() {
    const viewport = mechanism.getBoundingClientRect();
    const bounds = instrument.getBoundingClientRect();
    const units = Math.min(viewport.width / 1000, viewport.height / 620);
    if (units <= 0) return;
    const center = viewport.left + viewport.width / 2;
    const left = Math.max(0, bounds.left) + 16;
    const right = Math.min(document.documentElement.clientWidth, bounds.right) - 16;
    // The 540-unit envelope includes component edges, rotation and shadows;
    // clamping only their anchor points still lets tracks and rails clip.
    fittedScale = clamp(Math.min(center - left, right - center) / (540 * units), 0.1, 1);
    frameAt(lastTime);
  }

  measureFrame();
  const resizeObserver = new ResizeObserver(measureFrame);
  resizeObserver.observe(instrument);
  resizeObserver.observe(mechanism);

  return {
    duration: 10.6,
    render(time) {
      lastTime = time;
      frameAt(time);
      const arriving = time < DISASSEMBLE_AT;
      setVisible(heart, arriving);
      setVisible(mind, arriving);
      setVisible(partsLayer, !arriving);
      if (arriving) {
        const progress = easeOut(between(time, 0, 1.7));
        const distance = mix(fittedScale < 1 ? 360 : 500, 213, progress);
        pose(heart, { x: -distance, y: mix(15, 0, progress) }, mix(-6, 0, progress));
        pose(mind, { x: distance, y: mix(10, 0, progress) }, mix(4, 0, progress));
        const opacity = smooth(between(time, 0, 0.45));
        heart.setAttribute('opacity', String(opacity));
        mind.setAttribute('opacity', String(opacity));
      } else {
        for (const part of parts) renderPart(part, time);
      }
      const phase = arriving ? 'origins' : time < 4.2 ? 'disassembly' : time < 6.4 ? 'reconfiguration' : 'assembly';
      if (instrument.dataset.assemblyPhase !== phase) {
        instrument.dataset.assemblyPhase = phase;
        caption.textContent = { origins: 'HEART + MIND', disassembly: 'MECHANICAL DISASSEMBLY', reconfiguration: 'RECONFIGURING', assembly: 'ASSEMBLING HALL-E' }[phase];
      }
    },
  };
}
