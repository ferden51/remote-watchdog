#Requires -Version 5.1
<#
    Install-Client - KENDI BİLGİSAYARIN kurulumu (admin gerektirmez)

    Yapar:
      1) Istemci watchdog zamanlanmis gorevini kurar (uzak makineye TCP erisim testi + kopma alarmi)
      2) Tray kontrol panelini oturum acilinda baslatir

    Kullanim:
      .\Install-Client.ps1 -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\finrex.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
      .\Install-Client.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$RdpFile = '',
    [string]$BrowserUrl = 'https://remotedesktop.google.com',
    [string]$TelegramToken = '',
    [string]$TelegramChatId = '',
    [string]$HeartbeatUrl = '',
    [int]$IntervalMinutes = 10,
    [switch]$SkipTray,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$InstallDir = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $InstallDir
$ClientScript = Join-Path $Root 'client\RemoteClientWatchdog.ps1'
$TrayScript = Join-Path $Root 'ui\RemoteWatchdogPanel.ps1'

function Step { param([string]$Text) Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }
function Ok { param([string]$Text) Write-Host ('    [OK] ' + $Text) -ForegroundColor Green }
function Warn { param([string]$Text) Write-Host ('    [!] ' + $Text) -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $ClientScript)) { Write-Host ('Dosya bulunamadi: ' + $ClientScript) -ForegroundColor Red; exit 1 }

Write-Host '=============================================='
Write-Host ' RemoteWatchdog - ISTEMCI KURULUMU (bu bilgisayar)'
Write-Host (' Bilgisayar: ' + $env:COMPUTERNAME)
Write-Host '=============================================='

if ($DryRun) {
    Warn 'KURULUM YAPILMAYACAK (DryRun)'
    $a = @('-Install', '-IntervalMinutes', $IntervalMinutes)
    if ($Target) { $a += @('-Target', ('"' + $Target + '"')) }
    if ($RdpFile) { $a += @('-RdpFile', ('"' + $RdpFile + '"')) }
    if ($TelegramToken) { $a += @('-TelegramToken', ('"' + $TelegramToken + '"')) }
    if ($TelegramChatId) { $a += @('-TelegramChatId', ('"' + $TelegramChatId + '"')) }
    Step '1) Istemci watchdog'
    Warn ('  calistirilacak: ' + $ClientScript + ' ' + ($a -join ' '))
    Step '2) Tray paneli'
    if ($SkipTray) { Warn '  atlandi' } else { Warn ('  calistirilacak: ' + $TrayScript + ' -Install') }
    exit 0
}

Step '1) Istemci watchdog kurulumu'
$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ClientScript + '"'), '-Install', '-IntervalMinutes', $IntervalMinutes)
if ($Target) { $a += @('-Target', ('"' + $Target + '"')) }
if ($RdpFile) { $a += @('-RdpFile', ('"' + $RdpFile + '"')) }
if ($BrowserUrl) { $a += @('-BrowserUrl', ('"' + $BrowserUrl + '"')) }
if ($TelegramToken) { $a += @('-TelegramToken', ('"' + $TelegramToken + '"')) }
if ($TelegramChatId) { $a += @('-TelegramChatId', ('"' + $TelegramChatId + '"')) }
if ($HeartbeatUrl) { $a += @('-HeartbeatUrl', ('"' + $HeartbeatUrl + '"')) }
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -eq 0) { Ok ('zamanlanmış görev kuruldu (her ' + $IntervalMinutes + ' dk)') } else { Warn ('kurulum donus kodu: ' + $p.ExitCode) }
Start-ScheduledTask -TaskName 'RemoteClientWatchdog' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$task = Get-ScheduledTask -TaskName 'RemoteClientWatchdog' -ErrorAction SilentlyContinue
if ($task) { Ok ('görev durumu: ' + $task.State) } else { Warn 'gorev olusmadi' }
if ($Target) { Ok ('hedef: ' + $Target + ' (bu adresin TCP erisimi test edilecek)') } else { Warn 'hedef tanimli degil: sadece Google/CRD sinyal yolu test edilir' }

Step '2) Tray kontrol paneli'
if ($SkipTray) { Warn 'atlandi (-SkipTray)' }
else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $TrayScript -Install | Out-Null
    if (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'RemoteWatchdogTray' -ErrorAction SilentlyContinue) { Ok 'panel oturum açılışında başlayacak' } else { Warn 'tray kaydi olusmadi' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $TrayScript + '"')) | Out-Null
    Ok 'tray baslatildi, panel acik'
}

Step 'Ozet'
Ok ('config: ' + (Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog\config.json'))
Ok ('log: ' + (Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog\client-watchdog.log'))
Write-Host ''
Write-Host 'Kurulum tamamlandı.' -ForegroundColor Green
