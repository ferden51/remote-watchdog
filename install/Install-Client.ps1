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

# Uygulama SABIT bir dizine kopyalanir; gorevler ve kisayollar oradan calisir, boylece
# depo tasinsa/silinse bile kurulum bozulmaz (host kurulumuyla ayni yol).
$AppDir = Join-Path $env:LOCALAPPDATA 'RemoteWatchdog\app'

function Step { param([string]$Text) Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }
function Ok { param([string]$Text) Write-Host ('    [OK] ' + $Text) -ForegroundColor Green }
function Warn { param([string]$Text) Write-Host ('    [!] ' + $Text) -ForegroundColor Yellow }

function Copy-AppToInstallDir {
    # 'tools' de kopyalanir: panel anons onbellegini $Root\tools\VoiceLines.ps1'den
    # yukler (client tarafinda da ayni panel kullanilir).
    $targets = @('client', 'ui', 'lib', 'tools')
    foreach ($t in $targets) {
        $src = Join-Path $Root $t
        if (-not (Test-Path -LiteralPath $src)) { Write-Host ('Klasor yok: ' + $src) -ForegroundColor Red; exit 1 }
    }
    if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Force -Path $AppDir | Out-Null }
    foreach ($t in $targets) {
        & robocopy.exe (Join-Path $Root $t) (Join-Path $AppDir $t) /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Host ('Kopyalama basarisiz (' + $t + '): robocopy kodu ' + $LASTEXITCODE) -ForegroundColor Red; exit 1 }
    }
    Copy-Item -LiteralPath (Join-Path $Root 'VERSION') -Destination (Join-Path $AppDir 'VERSION') -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $ClientScript)) { Write-Host ('Dosya bulunamadi: ' + $ClientScript) -ForegroundColor Red; exit 1 }

$SfxDir = Join-Path $Root 'ui\sounds'
if (Test-Path -LiteralPath $SfxDir) { Ok ('ses paketi bulundu: ' + $SfxDir) }
else { Warn 'ui\sounds klasoru yok: panel film efektleri yerine Windows sistem sesini kullanir (depodan kopyalayin)' }

Write-Host '=============================================='
Write-Host ' RemoteWatchdog - ISTEMCI KURULUMU (bu bilgisayar)'
Write-Host (' Bilgisayar: ' + $env:COMPUTERNAME)
Write-Host '=============================================='

if ($DryRun) {
    Warn 'KURULUM YAPILMAYACAK (DryRun)'
    Step '0) Kurulum dizini'
    Warn ('  kopyalanacak: ' + $Root + '  ->  ' + $AppDir + '  (client\, ui\, lib\, tools\, VERSION)')
    $a = @('-Install', '-IntervalMinutes', $IntervalMinutes)
    if ($Target) { $a += @('-Target', ('"' + $Target + '"')) }
    if ($RdpFile) { $a += @('-RdpFile', ('"' + $RdpFile + '"')) }
    if ($TelegramToken) { $a += @('-TelegramToken', ('"' + $TelegramToken + '"')) }
    if ($TelegramChatId) { $a += @('-TelegramChatId', ('"' + $TelegramChatId + '"')) }
    Step '1) Istemci watchdog'
    Warn ('  calistirilacak: ' + $AppDir + '\client\RemoteClientWatchdog.ps1 ' + ($a -join ' '))
    Step '2) Tray paneli'
    if ($SkipTray) { Warn '  atlandi' } else { Warn ('  calistirilacak: ' + $AppDir + '\ui\RemoteWatchdogPanel.ps1 -Install') }
    exit 0
}

# Panel calisiyorsa betigi kilitliyor; robocopy /MIR onarim modunda eskiyi atlamaz.
$panelProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'RemoteWatchdogPanel' -and $_.ProcessId -ne $PID })
if ($panelProcs.Count -gt 0) {
    Step '0) Calisan panel kapatiliyor (dosya kilidi acilsin)'
    foreach ($pp in $panelProcs) { try { Stop-Process -Id $pp.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    Start-Sleep -Seconds 2
    Ok ('kapatildi: ' + $panelProcs.Count + ' panel surecu')
}

Step '0) Kurulum dizinine kopyalaniyor'
Copy-AppToInstallDir
Ok ('kurulum dizini: ' + $AppDir)
$ClientScript = Join-Path $AppDir 'client\RemoteClientWatchdog.ps1'
$TrayScript = Join-Path $AppDir 'ui\RemoteWatchdogPanel.ps1'

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
    # wscript + Start-Panel.vbs "show": konsol penceresi acmaz ve panel one gelir.
    $pvbs = Join-Path (Split-Path -Parent $TrayScript) 'Start-Panel.vbs'
    if (Test-Path -LiteralPath $pvbs) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $pvbs + '" show')
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $TrayScript + '"')) | Out-Null
    }
    Ok 'tray baslatildi, panel acik'
}

Step 'Ozet'
Ok ('kurulum: ' + $AppDir)
Ok ('config: ' + (Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog\config.json'))
Ok ('log: ' + (Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog\client-watchdog.log'))
Write-Host ''
Write-Host 'Kurulum tamamlandı. Güncellemede Install-Client.ps1 ile tekrar çalıştır.' -ForegroundColor Green
