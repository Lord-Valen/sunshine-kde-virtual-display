# Sunshine Virtual Display — KDE Plasma 6 / Wayland

Remote desktop on **KDE Plasma 6 (Wayland / KWin)** with a dedicated **virtual
display**: a headless monitor is created on client connect and streamed to a
[Moonlight](https://moonlight-stream.org/) / **Artemis** client at the client's
requested resolution. The physical monitor is disabled for the duration of the
session so the machine runs fully headless. Everything returns on disconnect.
Apollo-style virtual-display behaviour, built entirely from userspace tools — no
kernel module required.

> Origin note: this began as the KDE counterpart to my Hyprland setup,
> [sunshine-hyprland-virtual-display](https://github.com/jhonsnake/sunshine-hyprland-virtual-display).
> Hyprland creates headless outputs with `hyprctl`, which KWin has no equivalent
> for — so the display layer here is rebuilt around `krfb-virtualmonitor` and
> Sunshine's KWin capture.

## Design rules

The invariants this project upholds — and the reason it has no launcher,
installer, autostart entry, or systemd unit:

- **Sunshine owns its own lifecycle.** It runs as a plain systemd daemon
  (user or system service); this project never launches, wraps, or replaces
  it.
- **The do/undo hooks are the only integration point.** All session state —
  virtual display, sleep inhibitor, physical-output disabling — is created by
  the `do` hook and torn down by the `undo` hook. Recovery from a crashed or
  interrupted session is the `do` hook's reconcile pass, not a separate
  watchdog unit.
- **The repo is the installation.** Scripts resolve siblings via
  `BASH_SOURCE`, so they work from any directory as long as they stay
  together; nothing belongs on PATH or in `~/.local/bin`.
- **Config is static.** `output_name` and `capture` are written up front;
  no script rewrites them at startup.
- **Userspace only.** No kernel modules, no DKMS.

## How it works

The virtual display lifecycle is tied to the client connection via Sunshine's
`global_prep_cmd` (do/undo) hooks:

**On client connect** (`sunshine-connect.sh` — the `do` hook):

1. Reads `SUNSHINE_CLIENT_WIDTH` / `HEIGHT` (set by Sunshine) and creates a
   `krfb-virtualmonitor` output at exactly that resolution (`Virtual-SunshineHeadless`).
2. Acquires an idle/sleep inhibitor so the host doesn't suspend mid-stream.
3. Disables the physical output (`kscreen-doctor output.DP-1.disable`). KWin
   relocates all windows and the cursor to the virtual output automatically.
4. Sunshine finds `Virtual-SunshineHeadless` by name and starts the PipeWire
   screencast.

**On client disconnect** (`sunshine-disconnect.sh` — the `undo` hook):

1. Re-enables the physical output **first** (the machine is never left blind,
   even if a later step fails).
2. Destroys the `krfb-virtualmonitor` process. KWin moves windows back to the
   physical output.
3. Releases the idle/sleep inhibitor.

**Sunshine lifecycle:** this project never launches Sunshine. Run it as a
systemd daemon — the packaged user service (Arch: `app-dev.lizardbyte.app.Sunshine.service`)
or system service (Fedora/Debian: `sunshine.service`) — and it just works:
`config/sunshine.conf` is fully static (`output_name` and `capture` are
written up front), and the connect hook reconciles any leftover state from a
previous crashed session (re-enables stale physical outputs, kills orphaned
virtuals and inhibitors). The virtual output does **not** need to exist at
Sunshine startup; it only needs to exist with that exact name when the `do`
hook runs, which it always will.

| Step | Tool |
|---|---|
| Create the virtual display (at connect) | `krfb-virtualmonitor` (compositor-level output) |
| Let Sunshine capture it | `capture = kwin` |
| Discover the output name | diff of `kscreen-doctor -j` (always `Virtual-<hint>`) |
| Dynamic client resolution | `SUNSHINE_CLIENT_WIDTH` / `SUNSHINE_CLIENT_HEIGHT` env vars |

Because `krfb-virtualmonitor` outputs live at the compositor level (not
DRM/KMS), Sunshine's default `kms` capture can't see them — it **must** use
`capture = kwin`. The output name is written into `sunshine.conf` before
Sunshine launches; Sunshine caches `output_name` at startup and will find the
output by that name once the `do` hook creates it.

## Requirements

KDE Plasma 6 on Wayland, plus:

```bash
# Arch / CachyOS
sudo pacman -S --needed krfb sunshine python jq libkscreen
```

For NVIDIA `nvenc`, the proprietary driver (`nvidia-utils`) must be installed.
AMD/Intel: change `encoder = nvenc` to `encoder = vaapi` in `config/sunshine.conf`.

## Installation

There is no installer — the repo *is* the installation. Keep it wherever you
like (e.g. `~/projects/sunshine-kde-virtual-display`). The hooks locate their
sibling scripts via `BASH_SOURCE`, so the scripts only have to stay together
in one directory; nothing needs to be on PATH or in `~/.local/bin`.

```bash
# 1. Make the hooks executable
chmod +x scripts/sunshine-connect.sh scripts/sunshine-disconnect.sh

# 2. Install the config (save your existing one first if you have one)
mkdir -p ~/.config/sunshine
cp config/sunshine.conf ~/.config/sunshine/sunshine.conf
```

Then set `global_prep_cmd` in `~/.config/sunshine/sunshine.conf` to absolute
paths into the repo (replace `<repo>` with the repo's absolute path):

```
global_prep_cmd = [{"do":"<repo>/scripts/sunshine-connect.sh","undo":"<repo>/scripts/sunshine-disconnect.sh","elevated":"false"}]
```

Finally enable the Sunshine daemon itself:

```bash
# Arch (packaged user service)
systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
# Fedora / Debian (packaged system service)
sudo systemctl enable --now sunshine.service
```

> **Note:** the do/undo hooks run inside Sunshine's own process environment,
> so Sunshine must run **as the desktop user** for them to reach the KWin
> session. The packaged *user* service (Arch) does this out of the box. The
> packaged *system* service runs Sunshine as a separate `sunshine` user, which
> has no dbus/Wayland session to talk to — on Fedora/Debian, override the unit
> to run Sunshine as your desktop user (or run it via a user unit) before
> using the hooks.

Then open `https://localhost:47990`, set your Sunshine credentials, and pair
your client.

### Optional pieces

- **UFW**: if UFW is active, open Sunshine's ports from your LAN:

  ```bash
  LAN="$(ip route | awk '/proto kernel/ && /src/ {print $1; exit}')"
  sudo ufw allow from "$LAN" to any port 47984:48010 proto tcp
  sudo ufw allow from "$LAN" to any port 47998:48010 proto udp
  sudo ufw allow from "$LAN" to any port 5353 proto udp
  ```

## Scripts

| Script | Role |
|---|---|
| `display-backend.sh` | Virtual-display primitives (`create_virtual_display`, `get_virtual_display_name`, `destroy_virtual_display`), sourced by the hooks |
| `sunshine-connect.sh` | `global_prep_cmd` **do**: create virtual display at client resolution, inhibit sleep, disable physical output (also reconciles state left by a crashed session) |
| `sunshine-disconnect.sh` | `global_prep_cmd` **undo**: re-enable physical output, destroy virtual display, release inhibitor |

## Usage

Connect with Moonlight or Artemis at any resolution you like. The stream canvas
is created at the resolution your client requests. During the session the
physical monitor is off and the host is not usable locally; everything returns
when you disconnect.

```bash
# Start/stop Sunshine with the usual daemon commands
systemctl --user start app-dev.lizardbyte.app.Sunshine.service   # Arch

# Test the display backend in isolation (create / discover / destroy)
source scripts/display-backend.sh
create_virtual_display 1920x1080 SunshineHeadless && get_virtual_display_name && destroy_virtual_display

# Logs
tail -f ~/.local/share/sunshine-headless.log
```

## Status

Verified on KDE Plasma 6 Wayland (NVIDIA / nvenc):

- `krfb-virtualmonitor` creates the virtual output at the client's requested
  resolution; `kscreen-doctor -j` lists it; teardown removes it cleanly.
- Sunshine with `capture = kwin` locates the output **by name** and starts a
  PipeWire screencast at the right resolution:
  ```
  Info: Screencasting with KWin ScreenCast
  Info: [kwingrab] Screencasting output name Virtual-SunshineHeadless resolution 1920x1080
  Info: [pipewire] Streaming display 'Virtual-SunshineHeadless' ... resolution: 1920x1080
  ```
- Physical monitor is disabled on connect; KWin relocates windows and cursor to
  the virtual output without manual intervention.
- Physical monitor is restored on disconnect before the virtual output is
  destroyed, so the host is never left without a display.

Suspend during a session is inhibited by the connect hook; if the host is
suspended anyway, the undo hook and the next connect's reconcile pass restore
output state — no separate resume unit is needed.

## Known gotcha

KWin direct scanout on Plasma 6 crops fullscreen content on the client. The
fix is `KWIN_DRM_NO_DIRECT_SCANOUT=1` in **KWin's own environment** (e.g.
`~/.config/plasma-workspace/env/sunshine.sh`, exported by login on the X11
back-end, or a wrapper around your KWin launch) — it is a compositor setting,
not something Sunshine reads, so it does not belong in Sunshine's unit or
config.

## Alternatives / prior art

This isn't the first take on virtual-display streaming on Linux. The landscape
and where this project fits:

- **[Apollo](https://github.com/ClassicOldSong/Apollo)** — a Sunshine fork with a
  built-in virtual display, automatic client resolution/framerate matching, and
  HDR. Its virtual display is Windows-only (Linux planned).
- **[Hermes / Apollo-Linux](https://github.com/MrOz59/Apollo-Linux)** — a full
  streaming-host fork for Linux / KDE Wayland with virtual-display support via a
  KMS or EVDI backend, and optional physical-monitor shutdown. A more complete
  (and heavier) solution than this.
- **[sunshine-virtual-monitor](https://github.com/Cynary/sunshine-virtual-monitor)**
  — Windows PowerShell scripts that enable a virtual display driver and disable
  the other monitors while streaming.
- **[Nite's KDE Wayland guide](https://www.nite07.com/en/posts/kde-virtual-display-sunshine/)**
  — uses the same core combo this project does (`krfb-virtualmonitor` +
  `capture = kwin`), written up as a manual how-to with a persistent virtual output.

What this project does differently:

- **Runs on stock Sunshine — no server fork.** Apollo and Hermes replace the
  streaming server; this is just scripts on top of upstream Sunshine, and it
  uninstalls cleanly.
- **No kernel module.** `krfb-virtualmonitor` is userspace; EVDI/KMS backends need
  a kernel module recompiled per kernel.
- **Adopts the client's resolution** on KDE Wayland (`SUNSHINE_CLIENT_WIDTH/HEIGHT`),
  which the guide and the Windows scripts don't.
- **Full per-session lifecycle:** the virtual display is created on connect and
  destroyed on disconnect, the physical output is re-enabled first on teardown,
  plus reconnect handling.

Trade-offs to be aware of:

- **One session, shared canvas** — Sunshine runs a single streaming session;
  extra clients stream into it. The canvas is sized by the first client to
  connect, and clients that join later scale to it.
- **No HDR** — `krfb-virtualmonitor` doesn't expose it; EVDI/KMS-based setups
  can.
- **Stability** — `krfb-virtualmonitor` can crash in some headless/remote
  cases; the connect hook retries at 1920x1080 and refuses to blind the
  physical output if the virtual isn't up.

## Roadmap

- **Physical monitor preference GUI:** a small settings UI to let the user
  choose — without editing scripts — whether the physical monitor stays **off
  (headless, current default)** or remains **on and usable** while a client is
  connected. This would parametrize `sunshine-connect.sh` / `sunshine-disconnect.sh`
  via a preference file that the GUI writes.

## License

MIT
