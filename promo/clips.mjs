// Renders the onboarding clips from the film: silent, 1280×720 at 60 fps, with the onboarding camera.
// node clips.mjs   (writes ../Resources/Onboarding/*.mp4)
import { chromium } from 'playwright-core';
import ffmpegPath from 'ffmpeg-static';
import { spawn } from 'node:child_process';
import path from 'node:path';

const FPS = 60;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PAGE = 'file://' + path.resolve('index.html') + '#render-onboarding';
const OUT = path.resolve('../Resources/Onboarding');

// Scenes from STORYBOARD.md.
const CLIPS = [
  { name: 'how-it-works', from: 12.3, to: 23.6 }, // drag, hold Shift, drop on Web preset, shelf, drag out
  { name: 'batch', from: 23.6, to: 28.7 },        // a batch of mixed files, sorted by type, number keys
];

async function renderClip({ name, from, to }) {
  const browser = await chromium.launch({ executablePath: CHROME, args: ['--force-color-profile=srgb', '--hide-scrollbars'] });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('pageerror', e => console.error('pageerror:', e.message));
  await page.goto(PAGE);
  await page.waitForFunction(() => window.READY === true);

  const file = path.join(OUT, `${name}.mp4`);
  const ff = spawn(ffmpegPath, [
    '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
    '-vf', 'scale=1280:720:flags=lanczos,format=yuv420p',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-tune', 'film', '-an', '-movflags', '+faststart', file,
  ], { stdio: ['pipe', 'inherit', 'inherit'] });
  const finished = new Promise((resolve, reject) => ff.on('exit', c => c === 0 ? resolve() : reject(new Error(`ffmpeg exited with ${c}`))));
  const frames = Math.round((to - from) * FPS);
  for (let f = 0; f < frames; f++) {
    await page.evaluate(t => window.render(t), from + f / FPS);
    const jpg = await page.screenshot({ type: 'jpeg', quality: 95 });
    if (!ff.stdin.write(jpg)) await new Promise(r => ff.stdin.once('drain', r));
  }
  ff.stdin.end();
  await browser.close();
  await finished;
  console.log(`${name}.mp4  ${(to - from).toFixed(1)} s  ${frames} frames`);
}

await Promise.all(CLIPS.map(renderClip));
