'use strict';
// Shift release film. render(t) draws the frame at time t (seconds); nothing depends on wall-clock time.

const W = 1920, H = 1080, DURATION = 60;
window.DURATION = DURATION;

// ---------- math ----------
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, p) => a + (b - a) * p;
const E = {
  linear: p => p,
  outCubic: p => 1 - Math.pow(1 - p, 3),
  inCubic: p => p * p * p,
  inOutCubic: p => p < .5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2,
  inOutSine: p => -(Math.cos(Math.PI * p) - 1) / 2,
  outQuint: p => 1 - Math.pow(1 - p, 5),
  inOutQuint: p => p < .5 ? 16 * p ** 5 : 1 - Math.pow(-2 * p + 2, 5) / 2,
  outExpo: p => p >= 1 ? 1 : 1 - Math.pow(2, -10 * p),
  inExpo: p => p <= 0 ? 0 : Math.pow(2, 10 * p - 10),
  inOutExpo: p => p <= 0 ? 0 : p >= 1 ? 1 : p < .5 ? Math.pow(2, 20 * p - 10) / 2 : (2 - Math.pow(2, -20 * p + 10)) / 2,
  outBack: p => { const c1 = 1.4, c3 = c1 + 1; return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2); },
};
/** Progress of an animation that starts at t0 and lasts dur, eased. */
const P = (t, t0, dur, ease = E.outExpo) => ease(clamp((t - t0) / dur));
/** Damped spring from 0 to 1, dt seconds after it starts. */
function spring(dt, freq = 2.4, damp = .5) {
  if (dt <= 0) return 0;
  const w = 2 * Math.PI * freq, wd = w * Math.sqrt(1 - damp * damp);
  return 1 - Math.exp(-damp * w * dt) * (Math.cos(wd * dt) + (damp * w / wd) * Math.sin(wd * dt));
}
/** Interpolates keyframes [[t, ...values]] with an ease per segment. */
function keys(t, list, ease = E.inOutCubic) {
  if (t <= list[0][0]) return list[0].slice(1);
  for (let i = 0; i < list.length - 1; i++) {
    const a = list[i], b = list[i + 1];
    if (t <= b[0]) {
      const p = ease((t - a[0]) / (b[0] - a[0]));
      return a.slice(1).map((v, k) => lerp(v, b[k + 1], p));
    }
  }
  return list[list.length - 1].slice(1);
}
function rng(seed) {
  return () => {
    seed |= 0; seed = seed + 0x6D2B79F5 | 0;
    let r = Math.imul(seed ^ seed >>> 15, 1 | seed);
    r = r + Math.imul(r ^ r >>> 7, 61 | r) ^ r;
    return ((r ^ r >>> 14) >>> 0) / 4294967296;
  };
}

// ---------- DOM helpers ----------
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
function el(html) { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; }
function tf(node, { x = 0, y = 0, s = 1, sx, sy, r = 0, rx = 0, ry = 0, z = 0, o, blur } = {}) {
  node.style.transform = `translate3d(${x.toFixed(2)}px,${y.toFixed(2)}px,${z}px) rotateX(${rx}deg) rotateY(${ry}deg) rotate(${r}deg) scale(${(sx ?? s).toFixed(4)},${(sy ?? s).toFixed(4)})`;
  if (o !== undefined) node.style.opacity = clamp(o).toFixed(3);
  if (blur !== undefined) node.style.filter = blur > .05 ? `blur(${blur.toFixed(2)}px)` : 'none';
}
const vis = (node, on) => { node.style.visibility = on ? 'visible' : 'hidden'; };
const op = (node, v) => { node.style.opacity = clamp(v).toFixed(3); };
/** Masked line reveal: lines slide up into view at tin, and up out of view at tout. */
function lines(node, t, tin, tout, { stagger = .07, dur = .9, outDur = .4 } = {}) {
  const spans = node._spans || (node._spans = $$('.ln > span', node));
  spans.forEach((s, i) => {
    const pin = P(t, tin + i * stagger, dur, E.outExpo);
    const pout = tout == null ? 0 : P(t, tout + i * stagger * .5, outDur, E.inCubic);
    s.style.transform = `translateY(${((1 - pin) * 155 - pout * 155).toFixed(2)}%)`;
  });
}
const L = text => text.split('\n').map(l => `<span class="ln"><span>${l}</span></span>`).join('');

// ---------- icons (SF Symbol lookalikes) ----------
const SHIFT_PATH = 'M12 2.6 L21.4 12.3 H16.3 V20.8 H7.7 V12.3 H2.6 Z';
const I = {
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3c3.2 3.2 3.2 14.8 0 18"/><path d="M12 3c-3.2 3.2-3.2 14.8 0 18"/>',
  cycle: '<path d="M4.5 11a7.5 7.5 0 0 1 13-4.2L19.5 9"/><path d="M19.5 4v5h-5"/><path d="M19.5 13a7.5 7.5 0 0 1-13 4.2L4.5 15"/><path d="M4.5 20v-5h5"/>',
  down: '<path d="M12 4v11"/><path d="M7 10.5l5 5 5-5"/><path d="M5 20h14"/>',
  shrink: '<path d="M4 4l6 6"/><path d="M10 5v5H5"/><path d="M20 20l-6-6"/><path d="M14 19v-5h5"/>',
  doc: '<rect x="5" y="3" width="14" height="18" rx="2"/><rect x="8" y="6.5" width="4.5" height="4" rx=".6"/><path d="M14.5 7.5h1.5M8 14h8M8 17.5h5.5"/>',
  ocr: '<path d="M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16"/><path d="M8 9h8M8 12h8M8 15h5"/>',
  film: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M7.5 4v16M16.5 4v16M3 9h4.5M3 15h4.5M16.5 9H21M16.5 15H21"/>',
  wave: '<path d="M4 10v4M8 6.5v11M12 3.5v17M16 7.5v9M20 10.5v3"/>',
  caption: '<path d="M5 4.5h14A2 2 0 0 1 21 6.5v9a2 2 0 0 1-2 2h-8l-4.5 3.5v-3.5H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2z"/><path d="M7 9.5h4M13 9.5h4M7 13h7"/>',
  hash: '<path d="M9.5 3.5L7.5 20.5M16.5 3.5l-2 17M4.5 9h16M3.5 15h16"/>',
  pages: '<rect x="6.5" y="3" width="14.5" height="13" rx="2"/><path d="M3 7.5V18a2 2 0 0 0 2 2h12"/><path d="M9 13.5l3-3.5 3 3 1.8-1.8 2.2 2.3"/>',
  text: '<path d="M4 6h16M4 10h11M4 14h16M4 18h9"/>',
  tray: '<path d="M3 13.5h5l1.5 2.5h5l1.5-2.5h5"/><path d="M3 13.5L5.5 7H9M15 7h3.5L21 13.5V19H3z"/><path d="M12 3v8.5M9 8.5l3 3 3-3"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  shift: `<path d="${SHIFT_PATH}"/>`,
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  cloud: '<path d="M7 18.5h10.5a4 4 0 0 0 .6-7.95A6 6 0 0 0 6.6 9.6 4.5 4.5 0 0 0 7 18.5z"/>',
  lock: '<rect x="5" y="10.5" width="14" height="10" rx="2.2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>',
  hand: '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V11M11 10.5V4a1.5 1.5 0 0 1 3 0v6.5M14 10.5V5.5a1.5 1.5 0 0 1 3 0V14a6.5 6.5 0 0 1-6.5 6.5c-2.3 0-3.6-1-4.9-2.7L3.5 15a1.6 1.6 0 0 1 2.4-2l2.1 2"/>',
  dots: '<circle cx="5" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.3" fill="currentColor" stroke="none"/>',
  chev: '<path d="M6 15l6-6 6 6"/>',
  sparkle: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M18 6l-2.5 2.5M8.5 15.5L6 18"/>',
  arrowDown: '<path d="M12 4v15M6 13l6 6 6-6"/>',
  wifi: '<path d="M2.5 9a14 14 0 0 1 19 0"/><path d="M5.5 12.3a9.5 9.5 0 0 1 13 0"/><path d="M8.7 15.5a5 5 0 0 1 6.6 0"/><circle cx="12" cy="18.8" r="1" fill="currentColor"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  apps: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
  image: '<rect x="3" y="5" width="18" height="14" rx="2.5"/><circle cx="9" cy="10" r="1.6"/><path d="M4 17l5-5 4 4 2.5-2.5L20 18"/>',
};
const icon = (name, size = 24, sw = 2) =>
  `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round">${I[name]}</svg>`;
const shiftFill = (size, color = '#fff') =>
  `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24"><path d="${SHIFT_PATH}" fill="${color}" stroke="${color}" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
const appleLogo = '<svg width="15" height="18" viewBox="0 0 17 20"><path fill="#fff" d="M14.1 10.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9C3.6 4.8 2 5.8 1.1 7.4c-1.9 3.2-.5 8 1.3 10.6.9 1.3 1.9 2.7 3.3 2.6 1.3-.1 1.8-.9 3.4-.9s2 .9 3.4.8c1.4 0 2.3-1.3 3.2-2.6 1-1.5 1.4-2.9 1.4-3 0 0-2.7-1-3-4.3zM11.6 3c.7-.9 1.2-2 1.1-3.2-1 0-2.3.7-3 1.6-.7.8-1.3 2-1.1 3.1 1.1.1 2.3-.6 3-1.5z"/></svg>';

// ---------- images ----------
let gradientId = 0;
function photo(kind) {
  const id = `g${gradientId++}`;
  const S = {
    sunset: `<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b1b5a"/><stop offset=".5" stop-color="#e2557a"/><stop offset=".8" stop-color="#ffb36b"/></linearGradient></defs>
      <rect width="300" height="200" fill="url(#${id})"/><circle cx="196" cy="118" r="30" fill="#ffe3a3"/>
      <path d="M0 138 L56 96 L106 128 L168 78 L232 124 L300 92 V200 H0Z" fill="#7a3474"/>
      <path d="M0 162 L52 130 L122 158 L192 118 L262 156 L300 138 V200 H0Z" fill="#43195a"/>
      <path d="M0 184 L82 160 L162 182 L242 158 L300 174 V200 H0Z" fill="#1e0d31"/>`,
    ocean: `<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6cc6ff"/><stop offset=".52" stop-color="#e6f6ff"/><stop offset=".53" stop-color="#1683c9"/><stop offset="1" stop-color="#05416e"/></linearGradient></defs>
      <rect width="300" height="200" fill="url(#${id})"/><circle cx="80" cy="60" r="18" fill="#fffbe6"/>
      <path d="M0 132 Q40 126 80 132 T160 132 T240 132 T320 132" stroke="#9fdcff" stroke-width="3" fill="none" opacity=".7"/>
      <path d="M0 152 Q40 146 80 152 T160 152 T240 152 T320 152" stroke="#9fdcff" stroke-width="3" fill="none" opacity=".5"/>
      <path d="M0 176 Q90 150 180 170 T300 160 V200 H0Z" fill="#f3dcae"/>`,
    city: `<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1b2a6b"/><stop offset=".7" stop-color="#f08a5d"/></linearGradient></defs>
      <rect width="300" height="200" fill="url(#${id})"/>
      <g fill="#141a33"><rect x="10" y="90" width="40" height="110"/><rect x="56" y="60" width="34" height="140"/><rect x="96" y="110" width="44" height="90"/><rect x="146" y="40" width="30" height="160"/><rect x="182" y="96" width="48" height="104"/><rect x="236" y="70" width="30" height="130"/><rect x="270" y="120" width="30" height="80"/></g>
      <g fill="#ffd57a">${Array.from({ length: 40 }, (_, i) => `<rect x="${[16, 62, 102, 150, 188, 240, 276][i % 7] + (i % 3) * 8}" y="${[100, 70, 120, 50, 106, 80, 130][i % 7] + Math.floor(i / 7) * 14}" width="4" height="5"/>`).join('')}</g>`,
    portrait: `<defs><radialGradient id="${id}" cx=".5" cy=".4" r=".7"><stop offset="0" stop-color="#e7d3bf"/><stop offset="1" stop-color="#8a7464"/></radialGradient></defs>
      <rect width="300" height="200" fill="url(#${id})"/>
      <ellipse cx="150" cy="86" rx="34" ry="42" fill="#3b2a24"/><path d="M70 200 Q78 132 150 128 Q222 132 230 200Z" fill="#2a1f1c"/>
      <path d="M118 70 Q150 30 184 72" stroke="#f3c79a" stroke-width="4" fill="none" opacity=".6"/>`,
    whiteboard: `<rect width="300" height="200" fill="#f4f4ef"/>
      <text x="26" y="52" font-family="Marker Felt, Chalkboard, sans-serif" font-size="30" fill="#1e3a8a">Q4 plan</text>
      <path d="M28 82 h120 M28 108 h170 M28 134 h96" stroke="#1d1d1f" stroke-width="5" stroke-linecap="round" opacity=".7"/>
      <circle cx="232" cy="120" r="34" stroke="#d93025" stroke-width="5" fill="none"/>`,
    call: `<rect width="300" height="200" fill="#1c1c1e"/>
      <rect x="8" y="8" width="138" height="88" rx="8" fill="#3a4a6b"/><rect x="154" y="8" width="138" height="88" rx="8" fill="#5b3a4a"/>
      <rect x="8" y="104" width="138" height="88" rx="8" fill="#3a5b4a"/><rect x="154" y="104" width="138" height="88" rx="8" fill="#5b553a"/>
      <g fill="#d8c3b0"><circle cx="77" cy="46" r="18"/><circle cx="223" cy="46" r="18"/><circle cx="77" cy="142" r="18"/><circle cx="223" cy="142" r="18"/></g>
      <g fill="#20242c"><path d="M45 96 Q77 66 109 96Z"/><path d="M191 96 Q223 66 255 96Z"/><path d="M45 192 Q77 162 109 192Z"/><path d="M191 192 Q223 162 255 192Z"/></g>`,
  };
  return `<svg viewBox="0 0 300 200" preserveAspectRatio="xMidYMid slice" width="100%" height="100%" style="display:block">${S[kind]}</svg>`;
}
function thumb(kind, w, h = w) {
  if (kind === 'pdf' || kind === 'md') {
    const pw = Math.round(h * .76);
    const label = kind === 'pdf' ? `<div style="position:absolute;left:0;right:0;bottom:${h * .12}px;text-align:center;font:800 ${Math.max(6, h * .17)}px var(--sft);color:#e5352b">PDF</div>`
      : `<div style="position:absolute;left:${pw * .16}px;top:${h * .12}px;font:800 ${h * .26}px var(--sft);color:#0a7aff">#</div>`;
    const lines = Array.from({ length: 4 }, (_, i) => `<div style="height:${Math.max(1, h * .04)}px;margin:${h * .06}px ${pw * .16}px;background:#d1d1d6;border-radius:1px;width:${[70, 58, 66, 44][i]}%"></div>`).join('');
    return `<div style="width:${w}px;height:${h}px;display:flex;justify-content:center;flex:none"><div class="thumb" style="width:${pw}px;height:${h}px;border-radius:${h * .06}px;padding-top:${kind === 'md' ? h * .4 : h * .14}px">${lines}${label}</div></div>`;
  }
  return `<div class="thumb" style="width:${w}px;height:${h}px;border-radius:${Math.max(3, h * .12)}px">${photo(kind)}</div>`;
}

// ---------- action catalogue ----------
const A = {
  web: { ic: 'globe', title: 'Web preset', sub: 'WebP · max 2000 px · quality 78' },
  jpg: { ic: 'cycle', title: 'To JPG', sub: 'Opens everywhere' },
  png: { ic: 'cycle', title: 'To PNG', sub: 'Lossless, keeps transparency' },
  webp: { ic: 'cycle', title: 'To WebP', sub: 'Small and sharp, works across the web' },
  compress: { ic: 'down', title: 'Compress', sub: 'Smallest (auto) · same size · quality 72' },
  half: { ic: 'shrink', title: '50%', sub: '50% · quality 88' },
  m1920: { ic: 'shrink', title: 'Max 1920 px', sub: 'max 1920 px · quality 88' },
  onepdf: { ic: 'doc', title: 'One PDF', sub: 'All images in one document' },
  mdImg: { ic: 'ocr', title: 'To Markdown', sub: 'Recognize text (OCR)' },
  v1080: { ic: 'film', title: 'Web 1080p', sub: 'H.264 MP4 · max 1080p · standard quality' },
  v720: { ic: 'film', title: 'Web 720p', sub: 'H.264 MP4 · max 720p · standard quality' },
  mp4: { ic: 'film', title: 'To MP4', sub: 'Same quality, plays everywhere' },
  audio: { ic: 'wave', title: 'Audio only', sub: 'Audio as M4A' },
  mdAV: { ic: 'caption', title: 'To Markdown', sub: 'Transcript with timestamps' },
  pdfc: { ic: 'down', title: 'Compress', sub: 'Images at 144 dpi · quality 70' },
  mdPdf: { ic: 'hash', title: 'To Markdown', sub: 'Text with headings and lists' },
  pPng: { ic: 'pages', title: 'Pages to PNG', sub: 'Every page at 2x resolution' },
  pJpg: { ic: 'pages', title: 'Pages to JPG', sub: 'Every page at 2x resolution' },
  toPdf: { ic: 'doc', title: 'To PDF', sub: 'A4, with page numbers' },
  mdDoc: { ic: 'hash', title: 'To Markdown', sub: 'Headings, lists, links and tables' },
  plain: { ic: 'text', title: 'Plain text', sub: 'Formatting stripped, just the text' },
  m4a: { ic: 'wave', title: 'To M4A', sub: 'AAC in M4A' },
  avif: { ic: 'cycle', title: 'To AVIF', sub: 'Even smaller than WebP' },
};
function tileHTML(a, index, primary, cls = 'tile') {
  return `<div class="${cls} ${primary ? 'primary' : ''}"><div class="hb"></div><div class="t-top">${icon(a.ic, 26, 2.2)}${index != null && index < 9 ? `<span class="kc">${index + 1}</span>` : ''}</div>
    <div class="t-title">${a.title}</div><div class="t-sub">${a.sub}</div><div class="hl"></div></div>`;
}
function barHTML(id, { thumbs, title, size, groups, columns }) {
  let n = 0;
  const groupHTML = groups.map(g => {
    const tiles = g.actions.map((a, i) => tileHTML(A[a], n++, i === 0));
    const gaps = Array.from({ length: columns - g.actions.length }, () => '<div class="gap"></div>');
    return `<div class="grp">${g.label ? `<div class="g-label">${g.label}</div>` : ''}<div class="g-row">${tiles.join('')}${gaps.join('')}</div></div>`;
  }).join('');
  return `<div id="${id}" class="glass bar"><div class="bar-in">
    <div class="bar-head">
      <div class="stack">${thumbs.map((k, i) => `<div class="st" style="transform:translateX(${i * 3}px) rotate(${-6 * i}deg);z-index:${10 - i}">${thumb(k, 36)}</div>`).join('')}</div>
      <div><div class="bh-title">${title}</div><div class="bh-sub">${size}</div></div>
      <div class="sp"></div>
      <div class="bh-hint"><span class="h-drag">Drop on an action</span><span class="h-click">Click or press 1–9 · Esc closes</span></div>
      <div class="park">${icon('tray', 16, 1.8)}To Shelf</div>
      <div class="xbtn">${icon('x', 12, 2.4)}</div>
    </div>${groupHTML}</div>
    <div class="bar-work"><div class="spin"></div><div class="w-title">Web preset…</div><div class="w-track"><div class="w-fill"></div></div><div class="w-count">0/1</div></div>
  </div>`;
}

// ---------- build ----------
const stage = $('#stage');
const add = (html, parent = stage) => { const n = el(html); parent.appendChild(n); return n; };

// S1: the grind
const s1 = add('<div id="s1" class="scene"></div>');
const SHARDS = {
  upload: `<div class="shard light sh-upload"><b>Uploading IMG_4821.jpg…</b><div class="track"><i></i></div><div class="muted">37% · about 2 minutes remaining</div></div>`,
  export: `<div class="shard light sh-export"><b style="font-size:17px">Export As: IMG_4821.jpg</b>
    <div class="row" style="margin-top:10px"><span>Format</span><span class="pop">JPEG ⌄</span></div>
    <div class="row"><span>Quality</span><span style="width:200px;height:4px;background:#c7c7cc;border-radius:2px;position:relative"><i style="position:absolute;left:68%;top:-7px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.35)"></i></span></div>
    <div class="row" style="border:0"><span>File Size</span><span class="muted" style="font-size:15px">8.4 MB</span></div>
    <div class="btns"><span>Cancel</span><span class="p">Save</span></div></div>`,
  spin: `<div class="shard dark sh-spin"><div class="spinner"></div>Converting…</div>`,
  web: `<div class="shard light sh-web"><div class="chrome"><i></i><i></i><i></i><div class="url">free-image-convert-online.web/upload</div></div>
    <div class="body"><h4>Convert to WebP. Online. Free!*</h4><div class="up">Upload file</div><div class="muted">*Max 5 MB. Sign up for more.</div><div class="ad">SPONSORED</div></div></div>`,
  rename: `<div class="shard light sh-rename">${thumb('sunset', 44, 32)}<span class="field"><span class="sel">IMG_4821-final-v3-small-FINAL</span>.jpg<span class="caret"></span></span></div>`,
  alert: `<div class="shard light sh-alert"><svg class="warn" viewBox="0 0 64 58"><path d="M32 4 L61 54 H3 Z" fill="#ffcc00" stroke="#ffcc00" stroke-width="6" stroke-linejoin="round"/><rect x="29" y="20" width="6" height="20" rx="3" fill="#1d1d1f"/><circle cx="32" cy="47" r="3.5" fill="#1d1d1f"/></svg>
    <b>File is too large</b><div class="muted">The maximum upload size is 10 MB.</div><div class="btn">OK</div></div>`,
  dl: `<div class="shard light sh-dl"><div class="fi"></div><div><b style="font-size:16px">IMG_4821 (2).webp</b><div class="muted">Done · 1.9 MB</div></div></div>`,
};
const shardPlan = [
  ['upload', 1.25, 1330, 210, 4], ['export', 1.75, 420, 790, -5], ['spin', 2.25, 1480, 840, 3], ['web', 2.75, 400, 250, -4],
  ['dl', 3.25, 1560, 470, 5], ['rename', 3.6, 990, 900, -2], ['alert', 3.9, 1560, 700, 6], ['upload', 4.15, 330, 540, -7],
  ['alert', 4.4, 760, 170, -3], ['spin', 4.6, 1180, 1000, 5], ['dl', 4.8, 1600, 230, -6], ['export', 4.9, 220, 900, 4],
].map(([k, t, x, y, r], i) => ({ node: add(SHARDS[k], s1), t, x, y, r, i }));
const WORDS = [
  [0.5, 'Export.'], [1.0, 'Resize.'], [1.5, 'Compress.'], [2.0, 'Upload.'], [2.5, 'Wait.'], [3.0, 'Download.'], [3.5, 'Rename.'],
  [4.0, 'Too big.', 'dim'], [4.25, 'Again.'], [4.5, 'Again.'], [4.75, 'Again.'], [5.0, 'Every single time.', 'small'],
].map(([t, text, cls]) => ({ t, node: add(`<div class="word ${cls || ''}">${text}</div>`, s1) }));
const dot = add('<div class="dot"></div>', s1);

// S2: the turn
const s2 = add('<div id="s2" class="scene"></div>');
const line1 = add(`<div class="line1">${L("There’s a shorter way.")}</div>`, s2);
const glow = add('<div id="glow"></div>', s2);
const ring = add('<div id="ring"></div>', s2);
const ring2 = add('<div id="ring" style="border-color:rgba(255,255,255,.5)"></div>', s2);
const keywrap = add('<div id="keywrap"></div>', s2);
const key = add(`<div id="key"><div class="kfill"></div>
  <div class="kglyph kout">${icon('shift', 100, 1.5)}</div>
  <div class="kglyph kin" style="opacity:0">${shiftFill(100)}</div>
  <div class="klabel">shift</div></div>`, keywrap);
const word = add(`<div id="word">${[...'Shift'].map(c => `<span class="ch">${c}</span>`).join('')}</div>`, s2);
const tagline = add('<div id="tagline"><span>Drag.</span><span>Hold Shift.</span><span class="done">Done.</span></div>', s2);

// S3: desktop demo
const s3 = add('<div id="s3" class="scene" style="perspective:2200px"></div>');
const s3bg = add('<div class="abs" style="inset:0;background:radial-gradient(ellipse at 72% 50%, #0c1730 0%, #050608 60%)"></div>', s3);
const deskcard = add('<div class="abs" style="left:0;top:0;width:1920px;height:1080px;transform-origin:960px 540px;overflow:hidden"></div>', s3);
const desk = add('<div id="desk"></div>', deskcard);
add(`<div id="menubar">${appleLogo}<b>Finder</b><span>File</span><span>Edit</span><span>View</span><span>Go</span><span>Window</span><span>Help</span>
  <div class="r"><span style="opacity:.95">${icon('shift', 17, 2)}</span>${icon('wifi', 17, 1.8)}<span style="display:inline-block;width:26px;height:12px;border:1.5px solid #fff;border-radius:3.5px;position:relative"><i style="position:absolute;left:1.5px;top:1.5px;bottom:1.5px;width:16px;background:#fff;border-radius:1.5px"></i></span><span>Thu 22 Oct  10:41</span></div></div>`, desk);
const FILES = [
  ['IMG_4821.jpg', '8.4 MB', 'JPEG image', 'sunset'],
  ['Hero-banner.png', '6.1 MB', 'PNG image', 'ocean'],
  ['Team-offsite.jpg', '4.7 MB', 'JPEG image', 'city'],
  ['Studio-portrait.heic', '3.2 MB', 'HEIF image', 'portrait'],
  ['Kickoff-call.mov', '312 MB', 'QuickTime movie', 'call'],
  ['Brand-guide.pdf', '24.6 MB', 'PDF document', 'pdf'],
  ['Notes.md', '4 KB', 'Markdown', 'md'],
];
const finder = add(`<div id="finder" class="win">
  <div class="side"><div class="tl"><i></i><i></i><i></i></div><div class="h">Favorites</div>
    <div class="it">${icon('clock', 15, 1.8)}Recents</div><div class="it">${icon('apps', 15, 1.8)}Applications</div><div class="it">${icon('folder', 15, 1.8)}Desktop</div>
    <div class="it">${icon('doc', 15, 1.8)}Documents</div><div class="it on">${icon('arrowDown', 15, 1.8)}Downloads</div></div>
  <div class="main"><div class="tb"><span class="nav">‹ ›</span>Autumn shoot</div>
    <div class="hd"><div class="fcol1">Name</div><div class="fcol2">Size</div><div class="fcol3">Kind</div></div>
    <div class="rows">${FILES.map(f => `<div class="frow"><div class="fcol1 fn">${thumb(f[3], 22, 18)}<span>${f[0]}</span></div><div class="fcol2">${f[1]}</div><div class="fcol3">${f[2]}</div></div>`).join('')}</div>
    <div id="marquee"></div></div></div>`, desk);
const frows = $$('.frow', finder);
const marquee = $('#marquee', finder);
const composer = add(`<div id="composer" class="win">
  <div class="tb"><div class="tl"><i></i><i></i><i></i></div><span>Journal</span><span class="crumb">/ Articles / New</span><span class="pub">Publish</span></div>
  <div class="body"><div class="kick">NEW ARTICLE</div><h3>Autumn shoot: behind the scenes</h3>
    <div id="zone"><div style="color:#aeaeb2">${icon('image', 34, 1.6)}</div><span>Drop a cover image</span>
      <div class="zimg">${photo('sunset')}</div><div class="zchip">IMG_4821-web.webp · 412 KB</div></div>
    <div class="para"><i style="width:94%"></i><i style="width:88%"></i><i style="width:62%"></i></div></div></div>`, desk);
const zone = $('#zone', composer);

const bar1 = add(barHTML('bar1', {
  thumbs: ['sunset'], title: 'IMG_4821.jpg', size: '8.4 MB', columns: 7,
  groups: [{ actions: ['web', 'png', 'webp', 'compress', 'half', 'm1920', 'mdImg'] }],
}), desk);
const bar2 = add(barHTML('bar2', {
  thumbs: ['ocean', 'city', 'portrait'], title: '3 images, 1 video, 1 PDF', size: '350.6 MB', columns: 9,
  groups: [
    { label: '3 IMAGES', actions: ['web', 'jpg', 'png', 'webp', 'compress', 'half', 'm1920', 'onepdf', 'mdImg'] },
    { label: '1 VIDEO', actions: ['v1080', 'v720', 'mp4', 'audio', 'mdAV'] },
    { label: '1 PDF', actions: ['pdfc', 'mdPdf', 'pPng', 'pJpg'] },
  ],
}), desk);
$('.w-count', bar2).textContent = '0/3';

const SHELF_ROWS = [
  ['IMG_4821-web.webp', 'sunset', '8.4 MB → 412 KB', '−95%'],
  ['Hero-banner-web.webp', 'ocean', '6.1 MB → 298 KB', '−95%'],
  ['Team-offsite-web.webp', 'city', '4.7 MB → 356 KB', '−92%'],
  ['Studio-portrait-web.webp', 'portrait', '3.2 MB → 264 KB', '−92%'],
];
const shelf = add(`<div id="shelf" class="glass"><div class="grip"></div>
  <div class="sh-h">${shiftFill(13, '#1d1d1f')}<span class="cnt"><span class="c1">1 ready</span><span class="c4" style="opacity:0">4 ready</span></span>
    <div class="sp"></div><div class="dall">${icon('hand', 12, 1.8)}Drag all</div><span class="icb">${icon('dots', 14)}</span><span class="icb">${icon('chev', 11, 2.4)}</span><span class="icb">${icon('x', 11, 2.4)}</span></div>
  <div class="rows">${[1, 2, 3, 0].map(i => { const r = SHELF_ROWS[i]; return `<div class="srow" data-i="${i}"><div class="sbg"></div>${thumb(r[1], 40)}<div style="position:relative;min-width:0"><div class="sn">${r[0]}</div><div class="sm">${r[2]}<b>${r[3]}</b></div></div></div>`; }).join('')}</div></div>`, desk);
const srows = $$('.srow', shelf); // display order: Hero, Team, Studio, IMG_4821
const callout = add('<div id="callout"><div class="big">−95%</div><div class="sizes">8.4 MB → 412 KB</div></div>', desk);
const ghost = add(`<div id="ghost"><div class="g1"></div><div class="gname"></div><div class="badge">5</div></div>`, desk);
const cursor = add(`<svg id="cursor" viewBox="0 0 32 32"><path d="M9 4.5 L9 24.2 L13.6 19.9 L16.7 27 L20 25.6 L16.9 18.6 L23.2 18.6 Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`, desk);

const caps = add('<div id="caps"><div class="scrim"></div></div>', s3);
const CAPTIONS = [
  [12.45, 14.6, '01', 'Drag any file.'],
  [14.75, 16.45, '02', 'Hold Shift.'],
  [16.5, 18.45, '03', 'Drop it on what you need.'],
  [18.55, 20.5, '04', 'Results wait on the shelf.'],
  [20.6, 23.45, '05', 'Then drag them where they go.', 'Figma, Slack, Mail, your CMS.'],
  [23.55, 25.4, '06', 'Grab a whole batch.'],
  [25.5, 26.85, '07', 'Mixed files, sorted by type.'],
  [26.9, 28.7, '08', 'Or skip the mouse.', 'Press 1–9. Return runs the first.'],
].map(([tin, tout, num, txt, sub], i, all) => ({ tin, tout: i < all.length - 1 ? Math.min(tout, all[i + 1][0] - .3) : tout, node: add(`<div class="cap"><div class="num">${L(num)}</div><div class="txt">${L(txt)}</div>${sub ? `<div class="sub">${L(sub)}</div>` : ''}</div>`, caps) }));
const hud = add(`<div id="hud"><div class="hkey hshift">${icon('shift', 40, 2.2)}<span>shift</span></div><div class="hkey h1" style="width:92px">1</div></div>`, s3);
const hshift = $('.hshift', hud), h1 = $('.h1', hud);

// S4: USPs
const s4 = add('<div id="s4" class="scene"><div class="bloom"></div></div>');
const usp = (n, kicker, title, body) => add(`<div class="usp"><div class="copy"><div class="kicker">${L(`${n} <span>/</span> ${kicker}`)}</div><h2>${L(title)}</h2><p>${L(body)}</p></div><div class="visual"></div></div>`, s4);
const U = [
  usp('01', 'Markdown', 'Anything becomes\nMarkdown.', 'Text from images through OCR. Clean text\nfrom PDFs and documents. Transcripts of\naudio and video, Dutch included.'),
  usp('02', 'Compression', 'Smaller.\nNever bigger.', 'If compression doesn’t win, Shift keeps\nthe original. Metadata stripped, colors\nin sRGB, ready for the web.'),
  usp('03', 'Settings', 'Tuned to how\nyou work.', 'Edit the presets, choose which actions\nshow up and in what order, pick your\nown trigger keys.'),
  usp('04', 'Privacy', 'Nothing leaves\nyour Mac.', 'Everything runs on-device, transcription\nincluded. No account, no uploads, no\nspecial permissions.'),
  usp('05', 'CLI', 'Also in your\nterminal.', 'The same engine, scriptable from the\ncommand line. And the app keeps itself\nup to date.'),
];
// USP 1 visual
const v1 = $('.visual', U[0]);
const chips1 = [
  ['whiteboard', 'Whiteboard.jpg', 'Text recognition'],
  ['pdf', 'Brand-guide.pdf', 'Headings and lists'],
  ['call', 'Kickoff-call.mov', 'Transcript, on-device'],
].map(([k, n, s], i) => add(`<div class="chip" style="left:1010px;top:${300 + i * 170}px">${thumb(k, 76, 54)}<div><div class="cn">${n}</div><div class="cs">${s}</div></div></div>`, v1));
const flows1 = [0, 1, 2].map(i => add(`<div class="flow" style="left:1290px;top:${341 + i * 170}px;width:80px"></div>`, v1));
const md = add(`<div class="card md"><div class="mh">${icon('hash', 16, 2)}Kickoff-call.md</div><div class="mb"></div></div>`, v1);
const mdBody = $('.mb', md);
const MD_TEXT = '# Kick-off\n\n[00:00] Welkom allemaal, fijn dat\n        jullie er zijn.\n[00:06] Eerst de planning, dan\n        de presets.\n\n## Actiepunten\n- Release op 22 oktober\n- Presets delen met het team';
const mdPill = add(`<div class="pill" style="left:1360px;top:850px">${icon('lock', 18, 2)}On-device · no internet needed</div>`, v1);
// USP 2 visual
const v2 = $('.visual', U[1]);
const CMP = [
  ['IMG_4821.jpg', 8.4e6, 412e3, '−95%'],
  ['Brand-guide.pdf', 24.6e6, 3.2e6, '−87%'],
  ['Kickoff-call.mov', 312e6, 41e6, '−87%'],
  ['logo.png', 18e3, 18e3, 'Original kept'],
].map(([name, a, b, label], i) => {
  const node = add(`<div class="cmp" style="top:${290 + i * 140}px"><div class="cl"><span>${name}</span><span class="v"><span class="num"></span><b class="${i === 3 ? 'keep' : ''}">${label}</b></span></div>
    <div class="tr"><div class="ob" style="width:100%"></div><div class="fb"></div></div></div>`, v2);
  return { node, a, b, i, num: $('.num', node), fb: $('.fb', node), lab: $('b', node) };
});
// USP 3 visual
const v3 = $('.visual', U[2]);
const keyRow = add(`<div class="keys">${['⌃', '⌥', 'shift', '⌘', 'fn'].map(k => `<div class="k ${k === 'fn' ? 'fn' : ''}"><div class="on"></div><span>${k === 'shift' ? icon('shift', 50, 2) : k}</span></div>`).join('')}</div>`, v3);
const kEls = $$('.k', keyRow);
const preset = add(`<div class="card preset"><div class="pt"><span style="color:#5eb0ff">${icon('globe', 26, 2)}</span>Web preset</div>
  <div class="pr"><span>Format</span><span class="pv">WebP</span></div>
  <div class="pr"><span>Longest side</span><span class="pv">2000 px</span></div>
  <div class="pr"><span>Quality</span><span style="display:flex;align-items:center"><span class="slider"><span class="sf"></span><span class="kn"></span></span><span class="pv qv">78</span></span></div></div>`, v3);
const sf = $('.sf', preset), kn = $('.kn', preset), qv = $('.qv', preset);
// USP 4 visual
const v4 = $('.visual', U[3]);
const mac = add('<div class="mac"></div>', v4);
add('<div class="macbase"></div>', v4);
const macIcon = add(`<div class="appicon" style="left:265px;top:145px;width:110px;height:110px">${shiftFill(54)}</div>`, mac);
const orbs = ['sunset', 'pdf', 'call', 'ocean', 'md', 'city'].map(k => add(`<div class="orb">${thumb(k, 64, 46)}</div>`, mac));
const cloud = add(`<div class="cloud">${icon('cloud', 120, 1.4)}</div>`, v4);
const cut = add('<div class="cut"></div>', v4);
const slash = add('<div class="abs" style="left:1580px;top:120px;width:6px;height:90px;border-radius:3px;background:#ff453a;box-shadow:0 0 20px rgba(255,69,58,.6)"></div>', v4);
const stamps = add(`<div class="stamps">${['No uploads', 'No account', 'No permissions'].map(s => `<div class="stamp">${icon('check', 20, 2.6)}${s}</div>`).join('')}</div>`, v4);
const stampEls = $$('.stamp', stamps);
// USP 5 visual
const v5 = $('.visual', U[4]);
const term = add(`<div class="card term"><div class="th"><div class="tl"><i></i><i></i><i></i></div><div class="tt">~/shoot — zsh</div></div><div class="tb"></div></div>`, v5);
const termBody = $('.tb', term);
const CMD = 'shift-cli web --out ~/Desktop/web *.jpg';
const OUT = [
  '✓ /Users/mike/Desktop/web/IMG_4821-web.webp  8.4 MB → 412 KB (-95%)',
  '✓ /Users/mike/Desktop/web/Team-offsite-web.webp  4.7 MB → 356 KB (-92%)',
  '✓ /Users/mike/Desktop/web/Market-hall-web.webp  5.2 MB → 391 KB (-92%)',
  '✓ /Users/mike/Desktop/web/Night-street-web.webp  3.9 MB → 287 KB (-92%)',
];
const upd = add(`<div class="card upd"><span style="color:#5eb0ff">${icon('sparkle', 30, 2)}</span><div><div class="ut">Updates itself</div><div class="us">Checks for new versions every day</div></div></div>`, v5);

// S5: wall of actions
const s5 = add('<div id="s5" class="scene"></div>');
const plane = add('<div id="plane"></div>', s5);
const wallKeys = Object.keys(A);
const wr = rng(7);
const wrows = Array.from({ length: 9 }, (_, r) => {
  const tiles = Array.from({ length: 16 }, () => {
    const k = wallKeys[Math.floor(wr() * wallKeys.length)];
    return tileHTML(A[k], null, wr() < .16, 'wtile');
  }).join('');
  return add(`<div class="wrow">${tiles}</div>`, plane);
});
add('<div id="wallfog"></div>', s5);
const wallTitle = add(`<div id="walltitle">${L('Every file.')}<span class="ln b"><span>One key.</span></span></div>`, s5);

// S6: end card
const s6 = add('<div id="s6" class="scene"><div class="bloom"></div></div>');
const endIcon = add(`<div id="endicon" class="appicon">${shiftFill(98)}</div>`, s6);
const endWord = add(`<div id="endword">${[...'Shift'].map(c => `<span class="ch" style="display:inline-block">${c}</span>`).join('')}</div>`, s6);
const endTag = add('<div id="endtag"><span>Drag.</span> <span>Hold Shift.</span> <span class="done">Done.</span></div>', s6);
const cta = add(`<div id="cta"><div class="btn">${appleLogo.replace('width="15" height="18"', 'width="24" height="28"')}Free for macOS</div><div class="url">github.com/mike-hendriks/shift</div></div>`, s6);
const endFoot = add('<div id="endfoot"><span>macOS 15 or later · Apple Silicon</span><span>Made by <b>Stuurmen</b></span></div>', s6);

// overlays
const vignette = add('<div id="vignette"></div>');
const grain = add('<div id="grain"></div>');
const flash = add('<div id="flash"></div>');
const fade = add('<div id="fade"></div>');
{
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const g = c.getContext('2d'), img = g.createImageData(256, 256), r = rng(3);
  for (let i = 0; i < img.data.length; i += 4) { const v = r() * 255; img.data[i] = img.data[i + 1] = img.data[i + 2] = v; img.data[i + 3] = 255; }
  g.putImageData(img, 0, 0);
  grain.style.backgroundImage = `url(${c.toDataURL()})`;
}

// ---------- layout measurements (desk coordinates) ----------
const M = {};
function measure() {
  const d = desk.getBoundingClientRect(), k = d.width / W;
  const box = n => { const r = n.getBoundingClientRect(); return { x: (r.left - d.left) / k, y: (r.top - d.top) / k, w: r.width / k, h: r.height / k, cx: (r.left - d.left + r.width / 2) / k, cy: (r.top - d.top + r.height / 2) / k }; };
  M.rows = frows.map(box);
  M.tile1 = $$('.tile', bar1).map(box);
  M.tile2 = $$('.tile', bar2).map(box);
  M.bar1H = bar1.offsetHeight;
  M.bar2H = bar2.offsetHeight;
  M.zone = box(zone);
  M.shelfTop = box(shelf).y;
  M.rowsBox = box($('.rows', finder));
  M.main = box($('.main', finder));
  M.bar2Head = box($('.bh-hint', bar2));
  // shelf rows in display order; row 3 (IMG_4821) sits at the bottom
  M.srow = srows.map(box);
  WORDS.forEach(w => { w.w = w.node.offsetWidth; w.h = w.node.offsetHeight; });
  shardPlan.forEach(s => { s.w = s.node.offsetWidth; s.h = s.node.offsetHeight; });
  M.wordW = word.offsetWidth;
  M.wordH = word.offsetHeight;
}

// ---------- audio cues (read by audio.py) ----------
const CUES = [];
const cue = (t, type, gain = 1) => CUES.push({ t: +t.toFixed(3), type, gain });
WORDS.forEach((w, i) => cue(w.t, i < 7 ? 'hit' : 'hit2'));
shardPlan.forEach(s => cue(s.t, 'glitch', .55));
cue(4.4, 'riser'); cue(6.5, 'cutoff');
cue(6.75, 'bell', .6); cue(8.0, 'whooshUp'); cue(9.0, 'impact');
cue(10.5, 'pluck'); cue(11.0, 'pluck'); cue(11.5, 'pluck', 1.2); cue(11.55, 'whoosh');
cue(13.15, 'click'); cue(15.0, 'key'); cue(15.0, 'slide'); cue(16.75, 'tick'); cue(17.5, 'drop'); cue(18.4, 'done', .7);
cue(18.55, 'pop'); cue(18.85, 'count'); cue(21.0, 'click'); cue(21.95, 'tick'); cue(22.3, 'drop');
cue(23.75, 'click', .7); cue(24.8, 'click'); cue(25.5, 'key'); cue(25.5, 'slide'); cue(26.05, 'drop', .6);
cue(27.0, 'key'); cue(27.85, 'done', .7); cue(27.95, 'pop'); cue(28.07, 'pop'); cue(28.19, 'pop'); cue(28.8, 'whoosh'); cue(29.55, 'whoosh');
[30, 34, 38, 42, 46].forEach(t => cue(t, 'hitSoft'));
for (let i = 0; i < 26; i++) cue(30.6 + i * .1, 'type', .35);
[38.3, 39.2, 39.8, 40.2, 40.8].forEach(t => cue(t, 'key', .6));
cue(43.0, 'glitch', .5); [43.4, 43.7, 44.0].forEach(t => cue(t, 'pop'));
for (let i = 0; i < CMD.length; i++) if (i % 2 === 0) cue(46.3 + i * (1 / CMD.length), 'type', .4);
[47.45, 47.57, 47.69, 47.81].forEach(t => cue(t, 'tick', .6));
cue(48.2, 'pop');
cue(49.6, 'whoosh'); cue(50.5, 'hitSoft'); cue(51.5, 'hitSoft'); cue(52.0, 'riser');
cue(53.9, 'whooshUp'); cue(54.0, 'impact', 1.1);
cue(55.0, 'pluck'); cue(55.5, 'pluck'); cue(56.0, 'pluck', 1.2); cue(56.5, 'pop');
window.CUES = CUES;

// ---------- scenes ----------
function renderS1(t) {
  const on = t < 6.55; vis(s1, on); if (!on) return;
  const collapse = P(t, 5.5, .8, E.inExpo);
  // shards
  for (const s of shardPlan) {
    const dt = t - s.t;
    if (dt < 0) { s.node.style.visibility = 'hidden'; continue; }
    s.node.style.visibility = 'visible';
    const sp = spring(dt, 3.2, .45);
    const stress = P(t, 3.9, 1.5, E.inCubic);
    const jx = Math.sin(t * 53 + s.i * 7) * 3 * stress, jy = Math.cos(t * 47 + s.i * 3) * 3 * stress;
    const age = clamp((dt - .6) / 1.6);
    const cx = lerp(s.x, 960, collapse) + jx, cy = lerp(s.y, 540, collapse) + jy;
    tf(s.node, {
      x: cx - s.w / 2, y: cy - s.h / 2, r: s.r * (1 - .3 * sp) + collapse * 40 * (s.i % 2 ? 1 : -1),
      s: lerp(.55, 1, sp) * (1 - collapse * .97), o: clamp(dt / .06) * lerp(1, .5, age) * (1 - collapse * .4),
      blur: collapse * 8,
    });
  }
  // words: hard cuts on the beat; "Again." stacks
  const againIdx = [8, 9, 10];
  WORDS.forEach((w, i) => {
    const next = WORDS[i + 1];
    let on = t >= w.t && (!next || t < next.t);
    if (againIdx.includes(i) && t >= w.t && t < 5.0) on = true;
    if (i === 7 && t >= 4.0 && t < 5.0) on = true;
    if (!on) { w.node.style.visibility = 'hidden'; return; }
    w.node.style.visibility = 'visible';
    const dt = t - w.t;
    const punch = 1 + .14 * (1 - P(dt, 0, .35, E.outExpo));
    let x = 960 - w.w / 2, y = 540 - w.h / 2;
    let o = 1;
    if (i === 7) { y -= 250; o = t >= 4.25 ? .35 : 1; }
    if (againIdx.includes(i)) { const k = againIdx.indexOf(i); y += -60 + k * 170; x += (k - 1) * 120; o = t >= WORDS[i + 1].t && i !== 10 ? .35 : 1; }
    if (i === 11) o = 1;
    tf(w.node, { x: lerp(x, 960 - w.w / 2, collapse), y: lerp(y, 540 - w.h / 2, collapse), s: punch * (1 - collapse * .98), o, blur: (1 - P(dt, 0, .2)) * 10 + collapse * 14 });
  });
  // the point everything collapses into
  const dp = P(t, 5.95, .3, E.outExpo) * (1 - P(t, 6.3, .2, E.inExpo));
  tf(dot, { s: dp * 1.6, o: dp });
}

function renderS2(t) {
  const on = t >= 6.5 && t < 12.25; vis(s2, on); if (!on) return;
  lines(line1, t, 6.62, 7.7, { dur: 1.1 });
  // key rises, gets pressed at 9.0, folds into the app icon
  const rise = P(t, 7.9, 1.0, E.outExpo);
  const pressDown = P(t, 8.96, .05, E.inCubic) * (1 - P(t, 9.08, .5, E.outCubic));
  const morph = P(t, 9.15, .85, E.inOutQuint);
  const slide = P(t, 9.75, .9, E.inOutQuint);
  const kw = lerp(560, 230, morph), kh = lerp(210, 230, morph), kr = lerp(38, 52, morph);
  const groupW = 230 + 54 + M.wordW;
  const iconX = 960 - groupW / 2 + 115;
  const kx = lerp(960, iconX, slide), ky = lerp(560, 500, slide) + (1 - rise) * 420 + pressDown * 16;
  const depth = lerp(18, 4, pressDown) * (1 - morph);
  const bob = Math.sin((t - 8.9) * 2.2) * 4 * (1 - P(t, 8.9, .1)) * 0;
  keywrap.style.transform = `translate3d(${kx}px,${ky + bob}px,0) rotateX(${lerp(58, 18, rise) * (1 - morph)}deg)`;
  keywrap.style.opacity = rise.toFixed(3);
  Object.assign(key.style, { width: `${kw}px`, height: `${kh}px`, left: `${-kw / 2}px`, top: `${-kh / 2}px`, borderRadius: `${kr}px` });
  const pressGlow = P(t, 9.0, .05) * (1 - P(t, 9.1, 1.4, E.outCubic));
  key.style.boxShadow = `inset 0 1px 0 rgba(255,255,255,.2), inset 0 -3px 0 rgba(0,0,0,.35), 0 ${depth}px 0 #0b0c0e, 0 ${depth + 26}px 60px rgba(0,0,0,.65), 0 0 ${80 + 120 * pressGlow}px rgba(10,132,255,${(.15 + .55 * pressGlow + .2 * morph).toFixed(3)})`;
  op($('.kfill', key), morph);
  op($('.klabel', key), 1 - P(t, 9.12, .25, E.outCubic));
  const gS = lerp(.5, 1.12, morph), gx = lerp(34, kw / 2 - 56, morph), gy = lerp(24, kh / 2 - 56, morph);
  for (const g of [$('.kout', key), $('.kin', key)]) { g.style.left = `${gx}px`; g.style.top = `${gy}px`; g.style.transform = `scale(${gS})`; g.style.transformOrigin = '50% 50%'; }
  op($('.kin', key), P(t, 9.3, .4, E.outCubic));
  op($('.kout', key), 1 - P(t, 9.35, .4, E.outCubic));
  // shockwave and glow
  const rp = P(t, 9.0, 1.1, E.outCubic);
  tf(ring, { s: lerp(.4, 6, rp), o: (t >= 9 ? 1 : 0) * (1 - rp) * .9 });
  const rp2 = P(t, 9.06, 1.4, E.outCubic);
  tf(ring2, { s: lerp(.4, 4, rp2), o: (t >= 9.06 ? 1 : 0) * (1 - rp2) * .6 });
  op(glow, pressGlow * .9 + morph * .25 * (1 - slide * .5) + rise * .08);
  // wordmark
  const wx = 960 - groupW / 2 + 230 + 54;
  $$('.ch', word).forEach((c, i) => {
    const p = P(t, 9.95 + i * .055, .9, E.outExpo);
    c.style.transform = `translateY(${(1 - p) * 90}px)`; c.style.opacity = p.toFixed(3);
    c.style.filter = p < .98 ? `blur(${((1 - p) * 12).toFixed(1)}px)` : 'none';
  });
  tf(word, { x: wx + (kx - iconX), y: 500 - M.wordH / 2 - 6 });
  // tagline on the beat
  $$('span', tagline).forEach((s, i) => {
    const p = P(t, 10.5 + i * .5, .6, E.outExpo);
    tf(s, { y: (1 - p) * 40, o: p, blur: (1 - p) * 10 });
  });
  tagline.style.top = '690px';
  // exit: push into the screen
  const out = P(t, 11.72, .5, E.inExpo);
  s2.style.transform = `scale(${1 + out * .6})`;
  s2.style.filter = out > .01 ? `blur(${out * 18}px)` : 'none';
  s2.style.opacity = (1 - out).toFixed(3);
  // camera shake on impact
  const shake = (t >= 9 ? 1 : 0) * Math.exp(-(t - 9) * 7) * 10;
  if (shake > .1) s2.style.transform += ` translate(${Math.sin(t * 90) * shake}px,${Math.cos(t * 77) * shake}px)`;
}

// camera: [t, focusX, focusY, zoom]
const CAM = [
  [12.0, 960, 540, 1.0], [12.7, 960, 540, 1.0], [13.4, 520, 520, 1.32], [14.3, 620, 470, 1.2], [15.15, 960, 420, 1.04],
  [16.0, 880, 250, 1.28], [16.85, 560, 230, 1.6], [17.85, 560, 230, 1.6], [18.45, 960, 300, 1.2], [19.3, 1600, 200, 1.75],
  [20.3, 1600, 200, 1.75], [21.3, 1360, 420, 1.2], [22.5, 1360, 500, 1.18], [23.4, 1080, 520, 1.04], [24.05, 470, 520, 1.42],
  [25.25, 490, 510, 1.38], [25.9, 960, 340, 1.12], [26.6, 960, 340, 1.12], [27.05, 520, 230, 1.55], [27.7, 520, 230, 1.55],
  [28.3, 1600, 210, 1.6], [28.8, 1600, 210, 1.6],
];
// cursor: [t, x, y] (filled in after measuring)
let CUR;
function cursorPath() {
  const r0 = M.rows[0], r3 = M.rows[3], t0 = M.tile1[0], t2 = M.tile2[0];
  const s0 = M.srow[0]; // IMG_4821 sits at the top until the batch rows arrive
  const mqA = [M.rowsBox.x + M.rowsBox.w - 40, M.rows[5].y + M.rows[5].h + 18];
  const mqB = [M.rows[1].x + 150, M.rows[1].y + 8];
  M.mqA = mqA; M.mqB = mqB;
  CUR = [
    [12.0, 1480, 900], [12.95, r0.x + 70, r0.cy + 2], [13.35, r0.x + 70, r0.cy + 2], [14.6, 900, 480], [15.2, 870, 440],
    [16.55, t0.cx + 14, t0.cy + 12], [17.5, t0.cx + 14, t0.cy + 12], [18.6, 1080, 430], [20.15, 1180, 380], [20.9, s0.x + 120, s0.cy + 4],
    [21.1, s0.x + 120, s0.cy + 4], [22.25, M.zone.cx + 10, M.zone.cy + 10], [23.0, M.zone.cx + 60, M.zone.cy + 130],
    [23.7, mqA[0], mqA[1]], [23.78, mqA[0], mqA[1]], [24.4, mqB[0], mqB[1]], [24.75, r3.x + 70, r3.cy + 2], [24.9, r3.x + 70, r3.cy + 2],
    [25.6, 980, 520], [26.0, M.bar2Head.x - 260, M.bar2Head.cy], [26.7, 1000, 720], [28.8, 1060, 760],
  ];
}

function camera(t) {
  const [fx0, fy0, z] = keys(t, CAM);
  const hw = W / (2 * z), hh = H / (2 * z);
  const fx = z >= 1 ? clamp(fx0, hw, W - hw) : 960, fy = z >= 1 ? clamp(fy0, hh, H - hh) : 540;
  return { x: W / 2 - fx * z, y: H / 2 - fy * z, z };
}

function renderS3(t) {
  const on = t >= 11.7 && t < 30.1; vis(s3, on); if (!on) return;
  const cam = camera(t);
  desk.style.transform = `translate(${cam.x.toFixed(2)}px,${cam.y.toFixed(2)}px) scale(${cam.z.toFixed(4)})`;
  // entry from the S2 push
  const inP = P(t, 11.78, .9, E.outExpo);
  // exit: the desktop becomes a card that swings away
  const outA = P(t, 28.75, .8, E.inOutQuint), outB = P(t, 29.5, .5, E.inExpo);
  const s = lerp(1.35, 1, inP) * lerp(1, .56, outA);
  deskcard.style.transform = `translateX(${-outB * 1700}px) rotateY(${outA * -16 - outB * 14}deg) rotateX(${outA * 5}deg) scale(${s})`;
  deskcard.style.borderRadius = `${outA * 34}px`;
  deskcard.style.boxShadow = outA > 0 ? `0 50px 120px rgba(0,0,0,${.6 * outA})` : 'none';
  deskcard.style.filter = (1 - inP) > .01 || outB > .01 ? `blur(${(1 - inP) * 16 + outB * 10}px)` : 'none';
  deskcard.style.opacity = (clamp((t - 11.7) / .25)).toFixed(3);
  op(s3bg, outA);

  // cursor and drag ghost
  const [cx, cy] = keys(t, CUR, E.inOutCubic);
  const press = (t > 13.15 && t < 17.5) || (t > 21.0 && t < 22.3) || (t > 23.78 && t < 24.4) || (t > 24.8 && t < 26.05);
  tf(cursor, { x: cx - 9, y: cy - 4, s: press ? .92 : 1 });
  let g = null;
  if (t >= 13.4 && t < 17.75) g = { kind: 'sunset', name: 'IMG_4821.jpg', t0: 13.4, drop: 17.5 };
  if (t >= 21.1 && t < 22.5) g = { kind: 'sunset', name: 'IMG_4821-web.webp', t0: 21.1, drop: 22.3 };
  if (t >= 24.9 && t < 26.25) g = { kind: 'ocean', name: '', t0: 24.9, drop: 26.05, batch: true };
  if (g) {
    if (ghost._k !== g.name + g.kind) {
      ghost._k = g.name + g.kind;
      $('.g1', ghost).innerHTML = g.batch
        ? ['portrait', 'city', 'ocean'].map((k, i) => `<div style="position:absolute;left:${i * 6}px;top:${i * -6}px">${thumb(k, 104, 72)}</div>`).join('')
        : thumb(g.kind, 104, 72);
      $('.gname', ghost).textContent = g.name;
    }
    const lift = P(t, g.t0, .25, E.outBack), gone = P(t, g.drop, .22, E.inCubic);
    tf(ghost, { x: cx - 60, y: cy - 44, s: lerp(.6, 1, lift) * (1 - gone * .7), o: (.85 * Math.min(1, lift * 1.3)) * (1 - gone) });
    op($('.badge', ghost), g.batch ? lift : 0);
  } else op(ghost, 0);

  // finder selection
  const single = t >= 13.15 && t < 23.78;
  const mq = t >= 23.78 && t < 24.45 ? P(t, 23.78, .62, E.inOutCubic) : (t >= 24.45 ? 1 : 0);
  let mqY0 = 0, mqY1 = 0;
  if (t >= 23.78 && t < 24.5) {
    const [ax, ay] = M.mqA, [bx, by] = [lerp(M.mqA[0], M.mqB[0], mq), lerp(M.mqA[1], M.mqB[1], mq)];
    marquee.style.left = `${Math.min(ax, bx) - M.main.x}px`; marquee.style.top = `${Math.min(ay, by) - M.main.y}px`;
    marquee.style.width = `${Math.abs(ax - bx)}px`; marquee.style.height = `${Math.abs(ay - by)}px`;
    op(marquee, 1 - P(t, 24.4, .08));
    mqY0 = Math.min(ay, by); mqY1 = Math.max(ay, by);
  } else op(marquee, 0);
  frows.forEach((r, i) => {
    let sel = single && i === 0;
    if (t >= 23.78) sel = (i >= 1 && i <= 5) && (t >= 24.45 || (M.rows[i].y + M.rows[i].h > mqY0 && M.rows[i].y < mqY1));
    r.classList.toggle('sel', sel);
  });

  // bar 1
  renderBar(bar1, t, { show: 15.0, drop: 17.5, workEnd: 18.35, hide: 18.4, tiles: M.tile1, hiTile: 0, hiAt: 16.72, count: 1, h: M.bar1H });
  // bar 2
  renderBar(bar2, t, { show: 25.5, drop: 26.05, keyAt: 27.0, workEnd: 27.8, hide: 27.85, tiles: M.tile2, hiTile: -1, count: 3, h: M.bar2H, clickHint: 26.05 });

  // shelf
  const shIn = spring(t - 18.5, 2.6, .6);
  tf(shelf, { y: (1 - shIn) * -26, s: lerp(.96, 1, shIn), o: clamp((t - 18.5) / .15) });
  const batchIn = [27.95, 28.07, 28.19];
  srows.forEach((r, i) => {
    const start = i === 3 ? 18.5 : batchIn[i];
    const p = i === 3 ? 1 : P(t, start, .4, E.outCubic);
    r.style.height = `${54 * p}px`;
    r.style.opacity = (i === 3 ? 1 : P(t, start + .05, .3, E.outCubic)).toFixed(3);
    const fresh = P(t, start, .1) * (1 - P(t, start + 2.2, .6, E.outCubic));
    op($('.sbg', r), fresh * .2);
  });
  const c4 = P(t, 27.95, .25);
  op($('.c1', shelf), 1 - c4); op($('.c4', shelf), c4);
  op($('.dall', shelf), c4);

  // callout next to the shelf
  const co = P(t, 18.8, .7, E.outExpo) * (1 - P(t, 20.35, .35, E.inCubic));
  tf(callout, { y: (1 - P(t, 18.8, .7, E.outExpo)) * 30, o: co, blur: (1 - co) * 8 });
  const cnt = P(t, 18.85, 1.0, E.outExpo);
  const kb = Math.round(lerp(8400, 412, cnt));
  $('.sizes', callout).textContent = `8.4 MB → ${kb >= 1000 ? (kb / 1000).toFixed(1) + ' MB' : kb + ' KB'}`;
  $('.big', callout).textContent = `−${Math.round(95 * cnt)}%`;

  // drop zone
  const over = t >= 21.9 && t < 22.35;
  zone.style.borderColor = over ? '#0a7aff' : '#c7c7cc';
  zone.style.background = over ? 'rgba(10,122,255,.08)' : 'transparent';
  const zp = spring(t - 22.3, 2.2, .7);
  const zimg = $('.zimg', zone);
  zimg.style.opacity = clamp((t - 22.3) / .15).toFixed(3);
  zimg.style.transform = `scale(${lerp(1.12, 1, clamp(zp))})`;
  op($('.zchip', zone), P(t, 22.6, .4));

  // captions
  op(caps, P(t, 12.3, .5) * (1 - P(t, 28.6, .3)));
  CAPTIONS.forEach(c => {
    const on = t >= c.tin - .05 && t < c.tout + .5;
    c.node.style.visibility = on ? 'visible' : 'hidden';
    if (on) lines(c.node, t, c.tin, c.tout, { stagger: .05, dur: .8, outDur: .3 });
  });
  // keystroke HUD
  const hs = (t >= 14.7 && t < 17.6) || (t >= 25.25 && t < 26.15);
  const hsIn = t < 20 ? P(t, 14.7, .3) * (1 - P(t, 17.5, .2)) : P(t, 25.25, .3) * (1 - P(t, 26.05, .2));
  const hsDown = t < 20 ? P(t, 15.0, .06) * (1 - P(t, 17.5, .06)) : P(t, 25.5, .06) * (1 - P(t, 26.05, .06));
  hshift.style.opacity = hs ? hsIn.toFixed(3) : '0';
  hshift.style.transform = `translateY(${hsDown * 6 + (1 - hsIn) * 20}px)`;
  hshift.classList.toggle('on', hsDown > .5);
  hshift.style.boxShadow = `inset 0 1px 0 rgba(255,255,255,.25), 0 ${8 - hsDown * 6}px 0 #0d0e10, 0 20px 40px rgba(0,0,0,.45)${hsDown > .5 ? ', 0 0 40px rgba(10,132,255,.6)' : ''}`;
  const k1In = P(t, 26.75, .25) * (1 - P(t, 27.6, .25));
  const k1Down = P(t, 27.0, .06) * (1 - P(t, 27.2, .08));
  h1.style.opacity = k1In.toFixed(3);
  h1.style.display = t > 26.5 && t < 28 ? 'flex' : 'none';
  hshift.style.display = t > 26.5 && t < 28 ? 'none' : 'flex';
  h1.style.transform = `translateY(${k1Down * 6 + (1 - k1In) * 20}px)`;
  h1.classList.toggle('on', k1Down > .5);
  h1.style.boxShadow = `inset 0 1px 0 rgba(255,255,255,.25), 0 ${8 - k1Down * 6}px 0 #0d0e10, 0 20px 40px rgba(0,0,0,.45)${k1Down > .5 ? ', 0 0 40px rgba(10,132,255,.6)' : ''}`;
}

function renderBar(bar, t, o) {
  const shown = t >= o.show && t < o.hide + .3;
  if (!shown) { bar.style.opacity = '0'; bar.style.visibility = 'hidden'; return; }
  bar.style.visibility = 'visible';
  const sp = spring(t - o.show, 2.8, .62);
  const hideP = P(t, o.hide, .22, E.inCubic);
  tf(bar, { y: (1 - sp) * -40 - hideP * 14, s: lerp(.97, 1, sp), o: clamp((t - o.show) / .12) * (1 - hideP) });
  // tiles stagger in
  const tiles = $$('.tile', bar);
  tiles.forEach((tile, i) => {
    const p = P(t, o.show + .06 + i * .022, .5, E.outExpo);
    let s = 1;
    let hi = 0;
    if (i === o.hiTile && t >= o.hiAt && t < o.drop) { hi = P(t, o.hiAt, .12); s = 1 + .04 * spring(t - o.hiAt, 4, .5); }
    if (o.keyAt && i === 0 && t >= o.keyAt) { const k = P(t, o.keyAt, .06) * (1 - P(t, o.keyAt + .1, .2)); s = 1 - .04 * k; op($('.hb', tile), 0); hi = k; }
    if (i === o.hiTile && t >= o.drop) { const k = 1 - P(t, o.drop, .3); s = 1 + .04 * k - .03 * Math.sin(clamp((t - o.drop) / .2) * Math.PI); hi = k; }
    tile.style.transform = `translateY(${(1 - p) * 16}px) scale(${s})`;
    tile.style.opacity = p.toFixed(3);
    op($('.hl', tile), hi);
  });
  // drag vs click hint
  const ch = o.clickHint ? P(t, o.clickHint, .25) : 0;
  op($('.h-drag', bar), 1 - ch); op($('.h-click', bar), ch);
  // working state: the content folds into a progress row
  const workStart = o.keyAt || o.drop;
  const wp = P(t, workStart + .05, .3, E.inOutCubic);
  bar.style.height = `${lerp(o.h, 76, wp)}px`;
  op($('.bar-in', bar), 1 - P(t, workStart, .15));
  op($('.bar-work', bar), P(t, workStart + .15, .2));
  const prog = P(t, workStart + .2, o.workEnd - workStart - .2, E.inOutSine);
  $('.w-fill', bar).style.width = `${prog * 100}%`;
  $('.w-count', bar).textContent = `${Math.floor(prog * o.count + .001)}/${o.count}`;
  $('.spin', bar).style.transform = `rotate(${t * 720}deg)`;
}

function renderS4(t) {
  const on = t >= 29.75 && t < 50.2; vis(s4, on); if (!on) return;
  s4.style.opacity = '1';
  U.forEach((u, i) => {
    const T = 30 + i * 4;
    const show = t >= T - .1 && t < T + 4.05;
    vis(u, show); if (!show) return;
    const out = i < 4 ? T + 3.55 : 49.55;
    lines($('.kicker', u), t, T + .02, out, { dur: .8 });
    lines($('h2', u), t, T + .08, out, { stagger: .08, dur: 1.0 });
    lines($('p', u), t, T + .3, out, { stagger: .05, dur: .9 });
    const vin = P(t, T + .05, .9, E.outExpo), vout = P(t, out, .4, E.inCubic);
    const v = $('.visual', u);
    v.style.transform = `translateX(${(1 - vin) * 120 - vout * 60}px) scale(${1 - vout * .04})`;
    v.style.opacity = (vin * (1 - vout)).toFixed(3);
    v.style.filter = vout > .01 || vin < .99 ? `blur(${(1 - vin) * 8 + vout * 10}px)` : 'none';
    [uspMarkdown, uspCompress, uspSettings, uspPrivacy, uspCli][i](t - T);
  });
}

function uspMarkdown(d) {
  chips1.forEach((c, i) => { const p = P(d, .15 + i * .12, .8, E.outExpo); tf(c, { x: (1 - p) * -60, o: p }); });
  flows1.forEach((f, i) => { const p = P(d, .5 + i * .12, .5, E.outCubic); f.style.transform = `scaleX(${p})`; f.style.backgroundPosition = `${d * 60}px 0`; f.style.opacity = p; });
  const mp = P(d, .3, .9, E.outExpo);
  tf(md, { y: (1 - mp) * 40, o: mp });
  const n = Math.floor(clamp((d - .6) / 2.6) * MD_TEXT.length);
  const shown = MD_TEXT.slice(0, n);
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const html = shown.split('\n').map(l => l.startsWith('#') ? `<span class="hh">${esc(l)}</span>`
    : l.replace(/^(\[\d\d:\d\d\])/, '<span class="ts">$1</span>')).join('\n');
  const car = Math.floor(d * 2.5) % 2 === 0 || n < MD_TEXT.length ? '<span class="car"></span>' : '';
  if (mdBody._h !== html + car) { mdBody.innerHTML = html + car; mdBody._h = html + car; }
  const pp = P(d, 1.3, .7, E.outBack);
  tf(mdPill, { y: (1 - pp) * 20, s: lerp(.9, 1, pp), o: clamp(pp) });
}

const fmtBytes = b => b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.round(b / 1e3)} KB`;
function uspCompress(d) {
  CMP.forEach(c => {
    const st = .5 + c.i * .22;
    const pin = P(d, .1 + c.i * .08, .7, E.outExpo);
    tf(c.node, { x: (1 - pin) * 40, o: pin });
    if (c.i < 3) {
      const p = P(d, st, 1.1, E.outExpo);
      const frac = lerp(1, c.b / c.a, p);
      c.fb.style.width = `${frac * 100}%`;
      c.num.textContent = `${fmtBytes(c.a)} → ${fmtBytes(lerp(c.a, c.b, p))}`;
      op(c.lab, P(d, st + .5, .3));
    } else {
      // tries, would grow, keeps the original
      const grow = P(d, 1.2, .6, E.outCubic), back = P(d, 2.0, .35, E.outBack);
      const frac = lerp(1, 1.17, grow) - .17 * back;
      c.fb.style.width = `${frac * 100}%`;
      c.fb.style.background = back > .5 ? 'linear-gradient(90deg,#ff9f0a,#ffb340)' : (grow > .1 ? 'linear-gradient(90deg,#ff453a,#ff6b5e)' : '');
      const cur = lerp(c.a, c.a * 1.17, grow) - c.a * .17 * back;
      c.num.textContent = `${fmtBytes(c.a)} → ${fmtBytes(cur)}`;
      op(c.lab, P(d, 2.1, .3));
      tf(c.lab, { s: lerp(1.3, 1, P(d, 2.1, .4, E.outBack)) });
    }
  });
}

function uspSettings(d) {
  // ⇧ is on; ⌃ and fn get toggled, like in Settings → General
  const states = [
    [.3, [false, false, true, false, false]], [1.2, [true, false, true, false, false]], [1.8, [false, false, true, false, false]],
    [2.2, [false, false, true, false, true]], [2.8, [false, false, true, false, false]],
  ];
  let cur = [false, false, false, false, false], last = -9, lastIdx = -1;
  states.forEach(([at, st], si) => { if (d >= at) { cur = st; last = at; lastIdx = si; } });
  kEls.forEach((k, i) => {
    const p = P(d, .05 + i * .06, .7, E.outExpo);
    const pressed = lastIdx >= 0 && (i === [2, 0, 0, 4, 4][lastIdx]) ? (1 - P(d, last + .04, .18)) * P(d, last, .04) : 0;
    tf(k, { y: (1 - p) * 40 + pressed * 8, o: p });
    op($('.on', k), cur[i] ? 1 : 0);
    k.style.color = cur[i] ? '#fff' : '#9a9aa2';
  });
  const pp = P(d, .35, .9, E.outExpo);
  tf(preset, { y: (1 - pp) * 40, o: pp });
  const q = Math.round(d < 1.8 ? lerp(78, 64, P(d, 1.0, .7, E.inOutCubic)) : lerp(64, 82, P(d, 2.2, .8, E.inOutCubic)));
  sf.style.width = `${q}%`; kn.style.left = `${q}%`; qv.textContent = q;
}

function uspPrivacy(d) {
  const mp = P(d, .05, .9, E.outExpo);
  const ip = spring(d - .25, 2.4, .5);
  tf(macIcon, { s: lerp(.4, 1, ip), o: clamp(ip) });
  orbs.forEach((o, i) => {
    const a = d * .9 + i * (Math.PI * 2 / orbs.length);
    const p = P(d, .3 + i * .06, .7, E.outExpo);
    const rx = 230 * p, ry = 130 * p;
    tf(o, { x: 320 + Math.cos(a) * rx - 32, y: 200 + Math.sin(a) * ry - 23, s: .9 + Math.sin(a) * .12, o: p });
  });
  void mp;
  const cp = P(d, .6, .5, E.outCubic);
  cut.style.transform = `rotate(-28deg) scaleX(${cp})`;
  cut.style.opacity = (cp * (1 - P(d, 1.05, .4) * .6)).toFixed(3);
  const sp = P(d, 1.0, .25, E.outBack);
  tf(slash, { r: 35, s: sp, o: clamp(sp) });
  cloud.style.opacity = (P(d, .4, .5) * lerp(1, .3, P(d, 1.05, .4))).toFixed(3);
  stampEls.forEach((s, i) => { const p = P(d, 1.4 + i * .3, .5, E.outBack); tf(s, { y: (1 - p) * 30, s: lerp(.8, 1, clamp(p)), o: clamp(p) }); });
}

function uspCli(d) {
  const tp = P(d, .05, .9, E.outExpo);
  tf(term, { y: (1 - tp) * 40, o: tp });
  const n = Math.floor(clamp((d - .3) / 1.0) * CMD.length);
  const outs = OUT.filter((_, i) => d >= 1.45 + i * .12);
  let html = `<span class="pr">~/shoot $</span> ${CMD.slice(0, n)}`;
  const blink = Math.floor(d * 2.5) % 2 === 0;
  if (outs.length) {
    html += '\n' + outs.map(l => `<span class="ok">✓</span>${l.slice(1).replace(/(\(-\d+%\))/, '<span class="ok">$1</span>')}`).join('\n');
    if (d >= 2.0) html += `\n<span class="pr">~/shoot $</span> ${blink ? '<span class="car"></span>' : ''}`;
  } else html += (n < CMD.length || blink ? '<span class="car"></span>' : '');
  if (termBody._h !== html) { termBody.innerHTML = html; termBody._h = html; }
  const up = P(d, 2.2, .7, E.outBack);
  tf(upd, { y: (1 - up) * 30, s: lerp(.9, 1, clamp(up)), o: clamp(up) });
}

function renderS5(t) {
  const on = t >= 49.5 && t < 54.25; vis(s5, on); if (!on) return;
  const d = t - 49.5;
  const enter = P(t, 49.55, .8, E.outExpo);
  const push = P(t, 53.35, .65, E.inExpo);
  s5.style.opacity = enter.toFixed(3);
  plane.style.transform = `translateZ(${lerp(-200, 120, d / 4.5) + push * 900}px) rotateX(50deg) rotateZ(${-16 + d * 1.2}deg)`;
  wrows.forEach((r, i) => {
    const dir = i % 2 ? 1 : -1, speed = 110 + (i % 3) * 40;
    r.style.transform = `translate(${-1900 + dir * d * speed + (i % 2) * 110}px, ${(i - 4) * 172 - 75}px)`;
  });
  lines(wallTitle, t, 50.45, null, { stagger: 1.0, dur: .9 });
  wallTitle.style.transform = `scale(${1 + push * 2.2})`;
  wallTitle.style.opacity = (1 - push).toFixed(3);
  wallTitle.style.filter = push > .01 ? `blur(${push * 20}px)` : 'none';
}

function renderS6(t) {
  const on = t >= 53.9; vis(s6, on); if (!on) return;
  const ip = spring(t - 54.0, 1.9, .5);
  tf(endIcon, { y: (1 - clamp(ip)) * 40, s: lerp(.55, 1, ip), o: clamp((t - 54) / .15) });
  $$('.ch', endWord).forEach((c, i) => {
    const p = P(t, 54.3 + i * .05, .9, E.outExpo);
    c.style.transform = `translateY(${(1 - p) * 80}px)`; c.style.opacity = p.toFixed(3);
    c.style.filter = p < .98 ? `blur(${((1 - p) * 12).toFixed(1)}px)` : 'none';
  });
  $$('span', endTag).forEach((s, i) => { s.style.display = 'inline-block'; const p = P(t, 55.0 + i * .5, .6, E.outExpo); tf(s, { y: (1 - p) * 30, o: p, blur: (1 - p) * 8 }); });
  const bp = P(t, 56.5, .8, E.outExpo), up = P(t, 56.8, .8, E.outExpo);
  tf($('.btn', cta), { y: (1 - bp) * 30, s: lerp(.9, 1, bp), o: bp });
  tf($('.url', cta), { x: (1 - up) * -20, o: up });
  op(endFoot, P(t, 57.3, .8));
  const bl = $('.bloom', s6);
  bl.style.opacity = (P(t, 54, 1.2) * (.85 + Math.sin(t * 1.4) * .15)).toFixed(3);
}

// ---------- frame ----------
function render(t) {
  renderS1(t); renderS2(t); renderS3(t); renderS4(t); renderS5(t); renderS6(t);
  // flashes on the big hits
  const f = Math.max(
    (t >= 9.0 ? 1 : 0) * (1 - P(t, 9.0, .35, E.outCubic)) * .7,
    (t >= 53.95 ? 1 : 0) * (1 - P(t, 54.0, .7, E.outCubic)) * .9,
    (t >= 6.32 && t < 6.5 ? 1 : 0) * (1 - P(t, 6.32, .16)) * .5,
  );
  op(flash, f);
  op(fade, Math.max(P(t, 59.2, .8, E.inOutCubic), t < .05 ? 1 : 0));
  const fr = Math.round(t * 60);
  grain.style.transform = `translate(${(fr * 37) % 50 - 25}px,${(fr * 53) % 50 - 25}px)`;
  op(vignette, t > 12.2 && t < 28.9 ? .35 : 1);
}
window.render = render;

// ---------- boot ----------
async function boot() {
  await document.fonts.ready;
  measure();
  cursorPath();
  const fit = () => {
    if (location.hash.startsWith('#render')) return;
    const k = Math.min(innerWidth / W, innerHeight / H);
    stage.style.transform = `scale(${k})`;
    document.body.style.background = '#111';
  };
  fit(); addEventListener('resize', fit);
  const m = location.hash.match(/t=([\d.]+)/);
  if (location.hash.includes('play')) {
    const start = performance.now() - (m ? +m[1] * 1000 : 0);
    const loop = () => { render(((performance.now() - start) / 1000) % DURATION); requestAnimationFrame(loop); };
    loop();
  } else render(m ? +m[1] : 0);
  window.READY = true;
}
boot();
