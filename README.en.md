# remote-watchdog

Run a remote PC **like a server**: a two-part PowerShell watchdog that detects what broke, repairs it in
steps (restarting the machine if that is the only cure) and keeps you informed.

> Türkçe okuyorsanız: [README.md](README.md). Contributions: [CONTRIBUTING.en.md](CONTRIBUTING.en.md).

Most connection problems are "the machine is on but unreachable", and that needs two layers:

1. **On-site (host):** finds the root cause from scratch, repairs it, and pings outward.
2. **Remote (client):** if the link is really down, alerts you and opens the client automatically.

Everything runs on stock Windows with Windows PowerShell 5.1. No modules, no agents, no build step.

## What it does

| Module | Where it runs | Job |
|---|---|---|
| `host/RemoteHostWatchdog.ps1` | Remote PC (as SYSTEM) | Checks CRD/RDP/clock/network/power, repairs the network in steps, configures services, sends heartbeats and Telegram alerts, reboots when justified |
| `host/Protect-OpenDocuments.ps1` | Remote PC (user session) | Autosaves open Word/Excel documents, shortens AutoRecover, saves-and-closes before a reboot |
| `host/Collect-Diagnostics.ps1` | Remote PC | 14 days of event log + network/DHCP/power analysis with a scored suspect list (read-only) |
| `host/Enable-ConsoleAutoLogon.ps1` | Remote PC (admin) | Optional auto console logon after a reboot (stores the password in plain text - see warning) |
| `client/RemoteClientWatchdog.ps1` | Your own PC | TCP reachability test, disconnect alert, automatic RDP/browser launch |
| `ui/RemoteWatchdogPanel.ps1` | Both machines (user session) | System-tray control panel: status, pending work, all settings, forced-shutdown switch, logs, diagnostics |

Plus `lib/` (shared helpers, the data contract, settings definitions), `install/` (admin installers)
and `tests/` (regression suites).

## Install

Copy or clone the whole folder to the target machine, then:

> **Security: verify hashes before running anything.** The install scripts check every
> file's SHA256 themselves and abort if anything fails. You can also run it manually:
> `.\tools\Verify-Hashes.ps1` → expect `DOGRULAMA BASARILI` (use `-SkipHash` only when
> installing from a copy you already trust). The Telegram bot token is stored DPAPI-
> encrypted in `config.json` and is never passed on the command line.

### Remote PC (host, needs Administrator)

```powershell
.\tools\Verify-Hashes.ps1
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'
```

It produces a read-only diagnostics report first, installs the watchdog and document-saver tasks,
registers the tray panel at logon, and finally tells you to re-register Google Chrome Remote Desktop at
`https://remotedesktop.google.com/headless` (the one step a script cannot do). It re-launches itself as
administrator when needed. Useful switches: `-DryRun`, `-KeepSleep` (laptop profile), `-SkipTray`.

### Your own PC (client, no admin needed)

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Install-Client.ps1 -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\office.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
```

`Target` must be an address reachable *from that machine* (a Tailscale IP, for example - a public IP
without port forwarding is not reachable). Without `Target`, only the Google/CRD signal path is tested.

### Panel

```powershell
.\ui\RemoteWatchdogPanel.ps1                 # starts in the tray (double-click the icon = panel)
.\ui\RemoteWatchdogPanel.ps1 -Install        # start automatically at logon
.\ui\RemoteWatchdogPanel.ps1 -SelfTest       # build the UI, produce a PNG, exit (for testing)
```

The tray icon is colour-coded: green (healthy), red (problem), grey (no data). Four tabs: **Status**,
**Pending work**, **Settings**, **Log**. The header shows the next automatic check as a live countdown
(`Automatic: 03:24 (204 s)`) and a **"Repair network / internet"** button.

## Repairing the network from the panel

The button first tests network health (IP, DNS, HTTPS, Google signal). If everything is fine, no rung is
applied at all. If not, it walks the rungs in order:

1. flush DNS cache + restart Dnscache
2. renew the DHCP lease
3. reconnect Wi-Fi / bounce the network adapter
4. restart Dhcp + NlaSvc and the adapter driver
5. winsock + IPv4 reset (needs a reboot to take effect)

A separate **"Repair network / internet" window** opens and streams the log lines **live** while the
repair runs:

```
[WARN] elle ag onarimi basladi: panel istedi (username) (saatlim: False)
[INFO] kademe 1/4 basliyor: DNS onbellegi temizleme + Dnscache servisi yeniden baslatma
[INFO] kademe 1 uygulandi: DNS onbellegi temizlendi; Dnscache servisi yeniden baslatildi
[INFO] ag onarimi bitti: basarili=True, kademe=1, sure=9 sn
```

The repair runs as SYSTEM, so a normal user in the panel still gets it **without a UAC prompt**: the
panel writes `C:\ProgramData\RemoteWatchdog\repair-request.json` and one of two tasks picks it up.

| Task | Trigger | Role |
|---|---|---|
| `RemoteHostRepair` | on demand only (no trigger) | Starts immediately; used when the panel itself runs elevated |
| `RemoteHostRepairWatch` | every 60 s | Applies the request if present, exits in ~1 s if not. This is the main path, because a normal user cannot start a SYSTEM task by name |

Both are installed by `RemoteHostWatchdog.ps1 -Install` (removed by `-Uninstall`). The main check task
uses `MultipleInstances=IgnoreNew`, so it cannot be started while a run is in progress - that is exactly
why repair has its own tasks. `last-run.json` exposes `repairWatch: 1` when the 60 s watcher exists.

## Restart policy

| Time | Behaviour |
|---|---|
| Outside blackout (daytime) | **No restart.** On-screen and Telegram notifications only; the decision stays with you. |
| Blackout window (default 18:00 → 08:00) | Word/Excel/PPT are force-closed and the machine restarts (unsaved work may be lost; it is logged and reported to Telegram). |
| Saturday/Sunday (`BlackoutFullDays`) | Force-close + restart. |
| `RestartPolicy: always` / `never` | Ignore the blackout window / never restart. |
| `ForceRestartAlways: true` | Force-close + restart at any hour. |

Circuit breaker: `MaxRestartsPerDay` (3) and `RebootCooldownMinutes` (60). The machine is **not**
restarted when `host.json` is missing (a reboot would not help), and not before `MinUptimeMinutes`
after boot. Open documents can veto a reboot entirely (`OfficeAbortRebootIfUnsaved`).

## Network loss protection

`host/Protect-OpenDocuments.ps1` runs every 2 minutes as `RemoteHostOfficeSaver`:

- Word `Options.SaveInterval` and Excel `AutoRecoverInterval` are shortened to 3 minutes.
- Every unsaved Word/Excel document **with a file path** is saved to disk. New/untitled (would need
  *Save As*), read-only and shared documents are reported instead of saved, so the bot cannot lock the
  machine with a dialog.
- State is written to `C:\Windows\Temp\RemoteWatchdog-docs.json`; the watchdog reads it **before**
  rebooting and skips the reboot if anything is unsaved.

Check it manually: `.\Protect-OpenDocuments.ps1 -Status`.

## Signals that the machine is still alive

- **Telegram** - one message on state change, repeated every `AlertRepeatHours` while a problem lasts.
  The token lives in `config.json` (plain text); the installer locks the folder ACL down.
- **healthchecks.io** - pass `-HeartbeatUrl https://hc-ping.com/<uuid>` and you get e-mail/call when the
  ping stops. On failure, hit `<uuid>/fail`. Use `Period: 5m`, `Grace: 10m` (dead-man's switch).
- **GitHub Actions** - `.github/workflows/machine-health.yml` pings from the outside every 30 minutes
  and alerts via Telegram when the machine does not answer. This is the only layer that catches
  "machine off / no internet", which no local watchdog can see. Set the repository secrets
  `HEALTHCHECK_URL`, `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`.

## Audible alerts (voice + film effects)

Every important event is announced in **two layers**: a ready-made effect first, then a short Turkish
sentence (voice). The voice engine is tried in this order:

1. **edge-tts → natural FEMALE Turkish voice (`tr-TR-EmelNeural`)** — Microsoft's official neural
   voice, free, the most natural pronunciation. Install: `python -m pip install --user edge-tts`.
   *Requires internet.* The panel calls it through the `tools\edge_tts_win.py` wrapper (edge-tts 7.x
   uses aiodns, which on Windows requires `WindowsSelectorEventLoopPolicy`; without the wrapper the
   process dies before producing any audio).
2. **Piper TTS (local fallback)** — natural but **male**; works offline.
   Install: `.\tools\Install-Voice.ps1` → `%LOCALAPPDATA%\RemoteWatchdog\voice`
3. **Windows Turkish SAPI voice** — used when a Turkish text-to-speech pack is installed (Tolga/Emel).
4. If none exists the panel stays **silent** — it never reads Turkish text with an English voice.

Settings → Notification → `SesliBildirim` (on/off) and `SesliBildirimEdge` (cloud voice on/off; if
off it goes straight to local Piper); tray *Silent mode* mutes it. The panel logs the engine it
picked at startup. Check with `.\tools\Install-Voice.ps1 -Status`.

The effects are shipped ready-made as `ui/sounds/*.wav` and are designed to sound like a sci-fi console:
**clear** (attack under 2 ms), **sharp** (4 ms bright transient), **bright** (inharmonic metallic
partials plus a short shimmer reverb) and **realistic** (sub layer, soft limiter, no clipping). The
panel preloads them on first use, so there is no delay between the event and the sound; if a file or
the audio device is missing it falls back to the Windows system sounds.

| Effect | When | Character |
|---|---|---|
| `alert` | connection lost / critical alarm | 3-pulse klaxon, metallic edge, sub thump |
| `warn` | warning: partial/failed repair, problem found by a manual check | two-note tense chime |
| `ok` | confirmation: repair done, check clean | single bright glass ping |
| `recover` | connection recovered | rising shimmer + double bright chime |
| `repair` | repair in progress | sonar scan (repeated rising ping) |
| `reboot` | reboot requested/detected | falling sweep + sub, sharp top blip |
| `online` | system online (install/startup) | two-note glass bell + long tail |
| `scan` | manual check started | two micro blips |

Settings → Notification has **two independent switches**: `SesEfektleri` (the ready-made **wav**
effects) and `SesliBildirim` (the **human voice**, Turkish announcement). Both are one click away in
the tray menu — *Sesli anons (insan sesi)* and *Film efektleri (wav)* (their labels show the current
state) — and *Ses testi* checks both at once. Tray *Silent mode* mutes both. Effect volume:
`SesEfektleriVolume` (0-100, 0 = effects off). Regenerate or verify the pack with
`.\tools\New-SoundPack.ps1` (`-List`, `-Verify`); the sound design lives in `tools/SfxSynth.cs`.

> **Pronunciation note:** announcement texts are written **with Turkish characters** (`Bağlantı
> düzeldi.`, `Ağ onarılıyor.`). ASCII spellings (`Baglanti duzeldi`) are read with English letter
> sounds and break the Turkish pronunciation. Check names arrive ASCII from `last-run.json`, so
> `ConvertTo-TtsText` maps them through a small dictionary (`Internet erisimi` → `İnternet erişimi`);
> a general ASCII→diacritic conversion is deliberately **not** done (it would produce `ınternet`).
> A trailing full stop is added to short sentences for prosody.

## What a human must do (no script can)

- **BIOS**: *Restore on AC Power Loss = Power On* and *Wake on LAN = Enabled*. If the machine does not
  power on by itself after a power cut, software is irrelevant.
- **Re-register Google CRD**: if `host.json` is gone the device disappears from the list. Visit
  `https://remotedesktop.google.com/headless` → *Set up remote access* → get a PIN, then add the
  machine under *Machines → +* on your side.
- **RDP over the internet** needs port forwarding or a VPN (Tailscale is the easy option); opening the
  Windows firewall rule alone does not expose anything.
- **Windows Update**: set *active hours* / *maintenance window* so it does not restart mid-workday.
- **Auto logon** (optional): `host/Enable-ConsoleAutoLogon.ps1` logs in automatically after a reboot and
  stores the password in plain text. Use it only on networks you consider safe.

## Data contract

`last-run.json` is written **only** through `lib/Contract.ps1` (`Write-Status`, stamped with
`schemaVersion`) and read **only** through `Read-Status`. The reader normalises older or unversioned
files, so an old panel can read a new file and a new panel can read an old one. Keep it that way: it is
what lets the panel and the watchdog be updated independently on two different machines.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1        # 123 checks, read-only
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-UI.ps1    # 27 checks, WPF
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\ui\RemoteWatchdogPanel.ps1 -SelfTest -PreviewPath out.png
```

`Test-All.ps1` reads real system state (`C:\ProgramData\RemoteWatchdog\last-run.json`) but never changes
anything. Both suites run automatically on every push and pull request (`.github/workflows/tests.yml`).

## License

MIT - see [LICENSE](LICENSE). Contributions are welcome: read [CONTRIBUTING.en.md](CONTRIBUTING.en.md)
first (code rules, PowerShell/WPF pitfalls, PR flow). Security reports: [SECURITY.md](SECURITY.md) -
please do not open a public issue.
