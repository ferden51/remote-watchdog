#Requires -Version 5.1
<#
    Install-Host - UZAK BİLGİSAYAR kurulumu (fiziksel erisim gerekir)

    Sirasiyla yapar:
      1) Teşhis raporu üretir (okuma modunda, degisiklik yapmaz) - "kopma nedeni" icin
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

# Uygulama SABIT bir dizine kopyalanir ve her sey oradan calisir. Boylece depo
# tasinsa/silinse bile zamanlanmis gorevler ve kisayollar bozulmaz; ayrica
# "kod calisiyor" diye repodan calistirmak zorunda kalmazsin.
$AppDir = Join-Path $env:ProgramData 'RemoteWatchdog\app'

function Step { param([string]$Text) Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }
function Ok { param([string]$Text) Write-Host ('    [OK] ' + $Text) -ForegroundColor Green }
function Warn { param([string]$Text) Write-Host ('    [!] ' + $Text) -ForegroundColor Yellow }
function Die { param([string]$Text) Write-Host ('    [X] ' + $Text) -ForegroundColor Red; exit 1 }

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Copy-AppToInstallDir {
    <#
        host\, ui\, lib\, VERSION klasorlerini ProgramData'ya kopyalar ve oradaki
        betik yollarini dondurur. Panel aciliyken bir dosya kilitliyse robocopy
        onarim modu (/M) eskiyi atlamaz; bu yuzden once paneli kapatmayi dener.
    #>
    $targets = @('host', 'ui', 'lib')
    foreach ($t in $targets) {
        $src = Join-Path $Root $t
        if (-not (Test-Path -LiteralPath $src)) { Die ('kopyalanacak klasor yok: ' + $src) }
    }
    if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Force -Path $AppDir | Out-Null }
    foreach ($t in $targets) {
        $dst = Join-Path $AppDir $t
        & robocopy.exe (Join-Path $Root $t) $dst /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { Die ('kopyalama basarisiz (' + $t + '): robocopy kodu ' + $LASTEXITCODE) }
    }
    Copy-Item -LiteralPath (Join-Path $Root 'VERSION') -Destination (Join-Path $AppDir 'VERSION') -Force -ErrorAction SilentlyContinue
    $v = '0.0.0'
    try { $v = ([System.IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim() } catch { }
    return [pscustomobject]@{
        Dir   = $AppDir
        Host  = Join-Path $AppDir 'host\RemoteHostWatchdog.ps1'
        Diag  = Join-Path $AppDir 'host\Collect-Diagnostics.ps1'
        Docs  = Join-Path $AppDir 'host\Protect-OpenDocuments.ps1'
        Panel = Join-Path $AppDir 'ui\RemoteWatchdogPanel.ps1'
        Ver   = $v
    }
}

Write-Host '=============================================='
Write-Host ' RemoteWatchdog - UZAK BİLGİSAYAR KURULUMU'
Write-Host (' Bilgisayar: ' + $env:COMPUTERNAME + ' | Kullanici: ' + $env:USERNAME)
Write-Host '=============================================='

foreach ($f in @($HostScript, $DiagScript, $DocsScript)) {
    if (-not (Test-Path -LiteralPath $f)) { Die ('Dosya bulunamadi: ' + $f + ' (tum klasoru kopyaladin mi?)') }
}

$SfxDir = Join-Path $Root 'ui\sounds'
if (Test-Path -LiteralPath $SfxDir) { Ok ('ses paketi bulundu: ' + $SfxDir) }
else { Warn 'ui\sounds klasoru yok: panel film efektleri yerine Windows sistem sesini kullanir (depodan kopyalayin)' }

if (-not (Is-Admin)) { Warn 'Yonetici degilsin. Zamanlanmis gorev ve servis ayarlari icin gerekli; script kendini yonetici olarak yeniden baslatacak.' }

if ($DryRun) {
    Warn 'KURULUM YAPILMAYACAK (DryRun)'
    Step '0) Kurulum dizini'
    Warn ('  kopyalanacak: ' + $Root + '  ->  ' + $AppDir + '  (host\, ui\, lib\, VERSION)')
    Warn '  Bundan sonra butun gorevler ve kisayollar kurulum dizininden calisir.'
    Step '1) Tehis raporu'
    Warn ('  calistirilacak: ' + $DiagScript + '  (okuma modunda)')
    Step '2) Host watchdog'
    Warn ('  calistirilacak: ' + $AppDir + '\host\RemoteHostWatchdog.ps1 -Install -IntervalMinutes ' + $IntervalMinutes)
    if ($TelegramToken) { Warn '  -TelegramToken verilecek' } else { Warn '  Telegram token YOK: alarm ekranda gorunur, Telegram gelmez' }
    if ($KeepSleep) { Warn '  -KeepSleep: uyku ve Fast Startup ayarlarina dokunulmayacak' }
    Step '3) Belge koruyucu'
    Warn ('  goru: ' + $AppDir + '\host\Protect-OpenDocuments.ps1 (zamanlanmis gorev host -Install icinde kurulur)')
    Step '4) Tray paneli'
    if ($SkipTray) { Warn '  atlandi (-SkipTray)' } else { Warn ('  calistirilacak: ' + $AppDir + '\ui\RemoteWatchdogPanel.ps1 -Install') }
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

# Panel calisiyorsa betigi kilitliyor; robocopy /MIR onarim modunda eskiyi atlamaz,
# bu yuzden Once paneli kapatiyoruz (asagida kurulumdan sonra yeniden baslatilacak).
$panelProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'RemoteWatchdogPanel' -and $_.ProcessId -ne $PID })
if ($panelProcs.Count -gt 0) {
    Step '0) Calisan panel kapatiliyor (dosya kilidi acilsin)'
    foreach ($pp in $panelProcs) { try { Stop-Process -Id $pp.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    Start-Sleep -Seconds 2
    Ok ('kapatildi: ' + $panelProcs.Count + ' panel surecu')
}

Step '0) Kurulum dizinine kopyalaniyor'
$app = Copy-AppToInstallDir
Ok ('kurulum dizini: ' + $app.Dir + '  (v' + $app.Ver + ')')
$HostScript = $app.Host
$DocsScript = $app.Docs
$TrayScript = $app.Panel

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
if ($p.ExitCode -eq 0) { Ok 'zamanlanmış görev kuruldu (acilista + oturum acilista + her ' + $IntervalMinutes + ' dk)' } else { Warn ('kurulum donus kodu: ' + $p.ExitCode) }

$cfgPath = 'C:\ProgramData\RemoteWatchdog'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $acct = "$env:COMPUTERNAME\$env:USERNAME"
        icacls $cfgPath /grant "${acct}:(OI)(CI)M" /T /C 2>&1 | Out-Null
        $probe = Join-Path $cfgPath 'acl-probe.tmp'
        Set-Content -LiteralPath $probe -Value 'probe' -Encoding UTF8
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Ok "config klasoru izinleri duzeltildi (panel ayar kaydedebilsin): $acct"
    } catch { Warn ('izin duzeltilemedi, panel ayar kaydedemeyebilir: ' + $_.Exception.Message) }
}
Start-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
$task = Get-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue
if ($task) { Ok ('görev durumu: ' + $task.State) } else { Die 'gorev olusmadi' }
if (Get-ScheduledTask -TaskName 'RemoteHostOfficeSaver' -ErrorAction SilentlyContinue) { Ok 'belge koruyucu görevi kuruldu' } else { Warn 'belge koruyucu gorevi kurulmadi (belge kaydetme korumasi kapali)' }
if (Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue) { Warn 'CRD: cihaz yeniden kaydedilmemiş gorunuyor -> asagidaki 5. adim zorunlu' }

Step '3) Belge koruyucu kontrolu'
& powershell -NoProfile -ExecutionPolicy Bypass -File $DocsScript -Status | Out-String | Write-Host

Step '4) Tray kontrol paneli'
if ($SkipTray) { Warn 'atlandi (-SkipTray)' }
else {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $TrayScript -Install | Out-Null
    if (Get-ItemProperty -Path $runKey -Name 'RemoteWatchdogTray' -ErrorAction SilentlyContinue) { Ok 'panel oturum açılışında başlayacak' } else { Warn 'tray kaydi olusmadi (farkli yonetici hesabi ile calistirilmis olabilir)' }
    $vbs = Join-Path (Split-Path -Parent $TrayScript) 'Start-Panel.vbs'
    if (Test-Path -LiteralPath $vbs) {
        # "show" argumani ile: pencereyi one getirir. explorer.exe uzerinden calistirmak
        # paneli arka planda baslatiyor ve kullanicinin paneli acmadigi saniliyordu.
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '" show')
        Ok 'panel etkilesimli oturumda (yoneticisiz) baslatildi'
    } else {
        Warn ('panel baslatici bulunamadi: ' + $vbs + ' - elle calistirin: ' + $TrayScript)
    }
}

Step '5) Google Remote Desktop kaydı (ZORUNLU)'
Write-Host '    1) Bu makinede Chrome ac:  https://remotedesktop.google.com/headless'
Write-Host '    2) "Set up remote access" / "Uzaktan erisimi ayarla" -> bir ad ve PIN verir'
Write-Host '    3) Kendi cihazinda https://remotedesktop.google.com -> Machines altindaki "+" -> ad + PIN'
Write-Host '    4) Listede gorundugunde "baglanti calisiyor" degilse paneldeki CRD kontrolune bak'
Warn 'Bu adim watchdog ile yapilamaz; cihazin host kaydi (host.json) yoksa listede gorunmez.'

Step '6) Ozet'
$cfg = 'C:\ProgramData\RemoteWatchdog\config.json'
if (Test-Path -LiteralPath $cfg) { Ok ('config: ' + $cfg) }
Ok ('kurulum: ' + $AppDir)
Ok ('log: C:\ProgramData\RemoteWatchdog\host-watchdog.log')
Ok 'durum: tray paneli veya  powershell -File "' + $HostScript + '" -Status'
if (-not $TelegramToken) { Warn 'Telegram bildirimi kapali; ekranda uyari gorunur. Eklemek icin: Install-Host.ps1 -TelegramToken ... -TelegramChatId ...' }
Write-Host ''
Write-Host 'Kurulum tamamlandı. Artık deponun yerini önemsemezsiniz; her şey' -ForegroundColor Green
Write-Host ('  ' + $AppDir + ' altından çalışıyor. Güncelleme için bu klasörü') -ForegroundColor Green
Write-Host '  Install-Host.ps1 ile tekrar kurulum yapman yeterli.' -ForegroundColor Green
