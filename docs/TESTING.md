# Testing Torie-chan

## Automated

```sh
make test     # unit and integration tests
```

CI runs these on every push and pull request, with a per-file coverage table in the run summary.
They cover the logic: the guard state machine (with fake sensors and a controllable clock), the disarm
code and lockouts, the root helper's lease, person tracking, iMessage formatting, the event log, the
control socket, and the real `bg-mcp` binary end to end. Tests use a temporary data folder and never
touch your keychain, Messages, speakers or a running Torie-chan.

## Manual hardware checklist

Some things only real hardware can show: speakers, the lid, Messages, Touch ID, the camera. Run this list
before tagging a release, on an Apple Silicon MacBook with the release build installed in /Applications.
Note the macOS version and Mac model in the release PR.

Tip: **Settings > Developer** previews every screen and expression silently. Use it to check visuals
first, and save the loud tests for the end.

### Setup

- [ ] Fresh install from the disk image: the window shows the background, the arrow and both icons; the
      mounted volume has Torie-chan's icon
- [ ] First launch opens Settings with the setup checklist; Arm Guard is disabled and says what's missing
- [ ] Setting a code shorter than 6 digits is refused; a 6-digit code is accepted
- [ ] Lid-close protection: Install, approve in Login Items, and the Sensors page shows Installed
- [ ] Camera: Allow; the Developer page shows live frames with boxes around you

### Guarding

- [ ] Arm from the sidebar: 10-second countdown with the checklist, then "Watching~"
- [ ] The eyes follow you as you walk past, and blink, and look around when nobody's there
- [ ] Typing on the guard screen and a single knock on the table don't warn
- [ ] Repeated knocking gives a spoken warning (from the speakers, even with AirPods connected) and,
      if alerts are on, an iMessage
- [ ] Touching the keyboard right after a warning cancels it
- [ ] Lifting the laptop sounds the siren from the built-in speakers at full volume
- [ ] Plugging in headphones while armed counts as tampering, and the siren keeps playing on the speakers
- [ ] Unplugging the charger, then leaving it unplugged, sounds the alarm
- [ ] Closing the lid halfway: the eyes duck under the edge; reopening: they peek back out with sparkles
- [ ] Closing the lid fully: the alarm sounds within a couple of seconds and keeps going with the lid
      shut; you get the iMessage
- [ ] Pressing the power button or locking the screen (Control-Command-Q) sounds the alarm
- [ ] Pressing Spotlight (Command-Space) and staying there for 2 seconds sounds the alarm

### Disarming

- [ ] Correct code disarms; the welcome-back screen shows the debrief
- [ ] Touch ID on the guard screen disarms (no system pop-up appears)
- [ ] Three wrong codes lock the keypad and sound the alarm; the lockout survives quitting and relaunching
- [ ] After disarming, closing the lid puts the Mac to sleep normally (lid-close sleep was restored)
- [ ] Force-quitting Torie-chan while armed (Activity Monitor) relaunches it straight into the alarm

### Alerts

- [ ] Send Test Message reaches your iPhone; note whether it buzzed when sent to your own number
- [ ] With "Include the alarm photo" on, an alarm sends the photo; with it off, only text

### AI agents

- [ ] `claude mcp add torie-chan -- "/Applications/Torie-chan.app/Contents/MacOS/bg-mcp"`, then
      "watch my laptop, back in 5": the guard arms with focus on its screen, and the agent's reply lists
      what's protected and any gaps
- [ ] Asking the agent to disarm doesn't work (there's no tool for it)
- [ ] After disarming, asking "how did it go?" gives the debrief from `last_session`

### Accessibility

- [ ] VoiceOver reads the sidebar sections, the keypad ("digits entered") and announces the alarm
- [ ] Reduce Motion: no bobbing or trembling, and the alarm background doesn't pulse
