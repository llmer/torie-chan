import React from 'react';
import {AbsoluteFill, Audio, Easing, Img, interpolate, Loop, OffthreadVideo, Sequence,
  spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import timeline from './timeline.json';

type Scene = typeof timeline.scenes[number];
const cream = '#fff4e4';
const violet = '#a89bff';
const muted = '#b6acba';
const ease = Easing.bezier(0.22, 1, 0.36, 1);
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const enter = (f: number, delay = 0) => interpolate(f, [delay, delay + 26], [0, 1], {...clamp, easing: ease});
const serif: React.CSSProperties = {fontFamily: 'Georgia, Times New Roman, serif', fontStyle: 'italic', fontWeight: 400};
const small: React.CSSProperties = {fontSize: 19, fontWeight: 600, letterSpacing: 3.5, textTransform: 'uppercase'};

function Native({clip, duration = 4, startFrom = 0}: {clip: string; duration?: number; startFrom?: number}) {
  return <Loop durationInFrames={duration * 24}><OffthreadVideo src={staticFile(`app/${clip}.mp4`)} startFrom={startFrom} muted
    style={{width: '100%', height: '100%', objectFit: 'contain', display: 'block'}} /></Loop>;
}

function Device({children, width = 1110, style = {}}: {children: React.ReactNode; width?: number; style?: React.CSSProperties}) {
  return <div style={{position: 'absolute', width, ...style}}>
    <div style={{padding: 13, paddingTop: 23, borderRadius: '24px 24px 9px 9px', background: 'linear-gradient(135deg,#53525b,#15141b 40%,#77717c)',
      boxShadow: '0 45px 100px #0009, 0 0 90px #7360d01c', border: '1px solid #8f879955'}}>
      <div style={{position: 'absolute', top: 9, left: '50%', width: 5, height: 5, background: '#151319', borderRadius: '50%'}} />
      <div style={{aspectRatio: '1.6', background: '#111116', borderRadius: 9, overflow: 'hidden', position: 'relative'}}>{children}</div>
    </div>
    <div style={{height: 16, marginLeft: -32, marginRight: -32, borderRadius: '2px 2px 60% 60% / 2px 2px 100% 100%',
      background: 'linear-gradient(#b0aab8,#4f4c58 42%,#25222b)', boxShadow: '0 25px 40px #0008'}} />
  </div>;
}

function Eyebrow({children, color = violet}: {children: React.ReactNode; color?: string}) {
  return <div style={{...small, color, display: 'flex', alignItems: 'center', gap: 15}}>
    <span style={{width: 26, height: 1, background: color}} />{children}</div>;
}

function SceneTitle({children, sub, width = 630}: {children: React.ReactNode; sub?: string; width?: number}) {
  const f = useCurrentFrame();
  const p = enter(f, 7);
  return <div style={{position: 'absolute', left: 112, top: 206, width, opacity: p, transform: `translateY(${(1 - p) * 30}px)`}}>
    <h1 style={{fontSize: 82, letterSpacing: -4, lineHeight: 1.04, fontWeight: 500, margin: '0 0 28px', whiteSpace: 'pre-line'}}>{children}</h1>
    {sub && <p style={{fontSize: 26, lineHeight: 1.55, color: muted, maxWidth: 510, margin: 0}}>{sub}</p>}
  </div>;
}

function Tag({children, color = violet}: {children: React.ReactNode; color?: string}) {
  return <div style={{display: 'flex', alignItems: 'center', gap: 12, fontSize: 21, color, marginTop: 20}}>
    <span style={{width: 7, height: 7, borderRadius: '50%', background: color, boxShadow: `0 0 18px ${color}77`}} />{children}</div>;
}

function Cafe() {
  const f = useCurrentFrame();
  return <AbsoluteFill>
    <OffthreadVideo src={staticFile('generated/cafe.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover', transform: `scale(${1.03 + f / 18000})`}} />
    <AbsoluteFill style={{background: 'linear-gradient(90deg,#0c0810d9,transparent 90%),linear-gradient(0deg,#09070ce8,transparent 85%)'}} />
    <div style={{position: 'absolute', left: 115, top: 418, opacity: enter(f, 12)}}>
      <Eyebrow color="#e6ba82">A MOMENT AWAY</Eyebrow>
      <h1 style={{...serif, fontSize: 164, lineHeight: 1.04, letterSpacing: -7, margin: '30px 0'}}>Back in five.</h1>
      <p style={{fontSize: 30, color: '#e4d5c4', margin: 0, opacity: enter(f, 45)}}>Who’s watching your laptop?</p>
    </div>
  </AbsoluteFill>;
}

function Arm() {
  const f = useCurrentFrame();
  const p = enter(f, 18);
  const text = "Hey Claude, can you\nwatch my computer?\nI've got to take a\nnumber 2.";
  const typed = text.slice(0, Math.floor(interpolate(f, [64, 162], [0, text.length], clamp)));
  return <>
    <SceneTitle>One request.{'\n'}<span style={serif}>Eyes on.</span></SceneTitle>
    <div style={{position: 'absolute', left: 115, top: 470, width: 498, padding: '30px 28px', border: '1px solid #a89bff38',
      background: '#17131f', borderRadius: 15, opacity: enter(f, 24)}}>
      <div style={{...small, fontSize: 13, letterSpacing: 2, color: muted}}>EXAMPLE AGENT REQUEST</div>
      <div style={{fontSize: 28, lineHeight: 1.4, fontFamily: 'SF Mono, Menlo, monospace', whiteSpace: 'pre-line', marginTop: 20, minHeight: 160}}>{typed}<span style={{color: violet, opacity: Math.floor(f / 12) % 2}}>▍</span></div>
      <div style={{marginTop: 25, fontSize: 17, color: violet, opacity: enter(f, 170)}}>Claude → arm_guard</div>
    </div>
    <Device width={1060} style={{left: 762, top: 231, transform: `perspective(1800px) rotateY(${-5 + p * 3}deg) translateY(${(1 - p) * 45}px)`, opacity: p}}>
      <Sequence durationInFrames={180}><Native clip="sleepy" /></Sequence>
      <Sequence from={180} durationInFrames={66}><Native clip="arming" duration={2.75} startFrom={54} /></Sequence>
      <Sequence from={246}><Native clip="watching" duration={6} /></Sequence>
    </Device>
    <div style={{position: 'absolute', left: 115, top: 812, color: muted, fontSize: 21}}>A kawaii laptop guard for macOS.</div>
  </>;
}

function Watch() {
  const f = useCurrentFrame();
  const mode = f < 68 ? 'watching' : f < 121 ? 'close' : 'skeptical';
  return <>
    <SceneTitle sub="People pass. Someone gets close. Someone lingers.">Cute.{'\n'}<span style={serif}>Until it counts.</span></SceneTitle>
    <Device width={1060} style={{left: 762, top: 215, transform: `translateY(${Math.sin(f / 60) * 4}px)`}}>
      <Sequence key={mode} from={mode === 'watching' ? 0 : mode === 'close' ? 68 : 121} layout="none"><Native clip={mode} duration={mode === 'watching' ? 6 : 4} /></Sequence>
    </Device>
    <div style={{position: 'absolute', left: 115, top: 640}}>
      {['Eyes follow passers-by', 'A little curiosity', 'A very pointed side-eye'].map((t, i) => <div key={t} style={{opacity: enter(f, [10, 68, 121][i])}}><Tag color={i === 2 ? '#e6ba82' : violet}>{t}</Tag></div>)}
    </div>
  </>;
}

function Tamper({scene}: {scene: Scene}) {
  const f = useCurrentFrame();
  const cut = 70;
  const alarmAt = 140;
  if (f < cut) return <>
    <OffthreadVideo src={staticFile('generated/reach.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />
    <AbsoluteFill style={{background: 'linear-gradient(90deg,#160c12c9,transparent),linear-gradient(0deg,#0c070dcf,transparent 70%)'}} />
    <div style={{position: 'absolute', left: 115, top: 570, opacity: enter(f, 8)}}>
      <Eyebrow color="#edbb7e">SOMEONE TRIES IT</Eyebrow>
      <h1 style={{...serif, fontSize: 128, margin: '25px 0'}}>Hands off.</h1>
    </div>
  </>;
  return <>
    <AbsoluteFill style={{background: f >= alarmAt ? 'radial-gradient(ellipse at 66% 50%,#570e2455,transparent 74%)' : 'radial-gradient(ellipse at 66% 50%,#5b341b55,transparent 74%)'}} />
    <div style={{position: 'absolute', left: 112, top: 220, width: 570, opacity: enter(f, cut)}}>
      <Eyebrow color={f >= alarmAt ? '#ff9297' : '#e9b87a'}>{f >= alarmAt ? 'LIFT DETECTED' : 'MOTION DETECTED'}</Eyebrow>
      <h1 style={{fontSize: 94, lineHeight: 1.04, letterSpacing: -4, fontWeight: 500, margin: '32px 0'}}>{f >= alarmAt ? <>A louder<br /><span style={serif}>warning.</span></> : <>A voice.<br /><span style={serif}>A boundary.</span></>}</h1>
      <p style={{fontSize: 27, lineHeight: 1.55, color: muted}}>{f >= alarmAt ? 'Siren through the built-in speakers.' : 'A spoken warning when the laptop is disturbed.'}</p>
      <div style={{...small, fontSize: 14, color: f >= alarmAt ? '#ff9297' : '#e9b87a', marginTop: 45}}>{f >= alarmAt ? '02 / ALARM' : '01 / WARNING'}</div>
    </div>
    <Device width={1050} style={{left: 775, top: 214, transform: `scale(${interpolate(f, [cut, scene.durationInFrames], [0.98, 1.025], clamp)})`}}>
      {f < alarmAt ? <Sequence from={cut} layout="none"><Native clip="warning" /></Sequence> : <Sequence from={alarmAt} layout="none"><Native clip="alarm" /></Sequence>}
    </Device>
  </>;
}

function Phone() {
  const f = useCurrentFrame();
  const p = spring({frame: f - 25, fps: 24, config: {damping: 20, stiffness: 85}});
  return <>
    <SceneTitle sub="iMessage to your iPhone. An encrypted alarm photo on your Mac.">An alarm.{'\n'}<span style={serif}>An alert.</span></SceneTitle>
    <div style={{position: 'absolute', left: 115, top: 645}}>
      <Tag>Phone alerts enabled</Tag><Tag>Alarm photo encrypted on disk</Tag>
      <div style={{color: muted, fontSize: 18, marginTop: 28, maxWidth: 480, lineHeight: 1.6}}>Photo attachments are optional, and off by default.</div>
    </div>
    <div style={{position: 'absolute', left: 1087, top: 150, width: 365, height: 735, borderRadius: 62, padding: 12,
      background: 'linear-gradient(135deg,#8b8596,#17151f 35%,#5b5268)', boxShadow: '0 40px 90px #0009',
      transform: `perspective(1600px) rotateY(-8deg) translateY(${(1 - p) * 90}px)`, opacity: p}}>
      <div style={{height: '100%', borderRadius: 50, background: 'radial-gradient(ellipse at 30% 5%,#63527a,#1b142b 58%,#17111f)', overflow: 'hidden', position: 'relative', padding: 22}}>
        <div style={{position: 'absolute', top: 13, left: 121, width: 101, height: 28, background: '#08070a', borderRadius: 20}} />
        <div style={{textAlign: 'center', marginTop: 92, fontSize: 17, fontWeight: 500, color: '#eee1ff'}}>Wednesday, October 21</div>
        <div style={{textAlign: 'center', fontSize: 86, fontWeight: 300, letterSpacing: -5, color: '#f4eaff'}}>4:42</div>
        <div style={{marginTop: 50, padding: 20, borderRadius: 24, background: '#ece6f2e8', color: '#211b2d', opacity: enter(f, 55)}}>
          <div style={{display: 'flex', gap: 10, alignItems: 'center', fontSize: 12, letterSpacing: 1, color: '#5c5265'}}>
            <div style={{width: 25, height: 25, borderRadius: 7, background: '#47ae62', display: 'grid', placeItems: 'center'}}><svg width="16" height="16" viewBox="0 0 24 24"><path fill="white" d="M12 3C6.5 3 2 6.7 2 11.2c0 2.6 1.5 5 3.9 6.5L5 22l4.6-2.9c.8.2 1.6.3 2.4.3 5.5 0 10-3.7 10-8.2S17.5 3 12 3Z" /></svg></div>MESSAGES<span style={{marginLeft: 'auto'}}>now</span>
          </div>
          <div style={{fontSize: 19, fontWeight: 650, marginTop: 13}}>Torie-chan: ALARM</div>
          <div style={{fontSize: 18, lineHeight: 1.45, marginTop: 7}}>Lifted. The siren is going. A photo was saved on your Mac.</div>
          <div style={{fontSize: 14, marginTop: 7, color: '#766a80'}}>4:42 PM</div>
        </div>
        <div style={{position: 'absolute', bottom: 12, left: 114, width: 115, height: 5, background: '#ffffff99', borderRadius: 5}} />
      </div>
    </div>
    <div style={{position: 'absolute', left: 1098, top: 926, color: muted, fontSize: 16}}>Illustrative iMessage · alerts enabled</div>
  </>;
}

function Privacy() {
  const f = useCurrentFrame();
  const items = [
    ['On-device detection', 'People are noticed. Faces aren’t recognized.'],
    ['No continuous recording', 'A photo is saved only when the alarm goes off.'],
    ['You hold the keys', 'Your agent can arm. Your code or Touch ID disarms.'],
  ];
  return <>
    <div style={{position: 'absolute', left: 115, top: 190, opacity: enter(f, 8)}}>
      <Eyebrow>PRIVATE BY DESIGN</Eyebrow>
      <h1 style={{fontSize: 82, fontWeight: 500, letterSpacing: -4, margin: '27px 0 0'}}>A guard. <span style={serif}>With boundaries.</span></h1>
    </div>
    <div style={{position: 'absolute', left: 115, top: 432, width: 1690, display: 'flex', gap: 38}}>
      {items.map(([title, body], i) => {
        const p = enter(f, 24 + i * 28);
        return <div key={title} style={{flex: 1, borderTop: '1px solid #a89bff55', paddingTop: 34, opacity: p, transform: `translateY(${(1 - p) * 20}px)`}}>
          <div style={{...serif, fontSize: 72, color: '#a89bff80'}}>0{i + 1}</div>
          <h2 style={{fontSize: 35, fontWeight: 500, letterSpacing: -1, margin: '25px 0 18px'}}>{title}</h2>
          <p style={{fontSize: 25, lineHeight: 1.55, color: muted, maxWidth: 440, margin: 0}}>{body}</p>
        </div>;
      })}
    </div>
    <div style={{position: 'absolute', left: 115, top: 842, color: '#9b909f', fontSize: 20}}>Built for a brief break. A deterrent and an early warning.</div>
  </>;
}

function Return() {
  const f = useCurrentFrame();
  if (f < 67) return <>
    <OffthreadVideo src={staticFile('generated/return.mp4')} muted style={{height: '100%', width: '100%', objectFit: 'cover'}} />
    <AbsoluteFill style={{background: 'linear-gradient(0deg,#0a080ddd,transparent 90%)'}} />
    <div style={{...serif, position: 'absolute', left: 112, top: 620, fontSize: 117, letterSpacing: -4, opacity: enter(f, 3)}}>And you’re back.</div>
  </>;
  return <>
    <SceneTitle sub="Touch ID or your code. A welcome, and the story of your five minutes away.">Your laptop.{'\n'}<span style={serif}>Your way back in.</span></SceneTitle>
    <div style={{position: 'absolute', left: 115, top: 712, opacity: enter(f, 78)}}><Tag color="#99d6b3">Owner authenticated</Tag><Tag color="#99d6b3">Session summary ready</Tag></div>
    <Device width={1060} style={{left: 762, top: 215, opacity: enter(f, 65)}}><Sequence from={67} layout="none"><Native clip="welcome" duration={5} /></Sequence></Device>
  </>;
}

function Hero() {
  const f = useCurrentFrame();
  const p = enter(f, 6);
  return <>
    <div style={{position: 'absolute', left: 130, top: 217, opacity: p}}>
      <Img src={staticFile('app/icon.png')} style={{height: 90, width: 90, borderRadius: 23, boxShadow: '0 10px 70px #8974ee2f'}} />
      <div style={{fontSize: 104, letterSpacing: -5, fontWeight: 500, marginTop: 26}}>Torie-chan<span style={{color: violet}}>.</span></div>
      <div style={{...serif, fontSize: 49, marginTop: 15, color: '#e1d4e7'}}>Small face.<br />Big don’t-touch energy.</div>
      <div style={{fontSize: 24, color: muted, marginTop: 35}}>A kawaii laptop guard for macOS.</div>
      <div style={{fontSize: 24, color: violet, marginTop: 46, letterSpacing: 0.5}}>github.com/llmer/torie-chan</div>
    </div>
    <Device width={1000} style={{left: 820, top: 228, transform: `perspective(1600px) rotateY(-5deg) scale(${1 + f / 18000})`, opacity: p}}><Native clip="watching" duration={6} /></Device>
    <div style={{position: 'absolute', left: 130, top: 908, fontSize: 18, color: '#968a9d'}}>A deterrent and early warning. Keep Find My enabled.</div>
  </>;
}

function SceneBody({scene}: {scene: Scene}) {
  switch (scene.id) {
    case 'cafe': return <Cafe />;
    case 'arm': return <Arm />;
    case 'watch': return <Watch />;
    case 'tamper': return <Tamper scene={scene} />;
    case 'alert': return <Phone />;
    case 'privacy': return <Privacy />;
    case 'return': return <Return />;
    default: return <Hero />;
  }
}

function Shot({scene}: {scene: Scene}) {
  const f = useCurrentFrame();
  const p = interpolate(f, [0, 12], [0, 1], clamp);
  return <AbsoluteFill style={{background: '#0c0a11', opacity: p, overflow: 'hidden'}}>
    <AbsoluteFill style={{background: 'radial-gradient(ellipse at 75% 42%, #51406b2e,transparent 60%),radial-gradient(ellipse at 12% 90%,#6e382516,transparent 65%)'}} />
    <SceneBody scene={scene} />
    <div style={{position: 'absolute', top: 100, left: 115, right: 115, display: 'flex', alignItems: 'center', justifyContent: 'space-between', color: '#fff0dfb8'}}>
      <div style={{...small, fontSize: 17, letterSpacing: 4}}>TORIE-CHAN</div>
      <div style={{...small, fontSize: 14, letterSpacing: 2}}>{scene.chapter}</div>
    </div>
    {scene.id !== 'cafe' && scene.id !== 'privacy' && scene.id !== 'hero' && <div style={{position: 'absolute', bottom: 100, left: 115, fontSize: 15, color: '#aca0b4'}}>Native app UI · dramatized scenario</div>}
  </AbsoluteFill>;
}

export const Film: React.FC = () => {
  const f = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const tamper = timeline.scenes.find((s) => s.id === 'tamper')!;
  const alert = timeline.scenes.find((s) => s.id === 'alert')!;
  const fadeOut = interpolate(f, [durationInFrames - 22, durationInFrames - 1], [0, 1], clamp);
  return <AbsoluteFill style={{background: '#0c0a11', color: cream, fontFamily: 'Avenir Next, Helvetica Neue, Arial, sans-serif'}}>
    {timeline.scenes.map((scene) => <Sequence key={scene.id} from={scene.from} durationInFrames={scene.durationInFrames}>
      <Shot scene={scene} />
      <Sequence from={scene.voiceFrom}><Audio src={staticFile(`generated/vo-${scene.id}.mp3`)} volume={0.94} /></Sequence>
    </Sequence>)}
    <Audio src={staticFile('generated/score.wav')} volume={1} />
    <Sequence from={tamper.from + 140}><Audio src={staticFile('generated/alarm-cue.wav')} volume={0.65} /></Sequence>
    <Sequence from={alert.from + 56}><Audio src={staticFile('generated/notification.wav')} volume={0.7} /></Sequence>
    <AbsoluteFill style={{pointerEvents: 'none', background: 'radial-gradient(ellipse at 50% 45%,transparent 38%,#0005 100%)'}} />
    <div style={{position: 'absolute', top: 0, width: '100%', height: 54, background: '#08070b'}} />
    <div style={{position: 'absolute', bottom: 0, width: '100%', height: 54, background: '#08070b'}} />
    <AbsoluteFill style={{background: '#08070b', opacity: fadeOut}} />
  </AbsoluteFill>;
};
