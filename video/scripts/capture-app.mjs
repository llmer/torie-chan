import {spawnSync} from 'node:child_process';
import {mkdir, readFile, copyFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.resolve(root, '..');
const frames = path.join(root, '.cache/native-frames');
const output = path.join(root, 'public/app');
const run = (cmd, args, extra = {}) => {
  const r = spawnSync(cmd, args, {cwd: repo, stdio: 'inherit', ...extra});
  if (r.status !== 0) throw new Error(`${cmd} failed (${r.status})`);
};
await mkdir(output, {recursive: true});
// A distinct bundle path avoids replacing the user's installed app.
run('swift', ['build', '-c', 'debug', '--product', 'TorieChan']);
const bin = spawnSync('swift', ['build', '-c', 'debug', '--show-bin-path'], {cwd: repo, encoding: 'utf8'});
if (bin.status !== 0) throw new Error('Could not locate Swift debug products');
const productDir = bin.stdout.trim();
run(path.join(productDir, 'TorieChan'), ['--capture-film', frames]);
const manifest = JSON.parse(await readFile(path.join(frames, 'capture.json'), 'utf8'));
for (const clip of manifest.clips) {
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-framerate', String(manifest.fps),
    '-i', path.join(frames, clip.id, '%04d.png'), '-c:v', 'libx264', '-crf', '15', '-preset', 'medium',
    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(output, `${clip.id}.mp4`)]);
  await copyFile(path.join(frames, clip.id, '0024.png'), path.join(output, `${clip.id}.png`));
}
await copyFile(path.join(frames, 'capture.json'), path.join(output, 'capture.json'));
await copyFile(path.join(repo, 'docs/images/icon.png'), path.join(output, 'icon.png'));
await copyFile(path.join(repo, 'docs/images/settings.png'), path.join(output, 'settings.png'));
console.log('Native SwiftUI footage ready. No guard services were started.');
