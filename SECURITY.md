# Security

Torie-chan guards people's laptops and installs a privileged helper, so security reports matter a lot.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/llmer/torie-chan/security/advisories/new).
Include what you found, how to reproduce it, and the version (Torie-chan > About).

You'll get an acknowledgement within a few days. Fixes ship as a new signed release, and reporters are
credited in the advisory unless they'd rather not be.

## Supported versions

Only the latest release gets security fixes.

## What's in scope

The interesting trust boundaries:

| Component | What it trusts | Notes |
|---|---|---|
| `bg-helper` (runs as root via `SMAppService`) | XPC callers signed with Torie-chan's bundle ID **and** the same Team ID | Only toggles `pmset disablesleep` on a lease, and relaunches the app if it dies while armed: as the user who armed it, never as root, and only if the bundle is still validly signed by the same team. Each user's guard is their own; another user can't take it over or clear it |
| Control socket `~/Library/Application Support/Torie-chan/control.sock` | Local processes of the same user (socket is `0600` in a `0700` folder) | Commands: arm, status, events, last session, post update. **There is no disarm.** |
| `bg-mcp` (MCP server for AI agents) | Whatever agent the user connects | Can arm and read; can't disarm; never returns alarm photo paths; agent text is sanitized and length-capped |
| iMessage alerts | Messages.app via `osascript` | Recipient, text and photo path are passed as arguments after `--`, never spliced into the script; the recipient must look like a phone number or email |
| Disarm code | Keychain (PBKDF2-SHA256, 200k iterations) | 3 free tries, then lockouts that escalate and survive relaunch; guessing sounds the alarm |

Especially interesting: anything that disarms the guard or silences the siren without the code or
Touch ID, keeps a Mac from sleeping after Torie-chan exits, gets the root helper to do something
other than toggle sleep, or gets camera images off the Mac.

Out of scope:

- Physical attacks beyond what the README describes (holding the power button will always turn a Mac
  off), and social engineering of the owner.
- **Code already running as your user.** Anything with your user's access, including an AI agent with
  shell access, can quit Torie-chan, delete its data folder, change its settings or read its alarm photos.
  The "agents can't disarm" rule is about the MCP tools and the control socket. If you give an agent a
  shell, it can do whatever you can. Escalating from your user to root, or reaching another user's data,
  is in scope.
