"""Original, deterministic ambient underscore. No samples or third-party music."""
import array
import json
import math
from pathlib import Path
import random
import sys
import wave

root = Path(__file__).resolve().parents[1]
duration = float(sys.argv[1])
rate = 44100
timeline = json.loads((root / 'src/timeline.json').read_text())
random.seed(4711)
chords = [(110.0, 130.8128, 164.8138, 246.9417),
          (87.3071, 130.8128, 174.6141, 220.0),
          (130.8128, 164.8138, 195.9977, 261.6256),
          (97.9989, 123.4708, 146.8324, 195.9977)]
tamper = next(s['from'] / 24 for s in timeline['scenes'] if s['id'] == 'tamper')
alert = next(s['from'] / 24 for s in timeline['scenes'] if s['id'] == 'alert')


def save(name, seconds, sound):
    data = array.array('h')
    for i in range(int(seconds * rate)):
        t = i / rate
        left, right = sound(t)
        data.append(int(max(-1, min(1, left)) * 32767))
        data.append(int(max(-1, min(1, right)) * 32767))
    with wave.open(str(root / f'public/generated/{name}.wav'), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(data.tobytes())


def score(t):
    chord = chords[int(t / 8) % 4]
    previous = chords[(int(t / 8) - 1) % 4]
    blend = min(1, (t % 8) / 1.5)
    fade = min(1, t / 3, max(0, (duration - t) / 4))
    tension = 1.12 if tamper < t < alert else 0.85
    left = right = 0.0
    for j, (f, prev) in enumerate(zip(chord, previous)):
        # Independent drifting oscillators soften the pad's attack.
        gain = (0.55 + 0.14 * math.sin(t * 0.42 + j)) * 0.011
        cur = math.sin(math.tau * f * t) + 0.16 * math.sin(math.tau * f * 2 * t)
        old = math.sin(math.tau * prev * t)
        left += gain * (blend * cur + (1 - blend) * old)
        right += gain * (blend * math.sin(math.tau * (f + 0.16) * t) + (1 - blend) * old)
    beat = t % 0.833333
    note = chord[int(t / 0.833333) % 4] * 4
    env = math.exp(-beat * 6) * min(1, beat * 100)
    ping = 0.019 * env * math.sin(math.tau * note * beat)
    pulse_time = t % 1.666667
    pulse = 0.018 * math.exp(-pulse_time * 8) * math.sin(math.tau * 55 * pulse_time)
    return ((left + ping + pulse) * fade * tension, (right + ping * 0.7 + pulse) * fade * tension)


save('score', duration, score)
save('notification', 1.4, lambda t: (
    0.055 * math.exp(-t * 5) * (math.sin(math.tau * 880 * t) + 0.5 * math.sin(math.tau * 1320 * t)),
    0.055 * math.exp(-t * 5) * (math.sin(math.tau * 880 * t) + 0.5 * math.sin(math.tau * 1320 * t))))
save('alarm-cue', 1.2, lambda t: (
    0.045 * min(1, t * 30, (1.2 - t) * 8) * math.sin(math.tau * (690 * t - 17 * math.cos(t * 14))),
    0.045 * min(1, t * 30, (1.2 - t) * 8) * math.sin(math.tau * (690 * t - 17 * math.cos(t * 14)))))
print('Original ambient score and restrained editorial cues ready.')
