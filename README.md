# remote-watchdog

English / Türkçe (bilingual)

This repository contains a self-healing Windows watchdog for a remote PC: detects what broke, repairs the network in steps, reboots only when justified, and notifies you (Telegram / healthchecks). Everything is implemented in PowerShell 5.1 with no external dependencies.

Bu depo, uzaktaki bilgisayarı kendini onaran bir Windows watchdog olarak çalıştırır: neyin bozulduğunu tespit eder, ağı kademeli olarak onarır, yalnızca gerekliyse yeniden başlatır ve sizi bilgilendirir (Telegram / healthchecks). Her şey PowerShell 5.1 ile, bağımlılık olmadan yazılmıştır.

---

English

Run a remote PC like a server: a two-part PowerShell watchdog that detects what broke, repairs it in steps (restarting the machine if that is the only cure) and keeps you informed.

Most connection problems are "the machine is on but unreachable", and that needs two layers:

1. On-site (host): finds the root cause from scratch, repairs it, and pings outward.
2. Remote (client): if the link is really down, alerts you and opens the client automatically.

Everything runs on stock Windows with Windows PowerShell 5.1. No modules, no agents, no build step.

What it does

| Module | Where it runs | Job |
|---|---|---|
| `host/RemoteHostWatchdog.ps1` | Remote PC (as SYSTEM) | Checks CRD/RDP/clock/network/power, repairs the network in steps, configures services, sends heartbeats and Telegram alerts, reboots when required |
| `host/Protect-OpenDocuments.ps1` | Remote PC (user session) | Autosaves open Word/Excel documents, shortens AutoRecover, saves-and-closes before a reboot |
| `host/Collect-Diagnostics.ps1` | Remote PC | 14 days of event log + network/DHCP/power analysis with a scored suspect list (read-only) |
| `host/Enable-ConsoleAutoLogon.ps1` | Remote PC (admin) | Optional auto console logon after a reboot (stores the password in plain text - see warning) |
| `client/RemoteClientWatchdog.ps1` | Your own PC | TCP reachability test, disconnect alert, automatic RDP/browser launch |
| `ui/RemoteWatchdogPanel.ps1` | Both machines (user session) | System-tray control panel: status, pending work, all settings, forced-shutdown switch, logs, diagnostics |

Plus `lib/` (shared helpers, the data contract, settings definitions), `install/` (admin installers) and `tests/` (regression suites).

Install

Copy or clone the whole folder to the target machine, then:

Security: verify hashes before running anything. The install scripts check every file's SHA256 themselves and abort if anything fails. You can also run it manually:

```
.\tools\Verify-Hashes.ps1
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'
```

Remote PC (host, needs Administrator)

It produces a read-only diagnostics report first, installs the watchdog and document-saver tasks, registers the tray panel at logon, and finally tells you to re-register Google Chrome Remote Desktop at `https://remotedesktop.google.com/headless` (the one step a script cannot do). It re-launches itself as administrator when needed. Useful switches: `-DryRun`, `-KeepSleep` (laptop profile), `-SkipTray`.

Your own PC (client, no admin needed)

```
powershell -ExecutionPolicy Bypass -File .\install\Install-Client.ps1 -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\office.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
```

`Target` must be an address reachable from that machine (a Tailscale IP, for example - a public IP without port forwarding is not reachable). Without `Target`, only the Google/CRD signal path is tested.

Panel

```
.\ui\RemoteWatchdogPanel.ps1                 # starts in the tray (double-click the icon = panel)
.\ui\RemoteWatchdogPanel.ps1 -Install        # start automatically at logon
.\ui\RemoteWatchdogPanel.ps1 -SelfTest       # build the UI, produce a PNG, exit (for testing)
```

The tray icon is colour-coded: green (healthy), red (problem), grey (no data). Four tabs: Status, Pending work, Settings, Log. The header shows the next automatic check as a live countdown and a "Repair network / internet" button.

Repairing the network from the panel

The button first tests network health (IP, DNS, HTTPS, Google signal). If everything is fine, no rung is applied at all. If not, it walks the rungs in order:

1. flush DNS cache + restart Dnscache
2. renew the DHCP lease
3. reconnect Wi-Fi / bounce the network adapter
4. restart Dhcp + NlaSvc and the adapter driver
5. winsock + IPv4 reset (needs a reboot to take effect)

A separate "Repair network / internet" window opens and streams the log lines live while the repair runs. The repair runs as SYSTEM, so a normal user in the panel still gets it without a UAC prompt: the panel writes `C:\ProgramData\RemoteWatchdog\repair-request.json` and one of two tasks picks it up.

Restart policy

Behaviour depends on blackout settings; by default restarts happen during blackout hours and are avoided during daytime. See the full project docs for details.

Signals that the machine is still alive

- Telegram - one message on state change, repeated every AlertRepeatHours while a problem lasts.
- healthchecks.io - pass `-HeartbeatUrl https://hc-ping.com/<uuid>` and you get e-mail/call when the ping stops.
- GitHub Actions - `.github/workflows/machine-health.yml` pings from the outside and alerts via Telegram when the machine does not answer.

Audible alerts (voice + film effects)

Every important event is announced in two layers: a ready-made effect first, then a short Turkish sentence (voice). The voice engine is tried in this order: edge-tts (cloud), Piper TTS (local), Windows SAPI voice.

What a human must do (no script can)

- BIOS: Restore on AC Power Loss = Power On and Wake on LAN = Enabled.
- Re-register Google CRD if host.json is gone.
- RDP over the internet needs port forwarding or VPN.

Data contract

`last-run.json` is written only through `lib/Contract.ps1` and read only through `Read-Status`. The reader normalises older or unversioned files so old and new versions stay compatible.

Tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-UI.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\ui\RemoteWatchdogPanel.ps1 -SelfTest -PreviewPath out.png
```

---

Türkçe

Uzaktaki bilgisayarı server gibi çalıştıran, bağlantı koparsa kendini onaran (gerekirse yeniden başlatan) iki parçalı PowerShell watchdog projesidir.

Bağlantı sorunlarının çoğu "makine açık ama erişilemiyor" şeklindedir ve iki ayrı katmanda çözülür:

1. Yerinde (host): bağlantıyı bozan şeyi sıfırdan tespit edip onarır ve dışarıya "nabız" gönderir.
2. Uzaktan (istemci): bağlantı gerçekten düşmüşse uyarır ve istemciyi otomatik açar.

Her şey stok Windows ve Windows PowerShell 5.1 üzerinde çalışır. Modul yok, ajanın kurulması yok, derleme adımı yok.

Klasör yapısı

| Dosya | Nerede çalışır | Görev |
|---|---|---|
| `host/RemoteHostWatchdog.ps1` | Uzak bilgisayar (SYSTEM) | CRD/RDP/uyku/saat/ağ testi, kademeli ağ onarımı, otomatik servis ayarları, heartbeat, Telegram uyarısı, gerekirse reboot |
| `host/Protect-OpenDocuments.ps1` | Uzak bilgisayar (kullanıcı oturumu) | Kaydedilmemiş Word/Excel belgelerini periyodik kaydeder, AutoRecover'ı kısaltır, reboot öncesi kaydedip kapatır |
| `host/Collect-Diagnostics.ps1` | Uzak bilgisayar | 14 günlük olay günlüğü + ağ/DHCP/uyku analizi, puanlı şüpheli listesi (hiçbir şeyi değiştirmez) |
| `host/Enable-ConsoleAutoLogon.ps1` | Uzak bilgisayar (admin) | Reboot sonrası konsola otomatik giriş (opt-in, riskli) |
| `client/RemoteClientWatchdog.ps1` | Kendi bilgisayarın | Uzak hedefe TCP erişim testi, kopma uyarısı, RDP/tarayıcı otomatik açma |
| `ui/RemoteWatchdogPanel.ps1` | Her iki makinede (kullanıcı oturumu) | Sistem tepsisi kontrol paneli: durum, bekleyen işler, tüm ayarlar, daima zorla kapatma anahtarı, loglar, teşhis raporu |

Kurulum

Klasörün tamamını hedef makineye kopyala (veya `git clone`), sonra kurulum betiklerini çalıştır. Güvenlik için SHA256 doğrulaması yapmayı unutmayın (`.\tools\Verify-Hashes.ps1`). Host için `Install-Host.ps1`, client için `Install-Client.ps1` kullanılır.

Daha fazla ayrıntı için README.en.md ve orijinal README.md dosyalarındaki tam açıklamalara bakabilirsiniz.
