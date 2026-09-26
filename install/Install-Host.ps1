#Requires -Version 5.1
<#
    Install-Host - UZAK BILGISAYAR kurulumu (fiziksel erisim gerekir)

    Sirasiyla yapar:
      1) Tehis raporu uretir (okuma modunda, degisiklik yapmaz) - "kopma nedeni" icin
      2) Host watchdog zamanlanmis gorevini kurar (admin, 5 dk'da bir, otomatik onarim + alarm)
      3) Belge koruyucu gorevini kurar (Word/Excel kaydetme-koruma)
      4) Tray kontrol panelini oturum acilinda baslatir
      5) Kontrol eder ve ne yapilacagini yazar

    Kullanim:
      .\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'
      .\Install-Host.ps1 -KeepSleep -DryRun
#>
[CmdletBinding()]
param(
    [string]$TelegramToken = '',
    [string]$TelegramChatId = '',
    [int]$IntervalMinutes = 5,
    [switch]$KeepSleep,
    [switch]$SkipDiag,
    [switch]$SkipTray,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$InstallDir = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $InstallDir
$HostScript = Join-Path $Root 'host\RemoteHostWatchdog.ps1'
$DiagScript = Join-Path $Root 'host\Collect-Diagnostics.ps1'
$DocsScript = Join-Path $Root 'host\Protect-OpenDocuments.ps1'
$TrayScript = Join-Path $Root 'ui\RemoteWatchdogPanel.ps1'

function Step { param([string]$Text) Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }
function Ok { param([string]$Text) Write-Host ('    [OK] ' + $Text) -ForegroundColor Green }
function Warn { param([string]$Text) Write-Host ('    [!] ' + $Text) -ForegroundColor Yellow }
function Die { param([string]$Text) Write-Host ('    [X] ' + $Text) -ForegroundColor Red; exit 1 }

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host '=============================================='
Write-Host ' RemoteWatchdog - UZAK BILGISAYAR KURULUMU'
Write-Host (' Bilgisayar: ' + $env:COMPUTERNAME + ' | Kullanici: ' + $env:USERNAME)
Write-Host '=============================================='

foreach ($f in @($HostScript, $DiagScript, $DocsScript)) {
    if (-not (Test-Path -LiteralPath $f)) { Die ('Dosya bulunamadi: ' + $f + ' (tum klasoru kopyaladin mi?)') }
}

if (-not (Is-Admin)) { Warn 'Yonetici degilsin. Zamanlanmis gorev ve servis ayarlari icin gerekli; script kendini yonetici olarak yeniden baslatacak.' }

if ($DryRun) {
    Warn 'KURULUM YAPILMAYACAK (DryRun)'
    Step '1) Tehis raporu'
    Warn ('  calistirilacak: ' + $DiagScript + '  (okuma modunda)')
    Step '2) Host watchdog'
    Warn ('  calistirilacak: ' + $HostScript + ' -Install -IntervalMinutes ' + $IntervalMinutes)
    if ($TelegramToken) { Warn '  -TelegramToken verilecek' } else { Warn '  Telegram token YOK: alarm ekranda gorunur, Telegram gelmez' }
    if ($KeepSleep) { Warn '  -KeepSleep: uyku ve Fast Startup ayarlarina dokunulmayacak' }
    Step '3) Belge koruyucu'
    Warn ('  goru: ' + $DocsScript + ' (zamanlanmis gorev host -Install icinde kurulur)')
    Step '4) Tray paneli'
    if ($SkipTray) { Warn '  atlandi (-SkipTray)' } else { Warn ('  calistirilacak: ' + $TrayScript + ' -Install') }
    Step '5) CRD kaydi'
    Warn 'https://remotedesktop.google.com/headless adresini ac, "Set up remote access" ile yeni PIN al.'
    Warn 'Bu adim watchdog ile yapilamaz; cihaz Google listesinde gorunmuyorsa bu zorunludur.'
    exit 0
}

if (-not (Is-Admin)) {
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-IntervalMinutes', $IntervalMinutes)
    if ($TelegramToken) { $forward += @('-TelegramToken', ('"' + $TelegramToken + '"')) }
    if ($TelegramChatId) { $forward += @('-TelegramChatId', ('"' + $TelegramChatId + '"')) }
    if ($KeepSleep) { $forward += '-KeepSleep' }
    if ($SkipDiag) { $forward += '-SkipDiag' }
    if ($SkipTray) { $forward += '-SkipTray' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $forward
    Ok 'Yonetici yetkisiyle yeniden baslatildi. Bu pencereyi kapatabilirsiniz.'
    exit 0
}

if (-not $SkipDiag) {
    Step '1) Tehis raporu (okuma modunda, ~40 sn)'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $DiagScript | Out-Null
    $report = @(Get-ChildItem (Join-Path $env:USERPROFILE 'Desktop') -Filter 'rd-diagnostics-*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($report) { Ok ('rapor: ' + $report[0].FullName) } else { Warn 'rapor bulunamadi' }
    Warn 'Bu raporu saklayin; kac gun sonra "acik kalinca internet gitti" sikayeti tekrar ederse teşhis icin gerekli.'
}

Step '2) Host watchdog kurulumu'
$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $HostScript + '"'), '-Install', '-IntervalMinutes', $IntervalMinutes)
if ($TelegramToken) { $args += @('-TelegramToken', ('"' + $TelegramToken + '"')) }
if ($TelegramChatId) { $args += @('-TelegramChatId', ('"' + $TelegramChatId + '"')) }
if ($KeepSleep) { $args += '-KeepSleep' }
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -eq 0) { Ok 'zamanlanmis gorev kuruldu (acilista + oturum acilista + her ' + $IntervalMinutes + ' dk)' } else { Warn ('kurulum donus kodu: ' + $p.ExitCode) }

$cfgPath = 'C:\ProgramData\RemoteWatchdog'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        icacls $cfgPath /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F" "$env:USERNAME:(OI)(CI)M" /T /C 2>&1 | Out-Null
        Ok 'config klasoru izinleri kisitlandi (SYSTEM + Administrators + kullanimici)'
    } catch { Warn ('izin kisitlamasi yapilamadi (Telegram token gibi degerler duz metin kalir): ' + $_.Exception.Message) }
}
Start-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
$task = Get-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue
if ($task) { Ok ('gorev durumu: ' + $task.State) } else { Die 'gorev olusmadi' }
if (Get-ScheduledTask -TaskName 'RemoteHostOfficeSaver' -ErrorAction SilentlyContinue) { Ok 'belge koruyucu gorevi kuruldu' } else { Warn 'belge koruyucu gorevi kurulmadi (belge kaydetme korumasi kapali)' }
if (Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue) { Warn 'CRD: cihaz yeniden kaydedilmemis gorunuyor -> asagidaki 5. adim zorunlu' }

Step '3) Belge koruyucu kontrolu'
& powershell -NoProfile -ExecutionPolicy Bypass -File $DocsScript -Status | Out-String | Write-Host

Step '4) Tray kontrol paneli'
if ($SkipTray) { Warn 'atlandi (-SkipTray)' }
else {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $TrayScript -Install | Out-Null
    if (Get-ItemProperty -Path $runKey -Name 'RemoteWatchdogTray' -ErrorAction SilentlyContinue) { Ok 'tray oturum acilinda baslayacak' } else { Warn 'tray kaydi olusmadi (farkli yonetici hesabi ile calistirilmis olabilir)' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $TrayScript + '"')) | Out-Null
    Ok 'tray baslatildi (simge: sistem tepsisi)'
}

Step '5) Google Remote Desktop kaydi (ZORUNLU)'
Write-Host '    1) Bu makinede Chrome ac:  https://remotedesktop.google.com/headless'
Write-Host '    2) "Set up remote access" / "Uzaktan erisimi ayarla" -> bir ad ve PIN verir'
Write-Host '    3) Kendi cihazinda https://remotedesktop.google.com -> Machines altindaki "+" -> ad + PIN'
Write-Host '    4) Listede gorundugunde "baglanti calisiyor" degilse paneldeki CRD kontrolune bak'
Warn 'Bu adim watchdog ile yapilamaz; cihazin host kaydi (host.json) yoksa listede gorunmez.'

Step '6) Ozet'
$cfg = 'C:\ProgramData\RemoteWatchdog\config.json'
if (Test-Path -LiteralPath $cfg) { Ok ('config: ' + $cfg) }
Ok ('log: C:\ProgramData\RemoteWatchdog\host-watchdog.log')
Ok 'durum: tray paneli veya  powershell -File "' + $HostScript + '" -Status'
if (-not $TelegramToken) { Warn 'Telegram bildirimi kapali; ekranda uyari gorunur. Eklemek icin: Install-Host.ps1 -TelegramToken ... -TelegramChatId ...' }
Write-Host ''
Write-Host 'Kurulum tamamlandi.' -ForegroundColor Green
