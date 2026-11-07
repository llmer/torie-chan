import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const timeline = JSON.parse(await readFile(path.join(root, 'src/timeline.json'), 'utf8'));
const inputs = [];
for (const scene of timeline.scenes) {
  const offset = {arm: 205, watch: 210, tamper: 210, privacy: 155, return: 100}[scene.id] ?? 80;
  const file = path.join(root, `out/${scene.id}.png`);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', String((scene.from + offset) / 24),
    '-i', path.join(root, 'out/torie-chan-film.mp4'), '-frames:v', '1', '-update', '1', file]);
  inputs.push('-i', file);
}
const scales = timeline.scenes.map((_, i) => `[${i}:v]scale=640:360[v${i}]`).join(';');
const labels = timeline.scenes.map((_, i) => `[v${i}]`).join('');
const layout = timeline.scenes.map((_, i) => `${(i % 3) * 640}_${Math.floor(i / 3) * 360}`).join('|');
execFileSync('ffmpeg', ['-v', 'error', '-y', ...inputs, '-filter_complex',
  `${scales};${labels}xstack=inputs=${timeline.scenes.length}:layout=${layout}:fill=0x08070b[out]`,
  '-map', '[out]', '-frames:v', '1', '-update', '1', '-q:v', '2', path.join(root, 'out/storyboard.jpg')]);
console.log('Eight rendered scene stills and out/storyboard.jpg ready.');
