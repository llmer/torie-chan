// Optional word timing and subtitle pass over the existing MiniMax recordings.
// This transcribes existing audio; it does not regenerate voices or video.
import {fal} from '@fal-ai/client';
import {readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
for (const file of [path.join(root, '..', '.env'), path.join(root, '.env')]) {
  let source;
  try {source = await readFile(file, 'utf8');} catch {continue;}
  for (const line of source.split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
}
fal.config({credentials: process.env.FAL_KEY || process.env.FAL_AI_API_KEY || process.env.FAL_API_KEY});
const selected = process.argv.slice(2);
for (const id of (selected.length ? selected : ['arm', 'watch', 'tamper'])) {
  const cacheFile = path.join(root, `.cache/words-${id}.json`);
  let job;
  try {job = JSON.parse(await readFile(cacheFile, 'utf8'));} catch {}
  if (!job) {
    const voice = JSON.parse(await readFile(path.join(root, `.cache/vo-${id}.json`), 'utf8'));
    const result = await fal.queue.submit('fal-ai/whisper', {input: {
      audio_url: voice.result.audio.url, chunk_level: 'word', language: 'en', diarize: false,
    }});
    job = {requestId: result.request_id};
    await writeFile(cacheFile, JSON.stringify(job, null, 2));
  }
  if (!job.result) {
    await fal.queue.subscribeToStatus('fal-ai/whisper', {requestId: job.requestId, pollInterval: 2500});
    job.result = (await fal.queue.result('fal-ai/whisper', {requestId: job.requestId})).data;
    await writeFile(cacheFile, JSON.stringify(job, null, 2));
  }
  console.log(JSON.stringify({id, words: job.result.chunks}));
}
