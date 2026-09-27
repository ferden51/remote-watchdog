# Contributing

Thanks for considering a contribution! This project makes a remote PC behave like a self-healing
server: it finds what broke, repairs it in steps, restarts only when justified, and tells you what it did.

- Türkçe okuyorsanız: [CONTRIBUTING.md](CONTRIBUTING.md).

## Before you start

```powershell
# 1) Full suite (expected: Gecti: 117 | Kaldi: 0)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1

# 2) UI suite (WPF, needs STA; expected: Gecti: 17 | Kaldi: 0)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-UI.ps1

# 3) Build the UI, render a PNG and exit
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\ui\RemoteWatchdogPanel.ps1 -SelfTest -PreviewPath "$env:TEMP\panel.png"
```

`Test-All.ps1` reads real system state (`C:\ProgramData\RemoteWatchdog\last-run.json`) and writes
nothing. It also runs in CI on a clean runner, because the workflow prepares that folder first.

## Layout

| Path | Role |
|---|---|
| `host/RemoteHostWatchdog.ps1` | Remote machine (SYSTEM): checks, stepped network repair, services, CRD/RDP, alerts, restart policy |
| `client/RemoteClientWatchdog.ps1` | Your machine: reachability probe, alert, auto-open |
| `ui/RemoteWatchdogPanel.ps1` | WPF tray panel (single file, modular functions) |
| `lib/Common.ps1` | Shared helpers (JSON, TCP probe, day-name conversion) |
| `lib/Contract.ps1` | The single `last-run.json` contract (`schemaVersion` + backward-compatible reader) |
| `lib/Settings.ps1` | Setting definitions (`$script:Defs`) and help balloon texts |
| `install/*.ps1` | Administrator installers |
| `tests/*.ps1` | Regression suites |

## Code rules

1. **Save every `.ps1` as UTF-8 with BOM.** Windows PowerShell 5.1 mangles Turkish characters without
   a BOM. Preserve it in new files.
2. **Do not add comments.** The code should explain itself; a comment is only expected where the
   *reason* is not obvious (PowerShell pitfalls, policy decisions).
3. **One place writes the data contract.** Write `last-run.json` only through `lib/Contract.ps1`
   (`Write-Status`) and read it through `Read-Status`; never hand-roll JSON in the panel or the host.
   Keep the backward-compatible normalisation working.
4. **New setting:** add one row to `$script:Defs` in `lib/Settings.ps1`
   (`@{ Sec='Onarim'; Key='FixXyz'; Title='Text'; Type='bool|int|text|enum|days|lines|csv|datetime' }`).
   The host default goes to `Get-Config`, the panel reader to `Get-HostConfig`, and the "panel coverage"
   test will fail if a key is missing anywhere.
5. **Avoid these PowerShell/WPF traps:**
   - A `GetNewClosure()` created inside a function writes `$script:X` to the temporary scope; capture an
     object/dictionary reference instead (pattern: `$store = $script:EnumSelect`).
   - WPF `Button`: use `add_Click`, never `MouseLeftButtonUp`.
   - Event handlers must reach the window through `$script:Win`, not a local `$w`.
   - `New-Object System.Windows.GridLength('Auto')` fails; use
     `[System.Windows.GridLength]::new([System.Windows.GridUnitType]::Auto)`.
   - `Window.FindName()` only resolves names declared in XAML. Elements built in code need their
     references kept (the live repair window does this with `$script:RepairLiveBox`).
   - Never block the UI thread: long work uses a `DispatcherTimer` and event-driven flow, not
     `Start-Sleep`, otherwise WPF stops painting. Test code that needs timers must pump the dispatcher
     (`Wait-Dispatcher`).
6. **User-visible strings are Turkish**; that is fine. English documentation lives in `README.en.md` /
   `CONTRIBUTING.en.md`.
7. **Tests**: add rows to `tests/Test-All.ps1` as `Ok 'name: description' (<condition>)`. A test must not
   depend on your machine's state without stating the condition.

## Pull request flow

1. Open an issue first (or link one). Out-of-scope changes are worth discussing before you write them.
2. Branch: `git switch -c feat/short-topic`.
3. Run the three commands above and paste the output into the PR description.
4. If behaviour changes, update `README.md` **and** `README.en.md`.
5. PR description must state: what changed, why, which tests ran, and any compatibility impact
   (a `schemaVersion` bump with a backward-compatible reader).

## Adding a check

1. Call `Add-Result 'Name' $ok $detail $repair -Metrics @{...}` in `host/RemoteHostWatchdog.ps1`.
2. Add one line to `Invoke-Watchdog`.
3. If it should be able to trigger a restart, add its name to `$RebootableProblems`.

It then shows up automatically in the JSON, in the panel and in alert texts.

## Adding a button / tray item

`Add-ActionBar` (`& $mk 'Label' 'key'`) plus the `Invoke-SettingsAction` / `Invoke-TrayAction` switch,
and the `$items` array inside `New-TrayIcon`.

## Security

This tool runs as SYSTEM and executes network and service commands. Report vulnerabilities as described
in [SECURITY.md](SECURITY.md) - never in a public issue. Never commit secrets (Telegram token, heartbeat
URL, passwords, usernames); `config.json`, `last-run.json` and `*-state.json` are already ignored.
