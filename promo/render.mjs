// Renders the film to MP4: frames from headless Chrome in parallel segments, soundtrack from audio.py.
// node render.mjs [--fps 60] [--workers 6] [--from 0] [--to 60] [--out shift-release.mp4]
import { chromium } from 'playwright-core';
import ffmpegPath from 'ffmpeg-static';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : fallback;
};
const FPS = +arg('fps', 60);
const WORKERS = +arg('workers', Math.max(2, Math.min(8, os.cpus().length - 2)));
const OUT = path.resolve(arg('out', 'shift-release.mp4'));
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PAGE = 'file://' + path.resolve('index.html') + '#render';
const work = path.resolve('build');
fs.mkdirSync(work, { recursive: true });

async function openPage() {
  const browser = await chromium.launch({ executablePath: CHROME, args: ['--force-color-profile=srgb', '--hide-scrollbars'] });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('pageerror', e => console.error('pageerror:', e.message));
  await page.goto(PAGE);
  await page.waitForFunction(() => window.READY === true);
  return { browser, page };
}

// cues and length come from the film itself
const probe = await openPage();
const { cues, duration } = await probe.page.evaluate(() => ({ cues: window.CUES, duration: window.DURATION }));
await probe.browser.close();
const from = +arg('from', 0), to = +arg('to', duration);
fs.writeFileSync(path.join(work, 'cues.json'), JSON.stringify(cues));

const audio = new Promise((resolve, reject) => {
  const p = spawn('python3', ['audio.py', path.join(work, 'cues.json'), path.join(work, 'soundtrack.wav')], { stdio: 'inherit' });
  p.on('exit', code => code === 0 ? resolve() : reject(new Error(`audio.py exited with ${code}`)));
});

const first = Math.round(from * FPS), last = Math.round(to * FPS);
const total = last - first;
const per = Math.ceil(total / WORKERS);
let done = 0;
const started = Date.now();

async function renderSegment(k) {
  const a = first + k * per, b = Math.min(last, a + per);
  if (a >= b) return null;
  const file = path.join(work, `seg-${String(k).padStart(2, '0')}.mp4`);
  const ff = spawn(ffmpegPath, [
    '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
    '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '15', '-tune', 'film',
    '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv', file,
  ], { stdio: ['pipe', 'inherit', 'inherit'] });
  const finished = new Promise((resolve, reject) => ff.on('exit', c => c === 0 ? resolve() : reject(new Error(`ffmpeg ${k} exited with ${c}`))));
  const { browser, page } = await openPage();
  for (let f = a; f < b; f++) {
    await page.evaluate(t => window.render(t), f / FPS);
    const jpg = await page.screenshot({ type: 'jpeg', quality: 96 });
    if (!ff.stdin.write(jpg)) await new Promise(r => ff.stdin.once('drain', r));
    done++;
    if (done % 120 === 0) {
      const s = (Date.now() - started) / 1000;
      console.log(`${done}/${total} frames · ${(done / s).toFixed(1)} fps · ~${Math.round((total - done) / (done / s))} s left`);
    }
  }
  ff.stdin.end();
  await browser.close();
  await finished;
  return file;
}

const segments = (await Promise.all(Array.from({ length: WORKERS }, (_, k) => renderSegment(k)))).filter(Boolean);
await audio;
// two-pass loudness normalisation to -14 LUFS, the level YouTube, LinkedIn and Instagram play at
const wav = path.join(work, 'soundtrack.wav');
const measured = spawnSync(ffmpegPath, ['-hide_banner', '-i', wav, '-af', 'loudnorm=I=-14:TP=-1:LRA=11:print_format=json', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
const m = JSON.parse(measured.slice(measured.lastIndexOf('{')));
const loudnorm = `loudnorm=I=-14:TP=-1:LRA=11:linear=true:measured_I=${m.input_i}:measured_TP=${m.input_tp}:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}`;
const list = path.join(work, 'segments.txt');
fs.writeFileSync(list, segments.map(s => `file '${s}'`).join('\n'));
execFileSync(ffmpegPath, [
  '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list,
  '-ss', String(from), '-t', String(to - from), '-i', wav,
  '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-af', `${loudnorm},alimiter=limit=0.89:level=false,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo`, '-c:a', 'aac', '-b:a', '320k', '-shortest', '-movflags', '+faststart', OUT,
], { stdio: 'inherit' });
// a lighter copy for Slack, LinkedIn and the README
const web = OUT.replace(/\.mp4$/, '-web.mp4');
execFileSync(ffmpegPath, ['-loglevel', 'error', '-y', '-i', OUT, '-c:v', 'libx264', '-preset', 'slow', '-crf', '21', '-maxrate', '10M', '-bufsize', '20M',
  '-pix_fmt', 'yuv420p', '-c:a', 'copy', '-movflags', '+faststart', web], { stdio: 'inherit' });
console.log(`wrote ${OUT} and ${web} in ${Math.round((Date.now() - started) / 1000)} s`);
