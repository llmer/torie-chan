import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = path.join(root, 'out/torie-chan-film.mp4');
const timeline = JSON.parse(await readFile(path.join(root, 'src/timeline.json'), 'utf8'));
const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file], {encoding: 'utf8'}));
const video = probe.streams.find((s) => s.codec_type === 'video');
const audio = probe.streams.find((s) => s.codec_type === 'audio');
if (!video || !audio) throw new Error('Master must have video and audio');
if (video.width !== 1920 || video.height !== 1080 || video.avg_frame_rate !== '24/1') throw new Error('Unexpected video dimensions or frame rate');
if (Math.abs(Number(probe.format.duration) - timeline.durationInFrames / 24) > 0.1) throw new Error('Duration differs from timeline');
if (Number(audio.sample_rate) !== 48000 || audio.channels !== 2) throw new Error('Unexpected output audio');
const decode = spawnSync('ffmpeg', ['-hide_banner', '-i', file, '-af', 'loudnorm=I=-16:TP=-1.5:LRA=9:print_format=json',
  '-vf', 'blackdetect=d=0.6:pix_th=0.02:pic_th=0.995', '-f', 'null', '-'], {encoding: 'utf8', maxBuffer: 4 * 1024 * 1024});
if (decode.status !== 0) throw new Error(`Full decode failed: ${decode.stderr.slice(-1500)}`);
const match = decode.stderr.match(/\{\s*"input_i"[\s\S]*?\}/);
const loudness = match ? JSON.parse(match[0]) : null;
if (!loudness || Number(loudness.input_tp) > -1) throw new Error('Audio peak exceeds the delivery ceiling');
const blackIntervals = [...decode.stderr.matchAll(/black_start:([\d.]+) black_end:([\d.]+) black_duration:([\d.]+)/g)]
  .map((m) => ({from: +m[1], to: +m[2], duration: +m[3]}));
if (blackIntervals.some((b) => b.from > 1 && b.to < Number(probe.format.duration) - 1)) throw new Error('Unexpected full-black gap inside the film');
const report = {file: 'torie-chan-film.mp4', duration: +probe.format.duration, frames: +video.nb_frames,
  width: video.width, height: video.height, fps: 24, videoCodec: video.codec_name, audioCodec: audio.codec_name,
  sampleRate: +audio.sample_rate, channels: audio.channels, integratedLoudnessLUFS: +loudness.input_i,
  truePeakDBTP: +loudness.input_tp, blackIntervals, fullDecode: 'passed', checkedAt: new Date().toISOString()};
await writeFile(path.join(root, 'out/verification.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
