import {fal} from '@fal-ai/client';
import {readFile, writeFile, mkdir, access, rename} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const film = JSON.parse(await readFile(path.join(root, 'film.json'), 'utf8'));
const dryRun = process.argv.includes('--dry-run');
const mode = process.argv.includes('--audio-only') ? 'audio' : process.argv.includes('--video-only') ? 'video' : 'all';
const selected = process.argv.find((v) => v.startsWith('--only='))?.slice(7);
const exists = async (p) => access(p).then(() => true, () => false);
for (const file of [path.join(root, '..', '.env'), path.join(root, '.env')]) {
  if (!await exists(file)) continue;
  for (const line of (await readFile(file, 'utf8')).split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
}
const key = process.env.FAL_KEY || process.env.FAL_AI_API_KEY || process.env.FAL_API_KEY;
if (!key && !dryRun) throw new Error('Set FAL_KEY locally, or use the existing ../.env.');
fal.config({credentials: key});
await mkdir(path.join(root, '.cache'), {recursive: true});
await mkdir(path.join(root, 'public/generated'), {recursive: true});

async function generate(id, model, input, kind) {
  if (selected && selected !== id) return;
  const ext = kind === 'video' ? 'mp4' : 'mp3';
  const output = path.join(root, `public/generated/${id}.${ext}`);
  const fingerprint = createHash('sha256').update(JSON.stringify({model, input})).digest('hex');
  const cacheFile = path.join(root, `.cache/${id}.json`);
  let job = await exists(cacheFile) ? JSON.parse(await readFile(cacheFile, 'utf8')) : null;
  if (job?.fingerprint === fingerprint && await exists(output)) {
    console.log(`${id}: cached`);
    return;
  }
  if (job && job.fingerprint !== fingerprint) {
    throw new Error(`${id}: inputs changed. Archive .cache/${id}.json and its media to intentionally regenerate.`);
  }
  if (dryRun) {
    console.log(JSON.stringify({id, model, input}, null, 2));
    return;
  }
  if (!job) {
    const {request_id} = await fal.queue.submit(model, {input});
    job = {id, model, input, fingerprint, requestId: request_id, submittedAt: new Date().toISOString()};
    await writeFile(cacheFile, JSON.stringify(job, null, 2));
    console.log(`${id}: submitted ${request_id}`);
  } else console.log(`${id}: resuming ${job.requestId}`);
  // Persist the request before polling: rerunning resumes an existing paid job.
  await fal.queue.subscribeToStatus(model, {requestId: job.requestId, pollInterval: 3000, logs: false});
  const {data} = await fal.queue.result(model, {requestId: job.requestId});
  const media = data[kind];
  if (!media?.url) throw new Error(`${id}: response did not contain ${kind}.url`);
  const response = await fetch(media.url);
  if (!response.ok) throw new Error(`${id}: download returned ${response.status}`);
  await writeFile(`${output}.partial`, Buffer.from(await response.arrayBuffer()));
  await rename(`${output}.partial`, output);
  await writeFile(cacheFile, JSON.stringify({...job, result: data, completedAt: new Date().toISOString()}, null, 2));
  console.log(`${id}: saved ${path.relative(root, output)}`);
}

// Keep submissions sequential, limiting spend and making interrupted runs resumable.
if (mode !== 'video') {
  for (const scene of film.scenes) {
    await generate(`vo-${scene.id}`, film.speechModel, {
      prompt: scene.narration,
      voice_setting: {voice_id: film.voice, speed: 0.96, vol: 1, pitch: -1, emotion: 'neutral', english_normalization: true},
      audio_setting: {sample_rate: 44100, bitrate: 256000, format: 'mp3', channel: 1},
      language_boost: 'English', output_format: 'url',
      normalization_setting: {enabled: true, target_loudness: -18, target_peak: -1.5},
    }, 'audio');
  }
}
if (mode !== 'audio') {
  for (let i = 0; i < film.footage.length; i++) {
    const shot = film.footage[i];
    await generate(shot.id, film.videoModel, {
      prompt: shot.prompt, duration: shot.duration, resolution: '1080p',
      reasoning_level: 'high', aspect_ratio: '16:9', generate_audio: false, seed: 48531 + i,
    }, 'video');
  }
}
