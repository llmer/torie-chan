# Torie-chan — Back in five

An 83-second, 1920 × 1080, 24 fps cinematic product film. A café break becomes an illustrative
guard session: ask an AI agent to arm, leave, notice a passer-by, warn on tampering, alarm on a
lift, alert the owner, and return to a session summary.

The product footage comes from the app's **actual SwiftUI `GuardScreenContent` and `EyesRenderer`**.
The café inserts use **FLUX 3 Max by fal**. The narrator uses **MiniMax Speech 2.8 HD**, with the
`English_Trustworthy_Man` voice. A quiet original ambient score and editorial cues are generated
locally. This is a dramatized session, with synthetic data and an illustrative iMessage, rather
than a recording of a real security incident. No actual alarm, phone message, or camera capture
was triggered to make the native product footage.

## Watch and edit

The film's media and renders aren't in Git. These three appear in `out/` once you've
[reproduced the film](#reproduce-the-film):

- `out/torie-chan-film.mp4`: full-resolution master, H.264/AAC, with normalized audio.
- `out/index.html`: local review player with chapter buttons; serve the folder over HTTP.
- `out/storyboard.jpg`: overview of the eight scenes.

The source files are here:

- `src/Film.tsx`: editable Remotion motion design, transitions, device frames and audio placement.
- `film.json`: script, voice, prompts, model IDs and minimum scene lengths.
- `src/timeline.json`: generated timing based on measured narration lengths.
- `hyperframes/index.html`: HyperFrames composition with eight separately editable chapter clips.
  The chapter clips contain the finished Remotion design and mix. Edit internal graphics and
  narration in the Remotion source, then render again to refresh the handoff.

```sh
cd video
npm ci
npm run studio
```

For a simple local review player:

```sh
cd video/out
python3 -m http.server 4399 --bind 127.0.0.1
# http://127.0.0.1:4399
```

For HyperFrames:

```sh
cd video
npx hyperframes preview hyperframes
npx hyperframes lint hyperframes
npx hyperframes render hyperframes -o out/torie-chan-hyperframes.mp4 --fps 24
```

## Reproduce the film

Requirements: Apple Silicon macOS with Xcode/Swift, Node 22+, Chrome, FFmpeg, Python 3, and a fal key.
The Chrome executable can be overridden with `CHROME_PATH`.

```sh
cd video
npm ci
npm run capture
npm run generate -- --dry-run
npm run generate
npm run assemble
npm run check
npm run render -- --stills
npm run render
npm run storyboard
npm run verify
```

`capture` builds a debug app and invokes `--capture-film`. That branch runs before the live
guard is constructed. It exports deterministic 1440 × 900 native frames and encodes them into
nine product clips. It does not replace the installed app or change guard preferences.

`generate` makes **paid fal requests** for eight narration segments and three café clips.
It reads `FAL_KEY`, `FAL_AI_API_KEY` or `FAL_API_KEY` from the process environment, `../.env`,
or `video/.env`. Keys stay in the local Node process and are never imported into browser code.

Each submission is saved in `.cache/<asset>.json` before polling; an interrupted run resumes
that request instead of creating a second job. Matching downloaded files are reused. Changed
inputs stop with an explanation: archive the corresponding cached job and media only when you
intend to pay for a new version. `--audio-only`, `--video-only`, and `--only=vo-arm` limit work.
Do not run two generators against the same asset concurrently. Cached completed result URLs
can expire; the downloaded local files are the durable copies.

`assemble` measures audio, computes frame-aligned scene durations, writes a transcript, and
creates the original ambient score. `render -- --preview` produces a smaller review export;
`render` creates the 1080p master, review page, and HyperFrames chapter handoff. Output audio
targets -16 LUFS and -1.5 dBTP. Regenerating the film does not regenerate paid assets.

The warning/alarm and social reactions are timed against word timestamps from the existing
MiniMax recordings. `node scripts/align-narration.mjs` refreshes those cached timing references
through fal's Whisper transcription endpoint; it is a separate paid analysis pass, with no
voice or video regeneration. `npm run verify` fully decodes the master and checks dimensions,
frame rate, audio peaks and unexpected black gaps, saving `out/verification.json`.

Generated media, job records, source frames, dependencies and outputs are ignored by Git.
Keep a copy of `public/` and `.cache/` alongside source files to retain the exact generated takes.

## Pronouncing the name

The name should sound like Japanese -chan (ちゃん), not the English word "can". The `vo-arm` and
`vo-hero` recordings contain spliced takes generated with the spelling `Torie-chahn`, while
`film.json` keeps `Torie-chan` so the transcript reads correctly. If either segment is ever
regenerated, use the `chahn` spelling for the prompt. The approved takes and the previous recordings
are in `.cache/revisions/japanese-chan/`.

## Source references

- [FLUX 3 Max collection](https://fal.ai/explore/flux-3-max-by-fal)
- [FLUX 3 Max text-to-video API](https://fal.ai/models/blackforestlabs/flux-3-max/text-to-video/api)
- [MiniMax Speech 2.8 HD API](https://fal.ai/models/fal-ai/minimax/speech-2.8-hd/api)
- [Remotion rendering](https://www.remotion.dev/docs/render)
- [HyperFrames](https://github.com/heygen-com/hyperframes)
