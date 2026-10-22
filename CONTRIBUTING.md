# Contributing to Torie-chan

Thanks for helping Torie-chan keep an eye on people's laptops. This guide covers how to build it,
how the code is laid out, and how to send a change.

## Getting set up

You need an Apple Silicon Mac (the motion sensor is Apple Silicon only), macOS 14 or later, and Xcode
with Swift 6.2 or newer. CI builds with Xcode 26 / Swift 6.2, so don't rely on newer-only language
features.

```sh
git clone https://github.com/llmer/torie-chan.git
cd torie-chan
make test        # unit tests
make app         # build/Torie-chan.app, signed with your first Apple Development identity
make run         # build and open it
```

Open `Package.swift` in Xcode to edit. Camera, Messages and keychain access need the signed `.app`
from `make app`; `swift run` won't get those permissions.

Other useful targets:

| Command | What it does |
|---|---|
| `make mcp-test` | Smoke-tests the MCP server handshake |
| `make icon` | Regenerates `Resources/AppIcon.icns` from the eye renderer |
| `make dmg` | Builds `build/Torie-chan-<version>.dmg` with the styled window |
| `make install` | Copies the app to `/Applications` (needed for lid-close protection) |

### Seeing your UI changes

- **Settings > Developer** shows the live eyes, the camera frames with detection boxes, and every
  guard-screen state. It never sounds the alarm, speaks, sends messages or writes to the event log.
- Debug builds can render every Settings section and guard state to PNGs without screen-recording
  permission:

  ```sh
  CONFIG=debug scripts/build-app.sh
  build/Torie-chan.app/Contents/MacOS/TorieChan --snapshot-settings /tmp/shots --appearance dark
  ```

## How the code is laid out

| Path | What lives there |
|---|---|
| `Sources/TorieChan/GuardController.swift` | The state machine: disarmed, arming, armed, suspicious, alarm |
| `Sources/TorieChan/Sensors/` | Motion (accelerometer/gyro), camera and Vision tracking, lid and power |
| `Sources/TorieChan/UI/EyesModel.swift`, `EyesView.swift` | Torie-chan's eyes: spring model and vector renderer |
| `Sources/TorieChan/UI/SettingsView.swift`, `GuardScreen.swift` | Settings window and the full-screen guard screen |
| `Sources/TorieChan/Alarm.swift`, `Notifier.swift` | Siren and speech, iMessage alerts |
| `Sources/bg-mcp/` | The MCP server agents talk to |
| `Sources/bg-helper/` | Privileged helper for lid-close protection |
| `Sources/GuardShared/` | Types shared between the app, MCP server and helper |
| `Tests/TorieChanTests/` | Unit tests |
| `scripts/` | Build, packaging, notarization and icon scripts |

## Principles

A few things are deliberate. Please keep them that way, or open an issue to discuss first.

- **Agents can't disarm.** There is no disarm command in the MCP server or the control socket.
- **Privacy first.** Face *detection* only, never recognition or face templates. Camera frames stay in
  memory. The alarm photo is the only image ever saved, and it only leaves the Mac if the owner turns
  on "Include the alarm photo".
- **No third-party services.** Alerts go over iMessage through Messages on the Mac.
- **No emoji** anywhere: UI, notifications, docs or code. Use SF Symbols, or draw it as a vector shape
  in code (see the sweat drop and anger mark in `EyesView.swift`).
- **Silent tooling.** Developer tools and previews must never trigger real alarms, speech or messages.
- **Accessibility.** New controls need VoiceOver labels; motion should respect Reduce Motion.
- Match the style of the code around you: naming, comment density, and small focused types.

## Sending a change

1. Fork the repo (or create a branch if you have access) from `main`.
2. Make your change. Add or update tests in `Tests/TorieChanTests/` when you touch behavior,
   especially motion detection, filtering or anything that decides whether the alarm sounds.
3. Run `make test` and `make app` before pushing. If you touched hardware-facing code (alarm, sensors,
   lid, kiosk, alerts), run the relevant part of the manual checklist in [docs/TESTING.md](docs/TESTING.md).
4. Open a pull request against `main` and fill in the template.

### Commit and pull request format

We use [Conventional Commits](https://www.conventionalcommits.org/). Pull requests are squash-merged,
so **the PR title becomes the commit message on `main`** and must follow the format. A check on every
pull request enforces it.

```
<type>(<optional scope>): <summary>
```

- **Summary:** imperative, lowercase start, no trailing period, 72 characters or fewer.
- **Types:**

  | Type | Use it for |
  |---|---|
  | `feat` | A new feature |
  | `fix` | A bug fix |
  | `perf` | A performance improvement |
  | `refactor` | Code changes that don't change behavior |
  | `docs` | Documentation only |
  | `test` | Adding or fixing tests |
  | `build` | Build scripts, packaging, dependencies |
  | `ci` | GitHub Actions |
  | `chore` | Anything else that doesn't touch the app's behavior |
  | `style` | Formatting only |
  | `revert` | Reverting an earlier change |

- **Scopes** (optional): `eyes`, `guard`, `sensors`, `alarm`, `alerts`, `settings`, `devtools`, `mcp`,
  `helper`, `build`, `ci`, `docs`.
- **Breaking changes:** add `!` after the type or scope, for example `feat(mcp)!: rename arm_guard`, and
  explain the migration in the PR description.

Examples:

```
feat(eyes): add a sleepy yawn when the guard has been idle for an hour
fix(alarm): restart the siren after audio devices change
docs: explain how to set up lid-close protection
ci: cache the Swift build directory
```

Individual commits on your branch can be anything; only the PR title lands on `main`.

## Releasing (maintainers)

Run the manual hardware checklist in [docs/TESTING.md](docs/TESTING.md) first. Pushing a version tag
then runs the release workflow. It tests, builds, signs with Developer ID,
notarizes, packages the disk image and publishes a GitHub Release.

```sh
git checkout main && git pull
git tag v0.2.0 && git push origin v0.2.0
```

Use semantic versioning: `feat` bumps the minor version, `fix` bumps the patch, and a breaking change
bumps the major (or the minor while we're below 1.0). The signing secrets are listed at the top of
`.github/workflows/build.yml`.

The release also publishes `appcast.xml`, which existing installs use to update themselves (Sparkle).

**Homebrew.** The cask lives in `packaging/homebrew/torie-chan.rb` and is published in the
`llmer/homebrew-tap` repository. After a release, point it at the new disk image and copy it over:

```sh
scripts/update-cask.sh 0.2.0 "$(gh release download v0.2.0 -p '*.sha256' -O - | cut -d' ' -f1)"
```

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
