import {readFile, writeFile, mkdir, copyFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const film = JSON.parse(await readFile(path.join(root, 'film.json'), 'utf8'));
await mkdir(path.join(root, 'src'), {recursive: true});
await mkdir(path.join(root, 'out'), {recursive: true});
const probe = (file) => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
  '-of', 'default=nw=1:nk=1', file], {encoding: 'utf8'}).trim());
let cursor = 0;
const overlap = 12;
const scenes = film.scenes.map((scene) => {
  const voiceDuration = probe(path.join(root, `public/generated/vo-${scene.id}.mp3`));
  const durationInFrames = Math.ceil(Math.max(scene.minimumDuration, voiceDuration + 1.6) * film.fps);
  const result = {...scene, from: cursor, durationInFrames, voiceDuration, voiceFrom: 14};
  cursor += durationInFrames - overlap;
  return result;
});
const timeline = {fps: film.fps, width: film.width, height: film.height, durationInFrames: cursor + overlap, scenes};
await writeFile(path.join(root, 'src/timeline.json'), JSON.stringify(timeline, null, 2));
const duration = timeline.durationInFrames / film.fps;
await writeFile(path.join(root, 'out/transcript.txt'), scenes.map((s) =>
  `[${(s.from / film.fps).toFixed(2)}] ${s.chapter}\n${s.narration.replace(/<#.*?#>/g, '').replace(/\s+/g, ' ')}\n`).join('\n'));

// A restrained original ambient score and editorial cues, generated locally and reproducibly.
execFileSync('python3', [path.join(root, 'scripts/score.py'), String(duration)], {cwd: root, stdio: 'inherit'});
await mkdir(path.join(root, 'hyperframes/media'), {recursive: true});
console.log(`Timeline: ${duration.toFixed(2)}s, ${timeline.durationInFrames} frames. Narration follows measured audio lengths.`);
