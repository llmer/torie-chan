import {bundle} from '@remotion/bundler';
import {renderMedia, renderStill, selectComposition} from '@remotion/renderer';
import {mkdir, copyFile, readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const timeline = JSON.parse(await readFile(path.join(root, 'src/timeline.json'), 'utf8'));
await mkdir(path.join(root, 'out'), {recursive: true});
const browserExecutable = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const serveUrl = await bundle({entryPoint: path.join(root, 'src/index.tsx'), publicDir: path.join(root, 'public'),
  webpackOverride: (config) => config});
const composition = await selectComposition({serveUrl, id: 'TorieChanFilm', browserExecutable});
const stillsOnly = process.argv.includes('--stills');
const preview = process.argv.includes('--preview');
const out = path.join(root, 'out', preview ? 'torie-chan-preview.mp4' : 'torie-chan-film.mp4');
if (stillsOnly) {
  for (const scene of timeline.scenes) {
    const offset = {tamper: 210, return: 100, privacy: 155, watch: 210, arm: 205}[scene.id] ?? 80;
    const frame = scene.from + offset;
    await renderStill({serveUrl, composition, browserExecutable, frame,
      output: path.join(root, `out/${scene.id}.png`), imageFormat: 'png'});
    console.log(`Still: ${scene.id}`);
  }
} else {
  let last = -1;
  const raw = path.join(root, 'out', preview ? 'preview-raw.mp4' : 'master-raw.mp4');
  await renderMedia({serveUrl, composition, browserExecutable, codec: 'h264', outputLocation: raw,
    concurrency: 4, crf: preview ? 24 : 17, scale: preview ? 2 / 3 : 1,
    pixelFormat: 'yuv420p', audioBitrate: '320k',
    onProgress: ({progress}) => {const p = Math.floor(progress * 10); if (p !== last) {last = p; console.log(`Render ${p * 10}%`);}}});
  execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', raw,
    '-c:v', 'copy', '-af', 'loudnorm=I=-16:TP=-1.5:LRA=9', '-c:a', 'aac', '-b:a', '320k',
    '-ar', '48000', '-t', String(timeline.durationInFrames / 24), '-movflags', '+faststart', out], {stdio: 'inherit'});
  console.log(`Film: ${out}`);
  if (!preview) {
    // HyperFrames handoff retains each editorial scene as its own timeline clip.
    await mkdir(path.join(root, 'hyperframes/media'), {recursive: true});
    for (const scene of timeline.scenes) {
      execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(scene.from / 24), '-i', out,
        '-t', String((scene.durationInFrames - (scene.id === 'hero' ? 0 : 12)) / 24),
        '-c:v', 'libx264', '-crf', '18', '-preset', 'fast', '-c:a', 'aac', '-b:a', '256k',
        '-movflags', '+faststart', path.join(root, `hyperframes/media/${scene.id}.mp4`)], {stdio: 'inherit'});
    }
    const clips = timeline.scenes.map((s, i) => {
      const d = (s.durationInFrames - (i === timeline.scenes.length - 1 ? 0 : 12)) / 24;
      return `<video id="${s.id}" class="clip" data-start="${s.from / 24}" data-duration="${d}" data-track-index="0" data-has-audio="true" src="./media/${s.id}.mp4" playsinline></video>`;
    }).join('\n');
    await writeFile(path.join(root, 'hyperframes/index.html'), `<!doctype html>\n<html><head><meta charset="utf-8"><title>Torie-chan — Back in five</title><style>html,body{margin:0;background:#08070b}#film{position:relative;width:1920px;height:1080px;overflow:hidden}.clip{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}</style></head><body><main id="film" data-composition-id="torie-chan" data-no-timeline data-start="0" data-duration="${timeline.durationInFrames / 24}" data-fps="24" data-width="1920" data-height="1080">\n${clips}\n</main></body></html>\n`);
    // Serve this folder locally to review the film and jump to chapters.
    const chapters = timeline.scenes.map((s) => `<button onclick="const v=document.querySelector('video');v.currentTime=${s.from / 24};v.play()">${s.chapter}</button>`).join('');
    await writeFile(path.join(root, 'out/index.html'), `<!doctype html><meta charset="utf-8"><title>Torie-chan — Film review</title><style>body{margin:40px auto;padding:0 24px;max-width:1280px;background:#0c0a11;color:#fff4e4;font:16px system-ui}h1{font-weight:500}video{width:100%;border-radius:12px}nav{display:flex;flex-wrap:wrap;gap:10px;margin-top:20px}button{cursor:pointer;color:#d0c6ff;background:#221b31;border:1px solid #493b62;padding:12px 16px;border-radius:8px}</style><h1>Torie-chan — Back in five</h1><video controls src="torie-chan-film.mp4"></video><nav>${chapters}</nav><p>Native SwiftUI product footage · FLUX 3 Max café scenes · MiniMax Speech 2.8 HD narration</p>`);
    console.log('HyperFrames chapter composition and local review player ready.');
  }
}
