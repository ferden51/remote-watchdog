#Requires -Version 5.1
<#
    RemoteHostWatchdog - UZAK MAKINE tarafi (host)
    Kendini periyodik test eder, bozulan parcalari onarir, olculmezse makineyi yeniden baslatir,
    disariya nabiz (heartbeat) ve Telegram uyarisi gonderir. Sunucu gibi calisacak sekilde ayarlar.

    .\RemoteHostWatchdog.ps1 -Check     sadece rapor, hicbir sey degistirmez
    .\RemoteHostWatchdog.ps1            bir onarim dongusu
    .\RemoteHostWatchdog.ps1 -UserFallback  SYSTEM gorevi saglamsa cikis, yoksa/eskise tam dongu (kullanici yedegi)
    .\RemoteHostWatchdog.ps1 -FastProbe     hafif 60 sn yoklamasi: sorun varsa tam donguyu hemen tetikler
    .\RemoteHostWatchdog.ps1 -NetListen    surekli ag olay dinleyicisi (kablo/adaptor/IP degisimi ANLIK)
    .\RemoteHostWatchdog.ps1 -Install   zamanlanmis gorev + servis ayarlari (admin)
    .\RemoteHostWatchdog.ps1 -Uninstall
    .\RemoteHostWatchdog.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Check,
    [switch]$Status,
    [int]$IntervalMinutes = 5,
    [string]$HeartbeatUrl = '',
    [string]$TelegramToken = '',
    [string]$TelegramChatId = '',
    [string]$TunnelName = '',
    [switch]$EnableTunnelRepair,
    [switch]$KeepSleep,
    [string]$AddHoliday = '',
    [string]$RemoveHoliday = '',
    [switch]$ListHolidays,
    [switch]$Json,
    [switch]$NoJson,
    [switch]$ForceReboot,
    [switch]$RepairNetwork,
    [switch]$RepairWatch,
    [switch]$UserFallback,
    [switch]$FastProbe,
    [switch]$NetListen,
    [switch]$NetTestEvent,
    [switch]$Version,
    [int]$Rung = 0
)

$ErrorActionPreference = 'Continue'

$LibDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib'
foreach ($lib in @('Common.ps1', 'Contract.ps1')) {
    $libPath = Join-Path $LibDir $lib
    if (-not (Test-Path -LiteralPath $libPath)) { Write-Host ("KRITIK: kitaplik eksik: " + $libPath); exit 2 }
    . $libPath
}
$ScriptPath = $PSCommandPath
$VersionFile = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) 'VERSION'
$script:AppVersion = '0.0.0'
if (Test-Path -LiteralPath $VersionFile) { try { $script:AppVersion = ([System.IO.File]::ReadAllText($VersionFile)).Trim() } catch { } }
$BaseDir = Join-Path $env:ProgramData 'RemoteWatchdog'
$LogFile = Join-Path $BaseDir 'host-watchdog.log'
$LogDir = Join-Path $BaseDir 'log'
$StateFile = Join-Path $BaseDir 'host-state.json'
$ConfigFile = Join-Path $BaseDir 'config.json'
$RebootPendingFile = Join-Path $BaseDir 'reboot-pending.json'
$RebootCancelFile = Join-Path $BaseDir 'reboot-cancel.flag'
$RebootAckFile = Join-Path $BaseDir 'reboot-ack.json'
$TaskName = 'RemoteHostWatchdog'
$script:Results = New-Object System.Collections.ArrayList
$script:PublicIp = $null
$global:cfg = $null
$RebootableProblems = @('Internet', 'Saat senkronu', 'Ag katmani', 'Windows RDP', 'Guc/uyku ayarlari')

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LogColor {
    <#
        Konsol renk kurali (ayarlar sayfasinda da ayni kural):
          yesil  = stabil durum   (CHECK TAMAM)
          kirmizi= hata / sorun   (WARN, ALERT, ERROR, CHECK SORUN)
          mavi   = bilgilendirme (INFO, CHECK ATLANDI)
    #>
    param([string]$Level = 'INFO', [string]$Text = '')
    $l = ([string]$Level).ToUpperInvariant()
    if ($l -in @('WARN', 'ALERT', 'ERROR', 'FAIL')) { return 'Red' }
    if ($l -eq 'CHECK') {
        if ($Text -match 'TAMAM') { return 'Green' }
        if ($Text -match 'SORUN') { return 'Red' }
        return 'Cyan'
    }
    return 'Blue'
}

function Remove-OldLogFiles {
    <#  LogGunDays gunden eski arsivleri siler (sadece rotasyonda calisir, maliyeti dusuk). #>
    $days = 30
    try { $days = [int]$global:cfg.LogGunDays } catch { }
    if ($days -le 0) { return }
    try {
        $cut = (Get-Date).AddDays(-$days)
        foreach ($f in @(Get-ChildItem -LiteralPath $LogDir -Filter 'host-watchdog-*.log' -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTime -lt $cut) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

function Rotate-LogIfNeeded {
    <#
        Gunluk + boyut tabanli rotasyon. Eskiden her satir yaziminda TUM dosya okunup 5000
        satirda son 4000'e kirpiliyordu: 4400 satir/gun ile yalnizca ~1 gun saklaniyordu.
        Simdi dosya LogDosyaMB'yi asinca log/ klasorune gun-tarihli arsiv tasinir ve
        LogGunDays gun eskisi silinir (ayni zamanda her yazimda dosya okunmaz, log ucuzlar).
    #>
    $maxBytes = 2MB
    try { $maxBytes = [int]$global:cfg.LogDosyaMB * 1MB } catch { }
    if ($maxBytes -lt 256KB) { $maxBytes = 2MB }
    try {
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        if ((Get-Item -LiteralPath $LogFile).Length -lt $maxBytes) { return }
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        $arch = Join-Path $LogDir ('host-watchdog-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
        Move-Item -LiteralPath $LogFile -Destination $arch -Force -ErrorAction Stop
        Remove-OldLogFiles
    } catch { }
}

function Write-Log {
    param([string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    try {
        if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        Rotate-LogIfNeeded
    } catch { }
    Write-Host $line -ForegroundColor (Get-LogColor -Level $Level -Text $Message)
}

function Get-Config {
    $cfg = [ordered]@{
        FixRdp = $true
        FixCrd = $true
        FixClock = $true
        FixNetwork = $true
        NetMaxRepairRung = 4
        ServerMode = $true
        DisableHibernation = $true
        DisableFastStartup = $true
        ServiceAutoStart = $true
        ServiceCrashRecovery = $true
        <#
            HIZ: amac "en hizli tespit -> en hizli karar -> en hizli eylem". Zincir:
              t=0     kesinti -> ag olay dinleyicisi ANINDA yakalar (yoksa hizli yoklama <=1 dk)
              t~0.05  tetiklenen tam dongu ANINDA baslar (yaklasik 10-15 sn surer)
              t~0.3   ilk basarisiz dongu: RebootAfterFailedCycles=1, MinOutageMinutes=0
                      -> KARAR. (Taze toparlanma kontrolu + sesli "30 saniye icinde" anonsu)
              t~1.0   30 sn geri sayim biter -> RESTART
            Yani tespitten restart'a ~1 dakika. Blip korumasi korunur: karar aninda interneti
            iki kez daha yoklar (taze kontrol) ve geri sayim icinde internet gelirse iptal eder.
            Daha da hizli istemiyorsaniz: RebootDelaySeconds=10 (anons yine duyulur).
            Guvenlik sinirlari (bilerek kalir): MaxRestartsPerDay=3 (restart firtinasi olmaz)
            ve MinUptimeMinutes (yeniden acilis sonrasi kisa bekleme -> boot dongusu olmaz).
        #>
        RebootAfterFailedCycles = 1
        RebootDelaySeconds = 30
        MaxRestartsPerDay = 3
        RebootCooldownMinutes = 2
        HealthyMinutesToReset = 30
        RebootSkipIfUnregistered = $true
        MinUptimeMinutes = 3
        MinOutageMinutes = 0
        OfficeSaveBeforeReboot = $true
        OfficeSaveTimeoutSeconds = 60
        OfficeAbortRebootIfStillOpen = $true
        OfficeAbortRebootIfUnsaved = $true
        RestartPolicy = 'blackout'
        BlackoutEnabled = $true
        BlackoutStart = 18
        BlackoutEnd = 8
        BlackoutNights = @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')
        BlackoutFullDays = @('Cmt', 'Paz')
        HolidayMode = 'full'
        Holidays = @()
        HolidaysFile = ''
        NotifyRepeatHours = 4
        SesliBildirim = $true
        SesliBildirimEdge = $true
        EkranMesaji = $true
        LogGunDays = 30
        LogDosyaMB = 2
        SesEfektleri = $true
        SesEfektleriVolume = 80
        ForceRestartAlways = $false
        ForceRestartUntil = ''
        CrdRestartAfterHours = 0
        CrdSignalPorts = @(443, 5222, 5223, 19302, 19303, 8443, 4433)
        CrdNoConnRestartCycles = 3
        PanelRepair = $true
        PanelScriptName = 'RemoteWatchdogPanel.ps1'
        TunnelRepair = $false
        TunnelName = 'uzak-pc'
        HeartbeatUrl = ''
        HeartbeatFailPath = '/fail'
        TelegramToken = ''
        TelegramChatId = ''
        AlertRepeatHours = 12
    }
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) { if ($saved.PSObject.Properties.Name -contains $k) { $cfg[$k] = $saved.$k } }
        } catch { }
    }
    return $cfg
}

function Save-Config {
    param($Cfg)
    if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
    $Cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
}

function Get-State {
    $s = [pscustomobject]@{
        ConsecutiveFailures = 0
        CrdNoConnCycles = 0
        NetRepairRung = 0
        NetResetPendingReboot = 0
        RebootsUtc = @()
        LastBootUtc = ''
        PendingRebootUtc = ''
        LastHealthyUtc = ''
        AlertKey = ''
        AlertUtc = ''
        LastOkUtc = ''
        LastUserNotifyUtc = ''
        LastNotifyKey = ''
        LastRebootAnnounceUtc = ''
        OutageStartUtc = ''
        BreakerKey = ''
    }
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $raw = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { if ($s.PSObject.Properties.Name -contains $p.Name) { $s.($p.Name) = $p.Value } }
        } catch { }
    }
    return $s
}

function Save-State {
    param($State)
    for ($i = 1; $i -le 3; $i++) {
        try {
            $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StateFile -Encoding UTF8
            break
        } catch {
            if ($i -lt 3) { Start-Sleep -Milliseconds 200 }
        }
    }
}

function Invoke-StateUpdate {
    <#
        Durumu "oku -> degistir -> yaz" tek seferde yapar.
        Neden sart: daha once fonksiyonlar $state = Get-State ile bir kopya alip sonra
        Save-State $state ile geri yaziyordu. Arada baska bir fonksiyon (orn. kullanici
        bildirimi) LastUserNotifyUtc'yi kaydediyorsa, elde tutulan ESKI kopya onu
        geri aliyordu; "4 saatte bir tekrar et" kisiti bu yuzden hic calismiyor ve
        mesaj kutusu her dongude yeniden basiliyordu.
    #>
    param([scriptblock]$Mutate)
    $s = Get-State
    if ($Mutate) { $null = & $Mutate $s }
    Save-State $s
    return $s
}

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [string]$Repair = '', [bool]$Skipped = $false, [hashtable]$Metrics = @{})
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Skipped = $Skipped; Detail = $Detail; Repair = $Repair; Metrics = $Metrics })
    $tag = if ($Skipped) { 'ATLANDI ' } elseif ($Ok) { 'TAMAM    ' } else { 'SORUN    ' }
    Write-Log 'CHECK' ('{0} {1} | {2}{3}' -f $tag, $Name, $Detail, $(if ($Repair) { ' | onarim: ' + $Repair } else { '' }))
}

function Invoke-Probe {
    param([string]$Url, [int]$TimeoutSec = 10, [string]$Method = 'GET')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $Url -Method $Method -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        return [pscustomobject]@{ Ok = $true; Status = [int]$r.StatusCode; Raw = $r; Error = ''; Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        return [pscustomobject]@{ Ok = $false; Status = $code; Raw = $null; Error = $_.Exception.Message; Ms = [int]$sw.ElapsedMilliseconds }
    }
}

function Get-TcpMs {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return -1 }
        $c.EndConnect($iar)
        $sw.Stop()
        return [int]$sw.ElapsedMilliseconds
    } catch { return -1 } finally { try { $c.Close() } catch { } }
}

function Test-InternetFast {
    <#
        DETERMINISTIK ve HIZLI internet kontrolu. Neden ayri fonksiyon:
        Invoke-Probe (Invoke-WebRequest) asilir zaman asiminda DNS cozumlemesinde
        takilabiliyor; bu da restart geri sayim dongusunu olduruyordu (dongu yarida
        kayboluyor, shutdown.exe hic cagrilmamiyor oluyordu).
        Burada yalnizca TCP/443 dogrudan IP adresine ve mtalk.google.com'a bakilir;
        Get-TcpMs sert zaman asimi koyar, yani islem ASLA takilmaz.
    #>
    param([int]$TimeoutMs = 3500)
    foreach ($hedef in @(@('1.1.1.1', 443), @('8.8.8.8', 443), @('mtalk.google.com', 443))) {
        if ((Get-TcpMs -HostName $hedef[0] -Port $hedef[1] -TimeoutMs $TimeoutMs) -ge 0) { return $true }
    }
    return $false
}

function Get-PowerSettingAcIndex {
    param([string[]]$AliasPath)
    $out = (powercfg /query SCHEME_CURRENT @AliasPath 2>&1 | Out-String)
    $m = [regex]::Match($out, '(?i)0x([0-9a-f]{8})')
    if ($m.Success) { return [convert]::ToInt32($m.Groups[1].Value, 16) }
    return $null
}

function Get-UptimeMinutes {
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    if (-not $boot) { return 999999 }
    return [math]::Round(((Get-Date) - $boot).TotalMinutes, 0)
}

function Get-CrdHostConfigPath {
    $fallback = 'C:\ProgramData\Google\Chrome Remote Desktop\host.json'
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='chromoting'" -ErrorAction Stop
        if ($svc -and $svc.PathName -match '--host-config="?([^";]+)"?') { return $matches[1].Trim() }
    } catch { }
    return $fallback
}

function Get-CrdDaemon {
    return @(Get-Process -Name 'remoting_host', 'remoting_start_host' -ErrorAction SilentlyContinue)
}

function Get-CrdActiveSession {
    return @(Get-Process -Name 'remoting_desktop' -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-CrdSignalConnections {
    param([int[]]$Ports)
    $pids = @((Get-Process -Name 'remoting_host', 'remoting_start_host', 'remoting_desktop' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id))
    if ($pids.Count -eq 0) { return 0 }
    $count = 0
    try { $ns = netstat -ano -p tcp 2>&1 } catch { return 0 }
    foreach ($line in $ns) {
        if ($line -match '^\s*TCP\s+\S+\s+(\S+):(\d+)\s+(\S+)\s+(\d+)\s*$') {
            if ($matches[3] -eq 'ESTABLISHED' -and ($Ports -contains [int]$matches[2]) -and ($pids -contains [int]$matches[4])) { $count++ }
        }
    }
    return $count
}

function Test-Internet {
    $r = Invoke-Probe -Url 'https://www.google.com/generate_204' -TimeoutSec 8
    $mtalkMs = Get-TcpMs -HostName 'mtalk.google.com' -Port 443
    $mtalk = ($mtalkMs -ge 0)
    $ok = $r.Ok -and $mtalk
    $m = [ordered]@{ google204 = $(if ($r.Ok) { $r.Status } else { 'hata' }); google204ms = $r.Ms; mtalk443 = $(if ($mtalk) { 'acik' } else { 'kapali' }); mtalk443ms = $mtalkMs }
    Add-Result 'Internet' $ok ('google204=' + $(if ($r.Ok) { $r.Status } else { 'HATA' }) + ' (' + $r.Ms + 'ms), mtalk:443=' + $(if ($mtalk) { 'acik/' + $mtalkMs + 'ms' } else { 'KAPALI' })) $(if ($ok) { '' } else { 'ag yok; CRD kayit olamaz' }) $false $m
    return $ok
}

function Test-Clock {
    $r = Invoke-Probe -Url 'https://www.google.com/generate_204' -TimeoutSec 8
    $offset = $null
    if ($r.Ok -and $r.Raw) {
        try { $offset = [math]::Round(([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$r.Raw.Headers['Date']).ToUniversalTime()).TotalSeconds) } catch { }
    }
    if ($null -eq $offset) { Add-Result 'Saat senkronu' $true 'sunucu saati okunamadi' '' $true; return }
    $ok = [math]::Abs($offset) -le 120
    $repair = ''
    if (-not $ok -and $global:cfg.FixClock -and (Test-Admin) -and -not $Check) {
        w32tm /resync /force 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $repair = 'w32tm /resync'
    }
    Add-Result 'Saat senkronu' $ok ('ofset=' + $offset + 'sn') $repair
}

function Test-TcpPortFast {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Get-NetworkHealth {
    $h = [ordered]@{ Ip = $false; Dns = $false; Https = $false; Signal = $false; Dhcp = $false; TimeWait = 0; Link = ''; IpMs = -1; IpHost = ''; SignalMs = -1; HttpsMs = -1; DnsMs = -1 }
    foreach ($probeIp in @('9.9.9.9', '1.1.1.1', '8.8.8.8')) {
        $ms = Get-TcpMs -HostName $probeIp -Port 443 -TimeoutMs 3000
        if ($ms -ge 0) { $h.IpMs = $ms; $h.IpHost = $probeIp; break }
    }
    $h.Ip = ($h.IpMs -ge 0)
    $h.SignalMs = Get-TcpMs -HostName 'mtalk.google.com' -Port 443 -TimeoutMs 3000
    $h.Signal = ($h.SignalMs -ge 0)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $h.Dns = [bool](Resolve-DnsName -Name 'remotedesktop.google.com' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { }
    $sw.Stop(); $h.DnsMs = [int]$sw.ElapsedMilliseconds
    $r = Invoke-Probe -Url 'https://www.google.com/generate_204' -TimeoutSec 6
    $h.Https = $r.Ok
    $h.HttpsMs = $r.Ms
    try { $h.Dhcp = @((Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.Dhcp -eq 'Enabled' })).Count -gt 0 } catch { }
    try {
        $ano = @(netstat -ano -p tcp 2>&1)
        $h.TimeWait = @($ano | Where-Object { $_ -match '(?i)\bTIME_WAIT\b' }).Count
    } catch { }
    try { $h.Link = (@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { $_.Name }) -join ',') } catch { }
    return [pscustomobject]$h
}

function Get-RepairRungName {
    <#  Onarim kademesinin adlari (panel canli izinde gosterir). #>
    param([int]$Rung)
    switch ($Rung) {
        1 { return 'DNS onbellegi temizleme + Dnscache servisi yeniden baslatma' }
        2 { return 'DHCP lease yenileme (release/renew)' }
        3 { return 'Wi-Fi yeniden baglanma + adaptor kapat/ac' }
        4 { return 'Dhcp/NlaSvc servisleri + surucu yeniden baslatma' }
        5 { return 'winsock/IP reset (yeniden baslatma gerekir)' }
        default { return 'bilinmeyen kademe' }
    }
}

function Invoke-NetworkRepair {
    param([int]$Rung)
    $cfg = $global:cfg
    $done = @()
    switch ($Rung) {
        1 {
            try { ipconfig /flushdns 2>&1 | Out-Null; $done += 'DNS onbellegi temizlendi' } catch { }
            try { Restart-Service -Name 'Dnscache' -Force -ErrorAction Stop; $done += 'Dnscache servisi yeniden baslatildi' } catch { }
        }
        2 {
            try { ipconfig /release 2>&1 | Out-Null; Start-Sleep 2; ipconfig /renew 2>&1 | Out-Null; $done += 'DHCP lease yenilendi' } catch { }
        }
        3 {
            try { netsh wlan reconnect 2>&1 | Out-Null; $done += 'Wi-Fi yeniden baglanma denemesi' } catch { }
            foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                try { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep 3; Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue; $done += ($a.Name + ' kapatildi/acildi') } catch { }
            }
        }
        4 {
            foreach ($s in @('Dhcp', 'NlaSvc')) { try { Restart-Service -Name $s -Force -ErrorAction Stop; $done += ($s + ' yeniden baslatildi') } catch { } }
            try {
                $dev = @(Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'NetEnabled=True' -ErrorAction Stop | Select-Object -ExpandProperty DeviceID -Unique)
                foreach ($d in $dev) { pnputil /restart-device $d 2>&1 | Out-Null; $done += ('surucu yeniden baslatildi: ' + $d) }
            } catch { }
        }
        5 {
            netsh winsock reset 2>&1 | Out-Null
            netsh int ipv4 reset 2>&1 | Out-Null
            $done += 'winsock/IP reset uygulandi (yENIDEN BASLATMA gerekiyor)'
        }
    }
    return $done
}

function Test-NetworkHealthy {
    <#  Ag katmani saglikli mi: IP, DNS, HTTPS ve sinyal yolu ayni anda. #>
    $h = Get-NetworkHealth
    return [bool]($h.Ip -and $h.Dns -and $h.Https -and $h.Signal)
}

function Invoke-NetworkRepairFlow {
    <#
        Kullanicinin (ya da panelin) istedigi elle onarim.
        Kademeleri sirayla uygular, her kademeden sonra tekrar olcer ve saglikli olunca durur.
        Sonucu $script:LastRepair olarak JSON'a yazar; panel bunu okuyup kullaniciya gosterir.
    #>
    param([int]$MaxRung = 0, [string]$Reason = 'kullanici istedi')
    $cfg = $global:cfg
    if ($MaxRung -le 0) { $MaxRung = [int]$cfg.NetMaxRepairRung }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $applied = @()
    $rungs = @()
    $cancelled = $false
    $healthy = Test-NetworkHealthy
    Write-Log 'WARN' ('elle ag onarimi basladi: ' + $Reason + ' (saatlim: ' + $healthy + ')')
    if ($healthy) {
        Write-Log 'INFO' 'ag saglikli, hicbir kademe uygulanmadi'
    } else {
        $cancelled = $false
        for ($r = 1; $r -le $MaxRung; $r++) {
            <# Kullanici paneli kapattiysa burada dururuz; kademeler yari birakilmasin. #>
            if (Test-RepairCancelled) {
                $cancelled = $true
                Write-Log 'WARN' ('ag onarimi iptal edildi (kullanici istedi), kademe ' + $r + ' uygulanmadi')
                break
            }
            Write-Log 'INFO' ('kademe ' + $r + '/' + $MaxRung + ' basliyor: ' + (Get-RepairRungName $r))
            $steps = @(Invoke-NetworkRepair -Rung $r)
            $rungs += $r
            $applied += $steps
            Write-Log 'INFO' ('kademe ' + $r + ' uygulandi: ' + $(if ($steps.Count) { $steps -join '; ' } else { 'islem yok' }))
            Start-Sleep -Seconds 3
            $healthy = Test-NetworkHealthy
            if ($healthy) { Write-Log 'INFO' ('kademe ' + $r + ' sonrasi ag saglikli, onarim durduruldu'); break }
            Write-Log 'WARN' ('kademe ' + $r + ' sonrasi hâlâ sorun var, devam ediliyor')
        }
    }
    $sw.Stop()
    $h = Get-NetworkHealth
    $still = @()
    if (-not $h.Ip) { $still += 'IP erisimi yok' }
    if (-not $h.Dns) { $still += 'DNS cozumlemiyor' }
    if (-not $h.Https) { $still += 'HTTPS erisimi yok' }
    if (-not $h.Signal) { $still += 'Google sinyal yolu kapali' }
    $script:LastRepair = [ordered]@{
        at = (Get-Date).ToString('o')
        reason = $Reason
        healthyAtStart = $healthy
        ok = ($still.Count -eq 0)
        cancelled = $cancelled
        rungs = $rungs
        actions = $applied
        stillBad = $still
        elapsedSec = [int]$sw.Elapsed.TotalSeconds
    }
    Write-Log $(if ($cancelled) { 'WARN' } elseif ($script:LastRepair.ok) { 'INFO' } else { 'WARN' }) $(if ($cancelled) { ('ag onarimi iptal edildi (kullanici kapatti), uygulanan kademe=' + ($rungs -join ',') + ', sure=' + $script:LastRepair.elapsedSec + ' sn') } else { ('ag onarimi bitti: basarili=' + $script:LastRepair.ok + ', kademe=' + ($rungs -join ',') + ', sure=' + $script:LastRepair.elapsedSec + ' sn' + $(if ($still.Count) { ', kalan sorun: ' + ($still -join ', ') } else { '' })) })
    # Iptal kaydi kalmasin: sonraki otomatik onarimlar da iptal sayilmasin
    Clear-RepairCancelIfIdle
    return $script:LastRepair
}

function Read-RepairRequest {
    <#  Panelin bir dosya birakerek istedigi onarim: panel, görevi SYSTEM olarak çalıştırır, UAC gerekmez. #>
    $reqPath = Join-Path $BaseDir 'repair-request.json'
    if (-not (Test-Path -LiteralPath $reqPath)) { return $null }
    $req = $null
    try { $req = Get-Content -LiteralPath $reqPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    try { Remove-Item -LiteralPath $reqPath -Force -ErrorAction SilentlyContinue } catch { }
    # Yeni istek geldi: onceki iptal kaydini temizle (yoksa bu istek de iptal sayilir)
    Clear-RepairCancel
    $rung = 0
    if ($req -and $req.PSObject.Properties.Name -contains 'rung') { try { $rung = [int]$req.rung } catch { } }
    $who = 'panel'
    if ($req -and $req.PSObject.Properties.Name -contains 'requestedBy') { $who = [string]$req.requestedBy }
    return [pscustomobject]@{ Rung = $rung; RequestedBy = $who; At = (Get-Date).ToString('o') }
}

function Test-RepairRequestPending {
    <#  Panelin biraktigi onarim istegi dosyasi var mi (bu calisma icinde mi geldi)? #>
    return (Test-Path -LiteralPath (Join-Path $BaseDir 'repair-request.json'))
}

function Test-RepairCancelled {
    <#
        Panelde kullanici onarim penceresini kapattiysa repair-cancel.json yazilir.
        Akis burada kontrol edip kalan kademeleri uygulamadan durur; boylece kullanici
        "iptal" dediginde onarim gercekten yari birakilmaz.
    #>
    return (Test-Path -LiteralPath (Join-Path $BaseDir 'repair-cancel.json'))
}

function Clear-RepairCancel {
    <#  Yeni onarim istegi geldiginde eski iptal kaydini temizle, yoksa onarim hic baslamaz. #>
    try { Remove-Item -LiteralPath (Join-Path $BaseDir 'repair-cancel.json') -Force -ErrorAction SilentlyContinue } catch { }
}

function Clear-RepairCancelIfIdle {
    <#
        Onarim akisi bittiginde iptal kaydini kaldir. Kaydi kalici birakirsak, sonraki
        otomatik (izleyici) onarimlar da kullanici kapatmadi haliyle iptal sayilir.
    #>
    if (Test-RepairCancelled) {
        try { Remove-Item -LiteralPath (Join-Path $BaseDir 'repair-cancel.json') -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Test-NetworkLayer {
    $cfg = $global:cfg
    $script:LastRepair = $null
    $repairReq = Read-RepairRequest
    if ($RepairNetwork -or $repairReq) {
        $why = $(if ($repairReq) { 'panel istedi (' + $repairReq.RequestedBy + ')' } else { 'kullanici istedi' })
        $mr = $(if ($repairReq) { $repairReq.Rung } else { $Rung })
        $null = Invoke-NetworkRepairFlow -MaxRung $mr -Reason $why
    }
    $state = Get-State
    $h = Get-NetworkHealth
    $detail = 'ip=' + $h.Ip + ', dns=' + $h.Dns + ', https=' + $h.Https + ', sinyal=' + $h.Signal + ', dhcp=' + $h.Dhcp + ', timewait=' + $h.TimeWait + ', link=' + $h.Link
    if ($h.TimeWait -gt 15000) { Write-Log 'WARN' ('TCP TIME_WAIT sayisi yuksek: ' + $h.TimeWait + ' -> soket yigini sizmis olabilir') }
    $ok = ($h.Ip -and $h.Dns -and $h.Https)
    $metrics = [ordered]@{ ip443 = $(if ($h.Ip) { $h.IpMs } else { -1 }); iphost = $(if ($h.IpHost) { $h.IpHost } else { 'yok' }); ip443state = $(if ($h.Ip) { 'acik' } else { 'kapali' }); dnsms = $h.DnsMs; dnsstate = $(if ($h.Dns) { 'cozuldu' } else { 'cozulemedi' }); httpsms = $h.HttpsMs; httpsstate = $(if ($h.Https) { 'acik' } else { 'kapali' }); signalms = $h.SignalMs; signalstate = $(if ($h.Signal) { 'acik' } else { 'kapali' }); timewait = $h.TimeWait; dhcp = $h.Dhcp; link = $h.Link }
    $repair = @()
    if ($ok) {
        if ([int]$state.NetRepairRung -gt 0) { $repair += 'saga likli, onarim merdiveni sifirlandi (son: ' + $state.NetRepairRung + '. kademe)' }
        $null = Invoke-StateUpdate { param($st) $st.NetRepairRung = 0 }
    } else {
        $rung = [int]$state.NetRepairRung + 1
        if ($rung -gt [int]$cfg.NetMaxRepairRung) { $rung = [int]$cfg.NetMaxRepairRung }
        $repair += ('bozuk: eksik=' + (@(if (-not $h.Ip) { 'IP' }) + @(if (-not $h.Dns) { 'DNS' }) + @(if (-not $h.Https) { 'HTTPS' }) -join ','))
        $resetPending = 0
        if ($cfg.FixNetwork -and (Test-Admin) -and -not $Check) {
            $repair += (Invoke-NetworkRepair -Rung $rung) -join '; '
            if ($rung -ge [int]$cfg.NetMaxRepairRung) { $resetPending = 1; $repair += 'onerilen: makineyi yeniden baslat' }
        } else {
            $repair += 'kademe ' + $rung + ' uygulanmadi (admin gerekir)'
        }
        <#  Onarim merdiveni tek seferde yazilir: aradaki baska sureclerin (bildirim
            throttle'u gibi) degistirdigi alanlar ezilmez. #>
        $null = Invoke-StateUpdate {
            param($st)
            $st.NetRepairRung = $rung
            $st.NetResetPendingReboot = $resetPending
        }
    }
    Add-Result 'Ag katmani' $ok $detail ($repair -join '; ') $false $metrics
}

function Get-PanelProcesses {
    $name = [string]$global:cfg.PanelScriptName
    if (-not $name) { $name = 'RemoteWatchdogPanel.ps1' }
    $pattern = '-File\s+"?[^"]*' + [regex]::Escape($name)
    return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}

function Test-Panel {
    $cfg = $global:cfg
    $procs = @(Get-PanelProcesses)
    $task = Get-ScheduledTask -TaskName 'RemoteHostPanel' -ErrorAction SilentlyContinue
    $ok = ($procs.Count -gt 0)
    $repair = @()
    $m = [ordered]@{ procCount = $procs.Count; taskInstalled = [bool]$task; taskState = $(if ($task) { [string]$task.State } else { 'yok' }) }
    if (-not $ok) {
        if ($cfg.PanelRepair -and -not $Check) {
            if ($task) {
                try { Start-ScheduledTask -TaskName 'RemoteHostPanel' -ErrorAction Stop; $repair += 'panel gorevi tetiklendi (yeniden baslayacak)' } catch { $repair += 'panel gorevi calistirilamadi: ' + $_.Exception.Message }
            } else {
                $panelScript = $null
                try { $panelScript = Join-Path (Split-Path -Parent $ScriptPath) '..\ui\RemoteWatchdogPanel.ps1' } catch { }
                if ($panelScript -and (Test-Path -LiteralPath $panelScript)) {
                    $u = $env:USERNAME
                    try {
                        $vbs = Join-Path (Split-Path -Parent (Resolve-Path $panelScript).Path) 'Start-Panel.vbs'
                        if (Test-Path -LiteralPath $vbs) {
                            $pa = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
                        } else {
                            $pa = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Resolve-Path $panelScript).Path + '" -Background')
                        }
                        $pp = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited
                        $ps = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -Hidden
                        Register-ScheduledTask -TaskName 'RemoteHostPanel' -Action $pa -Principal $pp -Settings $ps -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)) -Force | Out-Null
                        Start-ScheduledTask -TaskName 'RemoteHostPanel'
                        $repair += 'panel gorevi olusturuldu ve calistirildi'
                    } catch { $repair += 'panel baslatilamadi (kullanici oturumu gerekli): ' + $_.Exception.Message }
                } else { $repair += 'panel betigi bulunamadi' }
            }
        } else { $repair += 'panel calismiyor' }
    }
    Add-Result 'Kontrol paneli' $ok ('surec=' + $procs.Count + ', gorev=' + $m.taskState) ($repair -join '; ') $true $m
}

function Test-CrdService {
    $cfg = $global:cfg
    $svc = Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue
    if (-not $svc) {
        $installed = (Test-Path 'C:\Program Files (x86)\Google\Chrome Remote Desktop') -or (Test-Path 'C:\Program Files\Google\Chrome Remote Desktop')
        Add-Result 'CRD servisi' $false $(if ($installed) { 'chromoting servisi kayit degil -> CRD host yeniden kurulmali' } else { 'CRD host kurulu degil' })
        return
    }
    $cfgPath = Get-CrdHostConfigPath
    $hostId = $null
    $registered = $false
    $readError = ''
    $hostIdFile = ''
    # host.json SYSTEM/Administrator ile kisitli olabilir: ayni klasordeki host_unprivileged.json normal kullanici icin okunabilir
    $crdCandidates = @($cfgPath)
    $crdDir = Split-Path -Parent $cfgPath
    if ($crdDir) { $crdCandidates += (Join-Path $crdDir 'host_unprivileged.json') }
    foreach ($cand in @($crdCandidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        try {
            $hid = (Get-Content -LiteralPath $cand -Raw -ErrorAction Stop | ConvertFrom-Json).host_id
            if ($hid) { $hostId = $hid; $registered = $true; $hostIdFile = $cand; break }
        } catch { if (-not $readError) { $readError = ($_.Exception.Message + ' [' + (Split-Path -Leaf $cand) + ']') } }
    }
    $ok = $true
    $repair = @()
    $detail = 'start=' + $svc.StartType + ', durum=' + $svc.Status
    if ($svc.Status -ne 'Running') {
        if ($cfg.FixCrd -and (Test-Admin) -and -not $Check) {
            try { Start-Service -Name 'chromoting' -ErrorAction Stop; (Get-Service -Name 'chromoting').WaitForStatus('Running', [TimeSpan]::FromSeconds(30)); $repair += 'servis baslatildi' }
            catch { $ok = $false; $repair += 'baslatilamadi: ' + $_.Exception.Message }
        } else { $ok = $false; $repair += 'servis durmus' }
    }
    $daemon = @(Get-CrdDaemon)
    $ageH = 0
    if ($daemon.Count -gt 0) { $ageH = ((Get-Date) - ($daemon | Sort-Object StartTime | Select-Object -First 1).StartTime).TotalHours }
    $conns = Get-CrdSignalConnections -Ports $cfg.CrdSignalPorts
    $detail = 'start=' + $svc.StartType + ', durum=' + $svc.Status + ', daemon=' + $daemon.Count + ', yas=' + [math]::Round($ageH, 1) + 'sa, host_id=' + $(if ($registered) { 'var' } else { 'YOK' }) + ', googleBaglanti=' + $conns
    if ($daemon.Count -eq 0) {
        $ok = $false
        if ($cfg.FixCrd -and (Test-Admin) -and -not $Check -and (Get-CrdActiveSession)) {
            try {
                Stop-Service -Name 'chromoting' -Force -ErrorAction SilentlyContinue
                Get-Process -Name 'remoting_host', 'remoting_start_host' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 2
                Start-Service -Name 'chromoting' -ErrorAction Stop
                $repair += 'daemon yeniden baslatildi'
            } catch { $repair += 'yeniden baslatma basarisiz: ' + $_.Exception.Message }
        } else {
            $repair += 'daemon yok'
        }
    } elseif ($registered -and $conns -eq 0) {
        $yeniSayac = [int](Get-State).CrdNoConnCycles + 1
        # CRD baglantisi olmamasi bir hata veya reboot nedeni degildir, sadece bos durum / sinyal bilgisi olarak kaydedilir
        $detail += ' (bosta veya baglanti yok)'
        if ($yeniSayac -ge [int]$cfg.CrdNoConnRestartCycles -and $cfg.FixCrd -and (Test-Admin) -and -not $Check -and -not (Get-CrdActiveSession)) {
            try {
                Stop-Service -Name 'chromoting' -Force -ErrorAction Stop
                Get-Process -Name 'remoting_host', 'remoting_start_host' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 2
                Start-Service -Name 'chromoting' -ErrorAction Stop
                $yeniSayac = 0
                $repair += 'uzun sure baglanti olmadi, chromoting servisi tazelendi'
            } catch { $repair += 'servis tazeleme basarisiz: ' + $_.Exception.Message }
        }
        $null = Invoke-StateUpdate { param($st) $st.CrdNoConnCycles = $yeniSayac }
    } else {
        $null = Invoke-StateUpdate { param($st) $st.CrdNoConnCycles = 0 }
        if ($cfg.CrdRestartAfterHours -gt 0 -and $ageH -gt [double]$cfg.CrdRestartAfterHours -and -not (Get-CrdActiveSession) -and -not $Check) {
            try { Stop-Service -Name 'chromoting' -Force -ErrorAction Stop; Start-Sleep 2; Start-Service -Name 'chromoting' -ErrorAction Stop; $repair += 'onleyici yeniden baslatma' } catch { }
        }
    }
    if ($cfg.ServiceAutoStart -and (Test-Admin) -and -not $Check -and $svc.StartType -ne 'Automatic') {
        try { Set-Service -Name 'chromoting' -StartupType Automatic; $repair += 'servis Automatic yapildi' } catch { }
    }
    if (-not $registered) { $ok = $false; $detail += ' -> cihaz Google listesinde gorunmez' }
    $m = [ordered]@{ servis = [string]$svc.Status; startType = [string]$svc.StartType; hostId = $(if ($registered) { 'var' } else { 'yok' }); hostIdFile = $(if ($hostIdFile) { Split-Path -Leaf $hostIdFile } else { '' }); googleBaglanti = $conns; daemon = $daemon.Count; yasSaat = [math]::Round($ageH, 1) }
    if (-not $registered) {
        $chrome = (Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe') -or (Test-Path 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe')
        if ($readError) {
            $repair = 'host.json ve host_unprivileged.json okunamadi (' + $readError + '). Yonetici olarak calistirip tekrar deneyin.'
            $m['readError'] = $readError
        } else {
            $repair = 'Cihaz Google hesabina kayitli degil (host.json ve host_unprivileged.json yok) ve bu yuzden CRD servisi calisamaz. Tek seferlik kurulum: bu makinede once Google Chrome kurun, sonra https://remotedesktop.google.com/headless adresinde "Set up remote access" deyip alinan PIN ile kendi cihazinizdan "+" ile ekleyin. Tarayicida acik olan Google oturumu bu kaydi olusturmaz.'
            if (-not $chrome) { $repair = 'Once Google Chrome kurulu degil (CRD host buna bagli), ardindan https://remotedesktop.google.com/headless -> "Set up remote access" ile cihazi kaydedin. Tarayicida acik olan Google oturumu bu kaydi olusturmaz.' }
        }
        $m['chromeInstalled'] = $chrome
        $m['setupRequired'] = $true
    }
    Add-Result 'CRD servisi' $ok $detail ($repair -join '; ') $false $m
}

function Test-Rdp {
    $cfg = $global:cfg
    $repair = @()
    $ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    $deny = $ts.fDenyTSConnections
    $ok = ($deny -eq 0)
    if (-not $ok -and $cfg.FixRdp -and (Test-Admin) -and -not $Check) {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
        $repair += 'fDenyTSConnections=0'
        $ok = $true
    }
    $rules = @(Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue | Sort-Object Name -Unique)
    $disabled = @($rules | Where-Object { $_.Enabled -ne 'True' })
    if ($disabled.Count -gt 0) {
        if ($cfg.FixRdp -and (Test-Admin) -and -not $Check) {
            foreach ($n in @($disabled | Select-Object -ExpandProperty Name -Unique)) { try { Enable-NetFirewallRule -Name $n -ErrorAction Stop } catch { } }
            $repair += "$($disabled.Count) firewall kurali acildi"
        } else { $ok = $false; $repair += "$($disabled.Count) firewall kurali kapali (admin gerekir)" }
    }
    foreach ($s in @('TermService', 'UmRdpService')) {
        $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $sv) { continue }
        if ($cfg.ServiceAutoStart -and (Test-Admin) -and -not $Check -and $sv.StartType -eq 'Manual') { try { Set-Service -Name $s -StartupType Automatic; $repair += ($s + ' Automatic') } catch { } }
        if ($sv.Status -ne 'Running') { if ((Test-Admin) -and -not $Check) { try { Start-Service -Name $s -ErrorAction Stop; $repair += ($s + ' baslatildi') } catch { } } }
    }
    $listening = $false
    try { $listening = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 3389 }).Count -gt 0 } catch { }
    Add-Result 'Windows RDP' $ok ('fDenyTSConnections=' + $deny + ', firewall kapali=' + $disabled.Count + ', 3389=' + $(if ($listening) { 'dinliyor' } else { 'yok' })) ($repair -join '; ')
}

function Test-ServerPower {
    $cfg = $global:cfg
    $repair = @()
    $standby = Get-PowerSettingAcIndex -AliasPath @('SUB_SLEEP', 'STANDBYIDLE')
    $hibIdle = Get-PowerSettingAcIndex -AliasPath @('SUB_SLEEP', 'HIBERNATEIDLE')
    $hibAfter = Get-PowerSettingAcIndex -AliasPath @('SUB_SLEEP', 'HIBERNATEAFTER')
    $disk = Get-PowerSettingAcIndex -AliasPath @('SUB_DISK', 'DISKIDLE')
    $ok = $true
    $detail = 'sleep=' + $(if ($null -eq $standby) { '?' } else { $standby }) + 's, hibIdle=' + $(if ($null -eq $hibIdle) { '?' } else { $hibIdle }) + 's, hibAfter=' + $(if ($null -eq $hibAfter) { '?' } else { $hibAfter }) + 's, disk=' + $(if ($null -eq $disk) { '?' } else { $disk }) + 's'
    $needFix = ($null -ne $standby -and $standby -ne 0) -or ($null -ne $hibIdle -and $hibIdle -ne 0) -or ($null -ne $hibAfter -and $hibAfter -ne 0) -or ($null -ne $disk -and $disk -ne 0)
    if ($needFix) {
        if ($cfg.ServerMode -and (Test-Admin) -and -not $Check) {
            powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
            powercfg /change standby-timeout-dc 0 2>&1 | Out-Null
            powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
            powercfg /change hibernate-timeout-dc 0 2>&1 | Out-Null
            powercfg /change disk-timeout-ac 0 2>&1 | Out-Null
            $repair += 'uyku/hibernasyon/disk zaman asimi kapatildi'
        } else { $ok = $false; $repair += 'uyku zaman asimlari acik (admin gerekir)' }
    }
    $fastStartup = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($cfg.DisableFastStartup -and $fastStartup -ne 0) {
        if ((Test-Admin) -and -not $Check) {
            try { powercfg /h off 2>&1 | Out-Null; Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -ErrorAction SilentlyContinue; $repair += 'Fast Startup kapatildi (powercfg /h off)' }
            catch { $ok = $false; $repair += 'Fast Startup kapatilamadi' }
        } else { $ok = $false; $repair += 'Fast Startup ACIK' }
    }
    $nicOff = @()
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
            if ($pm -and $pm.AllowComputerToTurnOffDevice -eq 'Enabled') { $nicOff += $a.Name }
        }
    } catch { }
    if ($nicOff.Count -gt 0) {
        if ($cfg.ServerMode -and (Test-Admin) -and -not $Check) {
            foreach ($n in $nicOff) { try { Set-NetAdapterPowerManagement -Name $n -AllowComputerToTurnOffDevice Disabled -WakeOnMagicPacket Enabled -ErrorAction Stop; $repair += ($n + ' guc yonetimi duzeltildi') } catch { } }
        } else { $ok = $false; $repair += 'NIC uyku acik: ' + ($nicOff -join ',') }
    }
    $onBattery = $false
    try { $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue; if ($bat) { $onBattery = ($bat.BatteryStatus -eq 1) } } catch { }
    if ($onBattery) { $ok = $false; $repair += 'CIKTAKILAR (pil) - sunucu modu icin AC besleme gerekli' }
    if (-not $cfg.ServerMode) {
        Write-Log 'INFO' 'ServerMode kapali (dizustu profili): uyku/hibernasyon ayarlarina dokunulmadi, kontrol atlandi'
        Add-Result 'Guc/uyku ayarlari' $true ($detail + ', fastStartup=' + $(if ($fastStartup) { 'acik' } else { 'kapali' })) 'ServerMode kapali - kontrol atlandi' $true
        return
    }
    Add-Result 'Guc/uyku ayarlari' $ok ($detail + ', fastStartup=' + $(if ($fastStartup) { 'acik' } else { 'kapali' }) + ', pil=' + $(if ($onBattery) { 'VAR/ciktaki' } else { 'yok' })) ($repair -join '; ')
}

function Test-ServiceRecovery {
    $cfg = $global:cfg
    if (-not $cfg.ServiceCrashRecovery -or -not (Test-Admin) -or $Check) { return }
    $repair = @()
    foreach ($s in @('chromoting', 'TermService')) {
        if (-not (Get-Service -Name $s -ErrorAction SilentlyContinue)) { continue }
        sc.exe failure $s actions= restart/5000/restart/15000/restart/60000 reset= 86400 2>&1 | Out-Null
        sc.exe failureflag $s 1 2>&1 | Out-Null
        $repair += $s
    }
    if ($repair.Count -gt 0) { Write-Log 'INFO' ('servis cokmeleri icin kendini yeniden baslatma etkin: ' + ($repair -join ', ')) }
}

function Test-Tunnel {
    $cfg = $global:cfg
    $codeCmd = Get-Command 'code' -ErrorAction SilentlyContinue
    if (-not $codeCmd) { Add-Result 'VS Code Tunnel' $true 'code CLI yok' '' $true; return }
    $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match 'tunnel' -and $_.CommandLine -match 'code' })
    $running = $procs.Count -gt 0
    if ($running) { Add-Result 'VS Code Tunnel' $true ('surec=' + $procs.Count) ''; return }
    if (-not $cfg.TunnelRepair) {
        Add-Result 'VS Code Tunnel' $true 'tunnel izlenmiyor (istege bagli, kapali)' 'Ayarlar > VS CODE TUNNEL > "Tunnel yoksa yeniden baslat" kapali oldugu icin atlandi' $true
        return
    }
    $ok = $false
    $repair = 'calisan tunnel yok'
    if (-not $Check) {
        if ([Environment]::UserInteractive) {
            Start-Process -FilePath $codeCmd.Source -ArgumentList @('tunnel', '--name', $cfg.TunnelName) -ErrorAction SilentlyContinue
            $repair = 'code tunnel baslatildi'
            $ok = $true
        } else { $repair = 'tunnel yok; SYSTEM altinda baslatilamaz' }
    }
    Add-Result 'VS Code Tunnel' $ok ('surec=' + $procs.Count) $repair
}

function Send-Heartbeat {
    param([bool]$Ok, [string]$Summary)
    $cfg = $global:cfg
    if (-not $cfg.HeartbeatUrl) { return }
    $url = $cfg.HeartbeatUrl
    if (-not $Ok) { $url = $url.TrimEnd('/') + $cfg.HeartbeatFailPath }
    $payload = [pscustomobject]@{
        host = $env:COMPUTERNAME
        time = (Get-Date).ToString('s')
        ok = $Ok
        public_ip = $script:PublicIp
        uptime_min = (Get-UptimeMinutes)
        summary = $Summary
        checks = $script:Results
    } | ConvertTo-Json -Depth 5
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Log 'INFO' ('heartbeat OK (' + $r.StatusCode + ') -> ' + $url)
    } catch { Write-Log 'WARN' ('heartbeat basarisiz: ' + $_.Exception.Message) }
}

function Send-Telegram {
    param([string]$Text)
    $cfg = $global:cfg
    if (-not $cfg.TelegramToken -or -not $cfg.TelegramChatId) { return }
    try {
        Invoke-RestMethod -Method Post -Uri ('https://api.telegram.org/bot' + $cfg.TelegramToken + '/sendMessage') -Body @{ chat_id = $cfg.TelegramChatId; text = $Text } -TimeoutSec 15 -ErrorAction Stop | Out-Null
    } catch { Write-Log 'WARN' ('telegram gonderilemedi: ' + $_.Exception.Message) }
}

function Invoke-Alerts {
    param([bool]$AllOk, [string]$Summary)
    $cfg = $global:cfg
    $now = Get-Date
    $bad = @($script:Results | Where-Object { -not $_.Ok -and -not $_.Skipped })
    $key = if ($AllOk) { 'OK' } else { (($bad | ForEach-Object { $_.Name }) -join '|') }
    $sonuc = [ordered]@{ Send = $false; Recovered = $false }
    $null = Invoke-StateUpdate {
        param($st)
        $sonuc.Send = $false
        if ($st.AlertKey -ne $key) {
            $sonuc.Send = $true
            $sonuc.Recovered = ($key -eq 'OK' -and $st.AlertKey -ne '' -and $st.AlertKey -ne 'OK')
        } elseif ($st.AlertUtc) {
            try {
                $last = [datetime]::Parse([string]$st.AlertUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                if (($now - $last).TotalHours -ge [double]$cfg.AlertRepeatHours) { $sonuc.Send = $true }
            } catch { }
        }
        if ($sonuc.Send) {
            $st.AlertKey = $key
            $st.AlertUtc = $now.ToString('o')
            if ($key -eq 'OK') { $st.LastOkUtc = $now.ToString('o') }
        }
    }
    if ($sonuc.Send) {
        $head = if ($sonuc.Recovered) { '[DUZELDI] ' } elseif ($key -eq 'OK') { '[BİLGİ] ' } else { '[UYARI] ' }
        $text = $head + $env:COMPUTERNAME + ' | ' + $Summary
        Write-Log 'ALERT' $text
        Send-Telegram $text
    }
}

function Get-HolidayList {
    $cfg = $global:cfg
    $list = @()
    foreach ($d in @($cfg.Holidays)) {
        if ($null -ne $d -and ([string]$d).Trim() -ne '') { $list += ([string]$d).Trim() }
    }
    $file = [string]$cfg.HolidaysFile
    if ([string]::IsNullOrEmpty($file)) { $file = Join-Path (Split-Path -Parent $ScriptPath) 'holidays.txt' }
    if (Test-Path -LiteralPath $file) {
        foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            $t = ([string]$line).Trim()
            if ($t -and -not $t.StartsWith('#')) { $list += $t }
        }
    }
    return @($list | Sort-Object -Unique)
}

function Test-IsHoliday {
    param([datetime]$At = (Get-Date))
    $cfg = $global:cfg
    if ([string]$cfg.HolidayMode -eq 'none') { return $false }
    return (@(Get-HolidayList) -contains $At.ToString('yyyy-MM-dd'))
}

function Add-HolidayToFile {
    param([string[]]$Dates)
    $cfg = $global:cfg
    $file = [string]$cfg.HolidaysFile
    if ([string]::IsNullOrEmpty($file)) { $file = Join-Path (Split-Path -Parent $ScriptPath) 'holidays.txt' }
    $existing = @()
    if (Test-Path -LiteralPath $file) { $existing = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue) }
    foreach ($d in $Dates) {
        $t = $d.Trim()
        if ($t -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host ('Hatali tarih (YYYY-AA-GG olmali): ' + $d) -ForegroundColor Red; continue }
        if ($existing -notcontains $t) { $existing += $t; Write-Host ('Eklendi: ' + $t) }
    }
    try {
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -LiteralPath $file -Value (@('# RemoteWatchdog tatil listesi - her satir YYYY-AA-GG') + ($existing | Where-Object { $_ })) -Encoding UTF8
        Write-Host ('Dosya: ' + $file)
    } catch { Write-Host ('Yazilamadi (yonetici yetkisi gerekebilir): ' + $_.Exception.Message) -ForegroundColor Red }
}

function Remove-HolidayFromFile {
    param([string[]]$Dates)
    $cfg = $global:cfg
    $file = [string]$cfg.HolidaysFile
    if ([string]::IsNullOrEmpty($file)) { $file = Join-Path (Split-Path -Parent $ScriptPath) 'holidays.txt' }
    if (-not (Test-Path -LiteralPath $file)) { Write-Host 'Tatil dosyasi yok'; return }
    $existing = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue | Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($d in $Dates) {
        $t = $d.Trim()
        if ($existing -contains $t) { $existing = @($existing | Where-Object { $_ -ne $t }); Write-Host ('Silindi: ' + $t) } else { Write-Host ('Bulunamadi: ' + $t) }
    }
    Set-Content -LiteralPath $file -Value (@('# RemoteWatchdog tatil listesi - her satir YYYY-AA-GG') + $existing) -Encoding UTF8
}

function ConvertTo-DotNetDays {
    param($Spec)
    $map = @{
        'pzt' = 1; 'pazartesi' = 1; 'mon' = 1; 'monday' = 1
        'sal' = 2; 'sali' = 2; 'tue' = 2; 'tuesday' = 2
        'car' = 3; 'carsamba' = 3; 'wed' = 3; 'wednesday' = 3
        'per' = 4; 'persembe' = 4; 'thu' = 4; 'thursday' = 4
        'cum' = 5; 'cuma' = 5; 'fri' = 5; 'friday' = 5
        'cmt' = 6; 'cumartesi' = 6; 'sat' = 6; 'saturday' = 6
        'paz' = 0; 'pazar' = 0; 'sun' = 0; 'sunday' = 0
    }
    $out = @()
    foreach ($s in @($Spec)) {
        if ($null -eq $s -or ([string]$s).Trim() -eq '') { continue }
        $t = ([string]$s).Trim().ToLowerInvariant()
        if ($t -match '^\d+$') { $out += [int]$t; continue }
        if ($map.ContainsKey($t)) { $out += $map[$t]; continue }
        Write-Log 'WARN' ('bilinmeyen gun tanimi yok sayildi: ' + $s + ' (ornek: Pzt, Sal, Car, Per, Cum, Cmt, Paz)')
    }
    return @($out | Sort-Object -Unique)
}

function Test-InBlackout {
    param([datetime]$At = (Get-Date))
    $cfg = $global:cfg
    $forceUntil = $null
    if ($cfg.ForceRestartUntil) { try { $forceUntil = [datetime]::Parse([string]$cfg.ForceRestartUntil, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { } }
    $forceActive = [bool]$cfg.ForceRestartAlways -and (($null -eq $forceUntil) -or ($forceUntil -gt $At))
    if ($forceActive) { return $true }
    if ($null -ne $forceUntil -and $forceUntil -le $At -and [bool]$cfg.ForceRestartAlways) { Write-Log 'INFO' ('daima zorla kapatma suresi doldu (' + $forceUntil.ToString('yyyy-MM-dd HH:mm') + '); normal blackoutu kuralina donuluyor') }
    if (-not $cfg.BlackoutEnabled) { return $true }
    $dow = [int]$At.DayOfWeek
    $h = $At.Hour + ($At.Minute / 60.0)
    $fullDays = ConvertTo-DotNetDays $cfg.BlackoutFullDays
    $nights = ConvertTo-DotNetDays $cfg.BlackoutNights
    if ($fullDays -contains $dow) { return $true }
    if (Test-IsHoliday -At $At) {
        $mode = ([string]$cfg.HolidayMode).ToLowerInvariant()
        if ($mode -eq 'full') { return $true }
        Write-Log 'INFO' ($At.ToString('yyyy-MM-dd') + ' resmi/dini tatil, normal mesai kurali uygulandi')
    }
    $s = [double]$cfg.BlackoutStart
    $e = [double]$cfg.BlackoutEnd
    if ($e -gt $s) { return ($nights -contains $dow -and $h -ge $s -and $h -lt $e) }
    $prevDow = ($dow + 6) % 7
    if ($nights -contains $dow -and $h -ge $s) { return $true }
    if ($nights -contains $prevDow -and $h -lt $e) { return $true }
    return $false
}

function Write-VoicePending {
    <#
        Panelin okuyup KONUSACAGI bekleyen anonsu yazar.
        BIRIKIM ENGELI: ayni metin dosyada 10 dk'dan tazeyse YENIDEN YAZILMAZ. Onceki
        surumde her dongude ayni dosya ezildigi icin panel ayni cumleyi arka arkaya
        kuyruga alip tekrar tekrar konusuyordu.
    #>
    param([string]$Text, [string]$Sfx = 'ok', [string]$VoiceKey = '')
    $f = Join-Path $BaseDir 'pending-voice.json'
    try {
        if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
        if (Test-Path -LiteralPath $f) {
            try {
                $eski = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($eski -and ([string]$eski.text -eq [string]$Text)) {
                    $yas = 999
                    try { $yas = ((Get-Date) - [datetime]::Parse([string]$eski.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes } catch { }
                    if ($yas -lt 10) { return $false }
                }
            } catch { }
        }
        ([ordered]@{ text = [string]$Text; sfx = [string]$Sfx; voiceKey = [string]$VoiceKey; at = (Get-Date).ToString('o') } | ConvertTo-Json) |
            Set-Content -LiteralPath $f -Encoding UTF8
        return $true
    } catch { Write-Log 'WARN' ('bekleyen anons dosyasi yazilamadi: ' + $_.Exception.Message); return $false }
}

function Write-RebootAnnounce {
    <#
        Restart ONCESI sesli/ekran anonsu. Iki kanaldan birden gider:
          1) pending-voice.json -> panel dosyayi okuyup TURKCE KONUSUR (kullanici duyar).
             Panel acik degilse dosya kalir; panel acilinca 30 dk'ya kadar konusur.
          2) msg.exe + Telegram -> ekran/telefon bildirimi.
        Amac: kullanici bilgisayarin kendiliginden kapanacagini ANLASIN.
        ZAMANLAMA: ayni anons 10 dk icinde TEKRAR EDILMEZ (LastRebootAnnounceUtc), boylece
        art arda gelen denemelerde kutu/ses birikmez; gerekirse 10 dk sonra yeniden soylenir.
        -VoiceKey verilirse panel onbellekteki hazir kadin sesli dosyayi calar.
    #>
    param(
        [string]$Text = 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.',
        [int]$CountdownSeconds = 60,
        [switch]$Force,
        [string]$VoiceKey = ''
    )
    if (-not $Force) {
        <#  DİKKAT: scriptblock icinde $gonder = $false yazmak cocuk kapsamda kalir ve
            ana akisi ETKILEMEZ (kisiT calismaz). Bu yuzden sonucu bir OrderedDictionary
            ile tasiyoruz; eski kodda 1 saatlik kisit bu yuzden hic uygulanmiyordu. #>
        $kisit = [ordered]@{ Gonder = $true; BekleDk = 0 }
        $null = Invoke-StateUpdate {
            param($st)
            if ($st.LastRebootAnnounceUtc) {
                try {
                    $son = [datetime]::Parse([string]$st.LastRebootAnnounceUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    $fark = ((Get-Date) - $son).TotalMinutes
                    if ($fark -lt 10) { $kisit.Gonder = $false; $kisit.BekleDk = [int][math]::Round(10 - $fark) }
                } catch { }
            }
            if ($kisit.Gonder) { $st.LastRebootAnnounceUtc = (Get-Date).ToString('o') }
        }
        if (-not $kisit.Gonder) {
            Write-Log 'INFO' ('restart anonsu bastan sona gonderildi, ayni anons icin tekrar icin ' + $kisit.BekleDk + ' dk')
            return $false
        }
    }
    $kalan = [math]::Max(0, [int]$CountdownSeconds)
    $metin = $Text
    if ($kalan -gt 0) { $metin += (' ' + $kalan + ' saniye içinde.') }
    $metin += ' Açık belgeler varsa kaydediliyor.'
    Write-Log 'ALERT' ('RESTART ANNOSU: ' + $metin)
    # voiceKey: onbellekteki kadin sesli varyant.
    <#
        Geri sayim suresi ayardan gelir (10/30/45/60 sn...) ama onbellekte YALNIZCA
        60/30/10 klipleri vardir. Anahtar tam denk gelmezse sesli anons internetsiz makinede
        sessizce kaliyordu (edge-tts calismaz, Turkce SAPI yok). Bu yuzden en YAKIN hazir
        sure secilir: gercek kapanma suresi degismez, sadece anons metni yuvarlanir.
    #>
    $vkey = $VoiceKey
    if (-not $vkey) {
        <#  Yuvarlama KISAYA dogru: "45 saniye icinde" derken 30/60 demekten iyidir, cunku
            makine soylendiginden ERKEN kapanir (kullanici "60 dedi, 30'da kapandi" yaşamaz). #>
        if ($kalan -ge 46) { $vkey = 'reboot60'; $hazirSn = 60 }
        elseif ($kalan -ge 21) { $vkey = 'reboot30'; $hazirSn = 30 }
        elseif ($kalan -ge 1) { $vkey = 'reboot10'; $hazirSn = 10 }
        else { $vkey = 'rebootplan'; $hazirSn = 0 }
        if ($kalan -gt 0 -and $kalan -ne $hazirSn) {
            Write-Log 'INFO' ('geri sayim ' + $kalan + ' sn icin hazir ' + $vkey + ' sesi kullanilacak (once uretilmis klipler 60/30/10 sn)')
        }
    }
    # 1) Panel icin bekleyen anons (dosya; panel okuyup konusur)
    $null = Write-VoicePending -Text $metin -Sfx 'reboot' -VoiceKey $vkey
    # 2) Ekran + Telegram
    Show-ScreenMessage -Text $metin
    try { Send-Telegram ('[KRITIK] ' + $env:COMPUTERNAME + ': ' + $metin) } catch { }
    return $true
}

function Show-ScreenMessage {
    <#
        Ekran mesaj kutusu (msg.exe). Ayarlardan KAPATILABILIR (config: EkranMesaji).
        Neden ayri fonksiyon: bu cagri uc yerde (restart anonsu, kullanici bildirimi, anlik
        ag sorunu) tekrarlaniyordu ve hepsi tek bir anahtardan yonetilmiyordu; kullanici
        "mesaj kutularini istemiyorum" dediginde tumunu kapatabilmek gerekiyor.
        Sesli anons (SesliBildirim) ve Telegram bu anahtardan BAGIMSIZ calismaya devam eder.
    #>
    param([string]$Text, [int]$Seconds = 600)
    <#  DİKKAT: Get-Config bir OrderedDictionary döner; onun anahtarları .PSObject.Properties
        ile GÖRÜNMEZ (o üyeler adapter üyeleridir). Bu yüzden IDictionary ise Contains, aksi
        halde PSObject.Properties kullanılır; ilk sürümde kapı bu yüzden hiç çalışmıyordu. #>
    $ekran = $true
    if ($null -ne $global:cfg) {
        $v = $null
        if ($global:cfg -is [System.Collections.IDictionary]) {
            if ($global:cfg.Contains('EkranMesaji')) { $v = $global:cfg['EkranMesaji'] }
        } elseif (@($global:cfg.PSObject.Properties.Name) -contains 'EkranMesaji') {
            $v = $global:cfg.EkranMesaji
        }
        if ($null -ne $v) { $ekran = [bool]$v }
    }
    if (-not $ekran) { return $false }
    try { msg.exe * /TIME:$Seconds ('[' + $env:COMPUTERNAME + '] ' + $Text) 2>&1 | Out-Null; return $true } catch { return $false }
}

function Send-UserNotification {
    param([string]$Text, [string]$Title = 'Uzak Makine Uyarisi', [string]$Key = '')
    $cfg = $global:cfg
    <#
        ANAHTAR BAZLI KISIT: ayni konu icin mesaj NotifyRepeatHours icinde bir kez gider.
        Onceki surumde throttle calismiyordu (bkz. Invoke-StateUpdate aciklamasi) ve ayni
        uyari 8 saat boyunca 276 kez basildi. FARKLI bir konu (yeni hata turu) hicbir zaman
        bastirilmaz - yalnizca ayni mesaj tekrarlanmaz.
    #>
    if (-not $Key) { $Key = $Title }
    $repeat = [double]$cfg.NotifyRepeatHours
    $sonuc = [ordered]@{ Gonder = $true; BekleDk = 0 }
    $null = Invoke-StateUpdate {
        param($st)
        if (([string]$st.LastNotifyKey -eq [string]$Key) -and $st.LastUserNotifyUtc) {
            try {
                $fark = ((Get-Date) - [datetime]::Parse([string]$st.LastUserNotifyUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalHours
                if ($fark -lt $repeat) { $sonuc.Gonder = $false; $sonuc.BekleDk = [int][math]::Round(($repeat - $fark) * 60) }
            } catch { }
        }
        if ($sonuc.Gonder) {
            $st.LastNotifyKey = [string]$Key
            $st.LastUserNotifyUtc = (Get-Date).ToString('o')
        }
    }
    if (-not $sonuc.Gonder) {
        Write-Log 'INFO' ('kullanici bildirimi bastan sona gonderildi (ayni konu: ' + $Title + '), tekrar icin ' + $sonuc.BekleDk + ' dk')
        return $false
    }
    Write-Log 'ALERT' ('KULLANICI BILDIRIMI: ' + $Text)
    Send-Telegram ('[BILDIRIM] ' + $env:COMPUTERNAME + ' - ' + $Title + ': ' + $Text)
    if (Show-ScreenMessage -Text ($Title + ': ' + $Text)) { Write-Log 'INFO' 'ekran bildirimi gosterildi (msg.exe, 10 dk)' }
    return $true
}

function Stop-OfficeForced {
    $killed = @()
    foreach ($p in @('WINWORD', 'EXCEL', 'POWERPNT')) {
        $procs = @(Get-Process -Name $p -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $killed += ($p + ' x' + $procs.Count)
        }
    }
    if ($killed.Count -gt 0) { Start-Sleep -Seconds 5 }
    return $killed
}

function Request-OfficeSave {
    param([int]$TimeoutSeconds)
    $cfg = $global:cfg
    $tempDir = $env:windir + '\Temp'
    $requestFile = Join-Path $tempDir 'RemoteWatchdog-reboot.flag'
    $resultFile = Join-Path $tempDir 'RemoteWatchdog-office-result.txt'
    $saver = Join-Path (Split-Path -Parent $ScriptPath) 'Protect-OpenDocuments.ps1'
    if (-not $cfg.OfficeSaveBeforeReboot) { return $true }
    if (Test-InBlackout) {
        $killed = Stop-OfficeForced
        $msg = 'blackout saatleri (' + (Get-Date).ToString('dddd HH:mm') + '): zorla yeniden baslatma' + $(if ($killed.Count) { ' - kapatilan: ' + ($killed -join ', ') + ' (kaydedilmemiş belge olabilir)' } else { ' - acik ofis uygulamasi yok' })
        Write-Log 'ALERT' $msg
        Send-Telegram ('[UYARI] ' + $env:COMPUTERNAME + ' ' + $msg)
        return $true
    }
    if (-not (Test-Path -LiteralPath $saver)) { Write-Log 'WARN' ('belge kaydetme betigi bulunamadi: ' + $saver); return $true }
    $stateFile = Join-Path $tempDir 'RemoteWatchdog-docs.json'
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $ds = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ([int]$ds.unsaved -gt 0) {
                Write-Log 'ALERT' ('belge koruyucu ' + $ds.unsaved + ' kaydedilmemiş belge bildiriyor (' + ((@($ds.names)) -join ', ') + '); reboot yapilmiyor')
                if ([bool]$cfg.OfficeAbortRebootIfUnsaved) { return $false }
            }
        } catch { }
    }
    $officeRunning = @(Get-Process -Name 'WINWORD', 'EXCEL' -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $officeRunning) { Write-Log 'INFO' 'Word/Excel sistemde calismiyor, kaydedilecek belge yok - beklemeden devam'; return $true }
    try { Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue } catch { }
    Set-Content -LiteralPath $requestFile -Value ((Get-Date).ToString('o')) -Encoding UTF8
    Write-Log 'ALERT' ('yeniden baslatma oncesi Word/Excel kaydetme istegi yazildi; ' + $TimeoutSeconds + ' sn bekleniyor')
    $waited = 0
    $done = $false
    $cleared = $false
    while ($waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 5
        $waited += 5
        $done = $false
        if (Test-Path -LiteralPath $resultFile) {
            $txt = ''
            try { $txt = Get-Content -LiteralPath $resultFile -Raw } catch { }
            if ($txt -match 'TIMEOUT|HATA') { $done = $true; $cleared = $false; Write-Log 'ERR' ('belge kaydetme sonucu: ' + $txt.Trim()) }
            elseif ($txt.Trim()) { $done = $true; $cleared = $true; Write-Log 'INFO' ('belge kaydetme sonucu: ' + ($txt.Trim() -replace "`r?`n", ' | ')) }
        }
        if ($done) { break }
    }
    try { Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue } catch { }
    if (-not $done -and $waited -ge $TimeoutSeconds) {
        Write-Log 'ERR' ('belge kaydetme zaman asimina ugradi (' + $TimeoutSeconds + ' sn); Word/Excel acik olabilir')
        return (-not [bool]$cfg.OfficeAbortRebootIfStillOpen)
    }
    return $cleared
}

function Get-RebootBudget {
    param($State, [datetime]$Now = (Get-Date))
    $cfg = $global:cfg
    $list = @()
    if ($State -and $State.PSObject.Properties.Name -contains 'RebootsUtc') {
        foreach ($r in @($State.RebootsUtc)) {
            if (-not $r) { continue }
            try { $list += [datetime]::Parse([string]$r, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
        }
    }
    $cutoff = $Now.AddHours(-24)
    $recent = @($list | Where-Object { $_ -gt $cutoff } | Sort-Object)
    $max = [int]$cfg.MaxRestartsPerDay
    $cooldown = [double]$cfg.RebootCooldownMinutes
    $lastGap = [double]::MaxValue
    if ($recent.Count -gt 0) { $lastGap = ($Now - $recent[-1]).TotalMinutes }
    return [pscustomobject]@{
        Count24h = $recent.Count
        Max = $max
        LastUtc = $(if ($recent.Count -gt 0) { $recent[-1] } else { $null })
        MinutesSinceLast = $lastGap
        CooldownMinutes = $cooldown
        BudgetExhausted = ($max -gt 0 -and $recent.Count -ge $max)
        InCooldown = ($cooldown -gt 0 -and $lastGap -lt $cooldown)
    }
}

function Get-RebootDecision {
    param($State, [datetime]$Now = (Get-Date), [string[]]$BadNames = @())
    $cfg = $global:cfg
    $b = Get-RebootBudget -State $State -Now $Now
    if ($b.BudgetExhausted) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'daily-budget'; Text = ('24 saat icinde ' + $b.Count24h + ' restart yapildi (sinir ' + $b.Max + '); otomatik restart durduruldu, elle mudahale gerek'); Budget = $b }
    }
    if ($b.InCooldown) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'cooldown'; Text = ('son restartan ' + [math]::Round($b.MinutesSinceLast) + ' dk oldu, bekleme suresi ' + $b.CooldownMinutes + ' dk'); Budget = $b }
    }
    $policy = [string]$cfg.RestartPolicy
    if ($policy -eq 'never') { return [pscustomobject]@{ Allowed = $false; Reason = 'policy-never'; Text = 'RestartPolicy = never'; Budget = $b } }
    if ($policy -eq 'blackout' -and -not (Test-InBlackout -At $Now)) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'outside-blackout'; Text = 'blackout penceresi disinda restart yapilmaz, sadece bilgilendirilir'; Budget = $b }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = 'ok'; Text = ('siyaha girildi; 24 saatte ' + $b.Count24h + '/' + $b.Max + ' restart kullanildi'); Budget = $b }
}

function Get-BootStamp {
    <#
        Makinin GERCEK acilis zamani (ISO). Bir restart'in olup olmadiginin tek
        guvenilir kaniti budur; "restart istedim" degil, "makine yeniden acildi".
    #>
    try {
        $b = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if ($b) { return $b.ToUniversalTime().ToString('o') }
    } catch { }
    return ''
}

function Sync-RebootAccounting {
    <#
        Restart BUTCESINI gercekle mutabakat eder. Sorun: butce "restart istendi" aninda
        artiyordu; shutdown.exe sessizce basarisiz olsa ya da surec geri sayimda kaybolsa
        bile kayit kaliyordu. Uc sahte kayit -> 24 saatlik butce tukendi -> gercek bir
        kesintide sistem hicbir sey yapamaz hale geliyordu (gercekte hic restart olmamisti).
        Simdi: restart istendiginde PendingRebootUtc damgalanir, sonraki dongude
          - acilis zamani DEGISTIYSE  -> gercek restart, butceye yazilir
          - acilis zamani ayni KALIYORSA -> sahte istem, kayit SILINIR, butceye yazilmaz
    #>
    $boot = Get-BootStamp
    if (-not $boot) { return (Get-State) }
    return Invoke-StateUpdate {
        param($st)
        if (-not $st.LastBootUtc) { $st.LastBootUtc = $boot; return }
        if ($st.LastBootUtc -ne $boot) {
            $gercek = [string]$st.PendingRebootUtc
            $liste = @(@($st.RebootsUtc) | Where-Object { $_ })
            if ($gercek -and ($liste -notcontains $gercek)) { $liste += $gercek }
            $st.RebootsUtc = @($liste)
            $st.PendingRebootUtc = ''
            $st.LastBootUtc = $boot
            $st.ConsecutiveFailures = 0
            $st.BreakerKey = ''
            Write-Log 'INFO' ('makine yeniden acildi; restart butceye yazildi (' + $liste.Count + '/' + $cfg.MaxRestartsPerDay + ') | acilis=' + $boot)
            return
        }
        if ($st.PendingRebootUtc) {
            $sahte = [string]$st.PendingRebootUtc
            $st.RebootsUtc = @(@($st.RebootsUtc) | Where-Object { $_ -and ([string]$_ -ne $sahte) })
            $st.PendingRebootUtc = ''
            Write-Log 'WARN' ('restart GERCEKLESMEDI (acilis zamani degismedi, shutdown reddedilmis olabilir); sahte butce kaydi temizlendi')
        }
    }
}

function Confirm-Reboot {
    <#
        Restart'i GERCEKTE yaptirir ve bunu loglar.
        Neden: shutdown.exe tek basina bazen sessizce basarisiz olur (yetki, servis, baska
        bir kapatma islemi). Onceki surumde cikis kodu atiliyordu ("2>&1 | Out-Null"),
        boylece "restart oldu" denilen ama hic olmayan durumlar olusuyordu.
        Sirasiyla denenir: shutdown.exe -> WMI Reboot -> Restart-Computer.
    #>
    $secilen = ''
    try {
        # /t 5: log ve durum dosyasinin yazilmasi icin kucuk bir pay (gorunmez), /f yok:
        # belgeler zaten kaydedildi, uygulamalari zorla kapatmayiz.
        $p = Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r', '/t', '5', '/c', 'RemoteHostWatchdog: onarilamayan baglanti sorunu') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($p.ExitCode -eq 0) { $secilen = 'shutdown.exe' }
        else { Write-Log 'WARN' ('shutdown.exe basarisiz (cikis kodu ' + $p.ExitCode + '); yedek yontem deneniyor') }
    } catch { Write-Log 'WARN' ('shutdown.exe calistirilamadi: ' + $_.Exception.Message + '; yedek yontem deneniyor') }
    if (-not $secilen) {
        try { Invoke-CimMethod -ClassName Win32_OperatingSystem -MethodName Reboot -ErrorAction Stop | Out-Null; $secilen = 'WMI Reboot' }
        catch { Write-Log 'WARN' ('WMI Reboot basarisiz: ' + $_.Exception.Message) }
    }
    if (-not $secilen) {
        try { Restart-Computer -Force -ErrorAction Stop; $secilen = 'Restart-Computer' }
        catch { Write-Log 'WARN' ('Restart-Computer basarisiz: ' + $_.Exception.Message) }
    }
    if ($secilen) { Write-Log 'ALERT' ('yeniden başlatma Windows''a iletildi (' + $secilen + '); 5 sn içinde kapanacak') }
    else { Write-Log 'ERR' 'yeniden başlatma HICBIR YONTEMLE baslatilamadi; elle mudahale gerekli' }
    return [bool]$secilen
}

function Test-RecoveryBeforeReboot {
    <#
        Yeniden baslatma TETIKLENMEDEN once son bir taze kontrol.
        Gerekce: adaptor elle kapatilip geri acildiginda (veya kablo cekilip geri takildiginda)
        ag saniyeler icinde toparlanir, ama dongu bunu gormeden karar verir ve kullanici
        "ben adaptoru geri actim ama yine de restart etti" durumunda kalir.
        Iki deneme yapilir; ikisi de basariliysa RESTART IPTAL EDILIR.
        DETERMINISTIK: Invoke-Probe yerine Test-InternetFast (sert zaman asimli soket
        kontrolu) kullanilir; DNS takilip kaldiginda onceki surumde bu kontrol donguyu
        olduruyor, shutdown.exe hic cagrilmiyordu.
    #>
    <#
        Yeniden baslatma TETIKLENMEDEN once son bir taze kontrol.
        Gerekce: adaptor elle kapatilip geri acildiginda (veya kablo cekilip geri takildiginda)
        ag saniyeler icinde toparlanir, ama dongu bunu gormeden karar verir ve kullanici
        "ben adaptoru geri actim ama yine de restart etti" durumunda kalir.

        HIZ: bu kontrol karar ile restart arasindaki SON beklemedir; asagida agda her hedef
        kendi zaman asimini bekledigi icin 3 hedef x 4 sn x 2 deneme = ~16 sn yiyordu. Artik
        TEK hedef (1.1.1.1) ve kisa zaman asimi (1.2 sn) ile iki deneme, arada 1 sn => kotu
        yolda en fazla ~3.5 sn. Burada "internet geri geldi mi" sorusunu yanitlamak yeterli;
        asil teshis zaten tam dongude yapildi.
    #>
    for ($deneme = 1; $deneme -le 2; $deneme++) {
        if ((Get-TcpMs -HostName '1.1.1.1' -Port 443 -TimeoutMs 1200) -ge 0) {
            Write-Log 'INFO' ('restart iptal: yeniden baslatma oncesi taze kontrolde internet SAGLIKLI (deneme ' + $deneme + ') - adaptor geri acilmis, restart yapilmadi')
            return $true
        }
        if ($deneme -lt 2) { Start-Sleep -Seconds 1 }
    }
    Write-Log 'INFO' 'restart oncesi taze kontrol de basarisiz (internet hala kopuk) - restart devam ediyor'
    return $false
}

function Invoke-RebootIfNeeded {
    param([bool]$AllOk)
    $cfg = $global:cfg
    if ($Check) { Write-Log 'INFO' 'rapor modu (-Check): yeniden baslatma degerlendirmesi ve durum sayaci degistirilmedi'; return }
    $null = Sync-RebootAccounting
    if ($AllOk) {
        $null = Invoke-StateUpdate {
            param($st)
            $st.ConsecutiveFailures = 0
            $st.NetResetPendingReboot = 0
            $st.OutageStartUtc = ''
            $st.BreakerKey = ''
            if ($st.LastHealthyUtc) {
                try {
                    $lh = [datetime]::Parse([string]$st.LastHealthyUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    if (((Get-Date) - $lh).TotalMinutes -ge [double]$cfg.HealthyMinutesToReset) {
                        if (@($st.RebootsUtc).Count -gt 0) { Write-Log 'INFO' ('uzun sure saglikli kaldi, restart butcesi sifirlandi (' + [int]$cfg.HealthyMinutesToReset + ' dk)') }
                        $st.RebootsUtc = @()
                    }
                } catch { }
            } else { $st.LastHealthyUtc = (Get-Date).ToString('o') }
            $st.LastOkUtc = (Get-Date).ToString('o')
        }
        return
    }
    $bad = @($script:Results | Where-Object { -not $_.Ok -and -not $_.Skipped })
    $unregistered = @($bad | Where-Object { $_.Name -eq 'CRD servisi' -and $_.Detail -match 'host_id=YOK' }).Count -gt 0
    $onlyUnregistered = $unregistered -and ($bad | Where-Object { $_.Name -ne 'CRD servisi' }).Count -eq 0
    if ($onlyUnregistered -and $cfg.RebootSkipIfUnregistered) {
        Write-Log 'INFO' 'yeniden baslatma atlandi: host.json yok, restart ile duzelmez (host yeniden kaydedilmeli)'
        return
    }
    $rebootable = @($bad | Where-Object { $RebootableProblems -contains $_.Name }).Count -gt 0
    if (-not $rebootable) { return }
    $state = Invoke-StateUpdate {
        param($st)
        $st.ConsecutiveFailures = [int]$st.ConsecutiveFailures + 1
        if (-not $st.OutageStartUtc) { $st.OutageStartUtc = (Get-Date).ToString('o') }
    }
    $limit = [int]$cfg.RebootAfterFailedCycles
    if ([int]$state.NetResetPendingReboot -eq 1) { $limit = [math]::Min($limit, 1); Write-Log 'INFO' 'winsock/IP reset uygulanmisti, etkisi icin yeniden baslatma bir sonraki dongude yapilacak' }
    Write-Log 'INFO' ('basarisiz dongu ' + $state.ConsecutiveFailures + '/' + $limit)
    if ($limit -le 0 -or $state.ConsecutiveFailures -lt $limit) { return }
    $uptime = Get-UptimeMinutes
    if ($uptime -lt [int]$cfg.MinUptimeMinutes) {
        Write-Log 'INFO' ('restart ertelendi: makine sadece ' + $uptime + ' dk acik (esik ' + [int]$cfg.MinUptimeMinutes + ' dk)')
        return
    }
    <#
        KESINTI SURESI ESIGI: canli yoklamalar her dakika calistigi icin 2 saniyelik bir
        kopyalanma bile "1/1 basarisiz dongu" sayilip restart karari uretiyordu. Onarim
        gercekten denenmis ve kesinti MinOutageMinutes kadar surmus olmali.
    #>
    $minKesinti = [int]$cfg.MinOutageMinutes
    if ($minKesinti -gt 0) {
        $kesintiDk = 0
        try { $kesintiDk = ((Get-Date) - [datetime]::Parse([string]$state.OutageStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes } catch { $kesintiDk = 0 }
        if ($kesintiDk -lt $minKesinti) {
            Write-Log 'INFO' ('restart degerlendirmesi bekliyor: kesinti ' + [math]::Round($kesintiDk) + ' dk suruyor (esik ' + $minKesinti + ' dk)')
            return
        }
    }
    $badNames = ($bad | ForEach-Object { $_.Name }) -join ', '
    $decision = Get-RebootDecision -State $state -Now (Get-Date) -BadNames @($bad | ForEach-Object { $_.Name })
    if (-not $decision.Allowed) {
        # Bu iki yolde restart YAPILMAZ ama sorun devam ediyor. Onceki mesaj
        # "durduruldu" diyordu ve kullanici bunu "restart iptal edildi" saniyordu;
        # aslinda hic restart denenmemisti. Metin artik bunu acikca soyluyor.
        if ($decision.Reason -eq 'outside-blackout' -or $decision.Reason -eq 'policy-never') {
            Write-Log 'INFO' ('yeniden başlatma yapılmayacak (' + $decision.Text + '); kullanıcıya bildiriliyor')
            $txt = ('Uzaktan erişim onarılamadı (' + $state.ConsecutiveFailures + ' deneme). Sorun: ' + $badNames + '. Şu anda yeniden başlatma yapılmayacak: ' + $decision.Text + '. Bilgisayarı istediğiniz zaman elle yeniden başlatabilirsiniz.')
            $null = Send-UserNotification -Key ('policy-' + $decision.Reason) -Title 'Bağlantı sorunu - restart yapılmayacak' -Text $txt
        } else {
            <#
                AYNI DEVRE KESICI DURUMUNDA ALERT/MESAJ TEKRARLANMAZ. Onceki surumde bu iki
                satiri her dongude (dakikada bir, iki es zamanli surecle) yaziyor, msg.exe
                ile 8 saat boyunca 276 kutu birikiyordu.
            #>
            $txt = ('Uzaktan erişim onarılamadı. Sorun: ' + $badNames + '. Yeniden başlatma bu turda yapılmayacak: ' + $decision.Text + '. Elle müdahale gerekiyor; bütçe veya bekleme süresi dolunca yeniden değerlendirilecek.')
            if ([string]$state.BreakerKey -ne [string]$decision.Reason) {
                Write-Log 'ALERT' ('yeniden başlatma yapılmayacak (devre kesici): ' + $decision.Text)
                $null = Send-UserNotification -Key ('kesici-' + $decision.Reason) -Title 'Otomatik restart yapılmayacak' -Text $txt
            } else {
                Write-Log 'INFO' ('devre kesici ayni durumda, tekrar edilmedi: ' + $decision.Text)
                $null = Send-UserNotification -Key ('kesici-' + $decision.Reason) -Title 'Otomatik restart yapılmayacak' -Text $txt
            }
        }
        $null = Invoke-StateUpdate {
            param($st)
            $st.ConsecutiveFailures = 0
            $st.BreakerKey = [string]$decision.Reason
        }
        return
    }
    Write-Log 'INFO' ('restart kararı: ' + $decision.Text)
    $null = Invoke-StateUpdate { param($st) $st.BreakerKey = '' }
    <#
        SON KONTROL: karar verildi ama henuz hicbir sey yapilmadi. Burada interneti TAZE
        tekrar yoklariz; kullanici adaptoru (ya da kabloyu) geri acmissa RESTART IPTAL EDILIR.
        Boylece "adaptoru geri actim ama yine de restart etti" durumu olmaz.
        Not: iptal edilirse ConsecutiveFailures ve NetResetPendingReboot sifirlanir, boylece
        eski "winsock reset sonrasi zorla restart" bayragi da temizlenir.
    #>
    if (Test-RecoveryBeforeReboot) {
        $null = Invoke-StateUpdate {
            param($st)
            $st.ConsecutiveFailures = 0
            $st.NetResetPendingReboot = 0
            $st.OutageStartUtc = ''
            $st.LastOkUtc = (Get-Date).ToString('o')
        }
        return
    }
    Send-Telegram ('[KRİTİK] ' + $env:COMPUTERNAME + ' ' + $state.ConsecutiveFailures + ' kez onarılamadı, ' + $cfg.RebootDelaySeconds + ' sn sonra yeniden başlatılıyor')
    if (-not (Request-OfficeSave -TimeoutSeconds ([int]$cfg.OfficeSaveTimeoutSeconds))) {
        Write-Log 'ALERT' 'yeniden başlatma iptal edildi: Word/Excel belgeleri kaydedilemedi (kayıp olmaması için durduruldu)'
        Send-Telegram ('[UYARI] ' + $env:COMPUTERNAME + ' yeniden başlatma iptal: kaydedilmemiş Word/Excel belgesi var, önce kaydedip kapatın')
        return
    }
    $hist = @()
    if ($state.PSObject.Properties.Name -contains 'RebootsUtc') { $hist = @($state.RebootsUtc) }
    $cutoff = (Get-Date).AddHours(-24)
    $kept = @()
    foreach ($r in $hist) {
        if (-not $r) { continue }
        try { if ([datetime]::Parse([string]$r, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) -gt $cutoff) { $kept += [string]$r } } catch { }
    }
    <#
        "RESTART ISTEME" damgasi. Butceye YAZILMAZ; yalnizca PendingRebootUtc isaretlenir.
        Butce kaydi ancak makine gercekten yeniden acildiginda (Sync-RebootAccounting) yazilir.
        Boylece "24 saatte 3 restart" iddiasi, olmayan restart'lar icin butce yakmaz.
    #>
    $null = Invoke-StateUpdate { param($st) $st.PendingRebootUtc = (Get-Date).ToString('o') }
    Write-Log 'ALERT' ('yeniden başlatma istendi: ' + [int]$cfg.RebootDelaySeconds + ' sn sonra (onaylanan restart ' + $kept.Count + '/' + [int]$cfg.MaxRestartsPerDay + '; bu restart gerçekten olunca sayılacak)')
    $null = Start-CountdownReboot -Reason 'onarilamayan baglanti sorunu' -Problems $badNames
}

function Start-CountdownReboot {
    <#
        Geri sayacli, IPTAL EDILEBILIR yeniden baslatma. Tum restart yollari buradan gecer
        (otomatik karar, paneldeki "Simdi zorla kapat", CRD) ki tek davranis olsun.

        Iki ayri iptal yolu var:
          1) Panelden "Iptal et" -> reboot-cancel.flag. 0,5 sn'de bir kontrol edilir;
             reboot-ack.json yazilir (panelin "gercekten durdu" demesinin tek yolu).
          2) Geri sayim sirasinda internet kendiliginden SAGLIKI cikarsa iptal edilir
             (kullanici adaptoru/kablonu geri acmis olabilir, gereksiz restart olmasin).

        Panel hic acilmadiysa da ayni dosyalar yazilir; kullanici yoksa cihaz yine kapanir
        (uzaktan kurtarma davranisi korunur).
    #>
    param(
        [string]$Reason = 'onarilamayan baglanti sorunu',
        [string]$Problems = '',
        [int]$DelaySeconds = 0
    )
    $cfg = Get-Config
    $delay = $DelaySeconds
    if ($delay -le 0) { $delay = [int]$cfg.RebootDelaySeconds }
    if ($delay -lt 30) { $delay = 30 }
    if ($delay -gt 600) { $delay = 600 }

    # Onceki turdan kalan isaretleri temizle: yeni sayac sifirdan baslasin.
    foreach ($f in @($RebootCancelFile, $RebootAckFile)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { } }

    $pending = [ordered]@{
        generated = (Get-Date).ToString('o')
        deadline  = (Get-Date).AddSeconds($delay).ToString('o')
        delaySec  = $delay
        reason    = $Reason
        problems  = $Problems
    }
    try {
        [System.IO.File]::WriteAllText($RebootPendingFile, ($pending | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $true))
    } catch { Write-Log 'WARN' ('restart bildirim dosyasi yazilamadi: ' + $_.Exception.Message) }

    # KULLANICI ANNOSU: panel dosyadan Turkce konusur (ses onbellegi tercih edilir);
    # panel kapaliysa dosya kalir ve 30 dk'ya kadar acilinca konusulur.
    # CountdownSeconds verildigi icin Write-RebootAnnounce klibi sure gore secer (60/30/10).
    $null = Write-RebootAnnounce -Text ('Onarılamayan bağlantı sorunu. Bilgisayar ' + $delay + ' saniye içinde yeniden açılacak.') -CountdownSeconds $delay -Force

    Write-Log 'ALERT' ('yeniden baslatma geri sayimi basladi: ' + $delay + ' sn (iptal edilebilir; sebep: ' + $Reason + ')')

    $end = (Get-Date).AddSeconds($delay)
    $tick = 0
    while ((Get-Date) -lt $end) {
        # 1) Panelden iptal
        if (Test-Path -LiteralPath $RebootCancelFile) {
            Write-Log 'ALERT' 'yeniden baslatma kullanici tarafindan iptal edildi'
            shutdown.exe /a 2>&1 | Out-Null
            try {
                $ack = [ordered]@{ cancelled = $true; at = (Get-Date).ToString('o'); reason = $Reason } | ConvertTo-Json
                [System.IO.File]::WriteAllText($RebootAckFile, $ack, (New-Object System.Text.UTF8Encoding $true))
            } catch { }
            foreach ($f in @($RebootCancelFile, $RebootPendingFile, (Join-Path $BaseDir 'pending-voice.json'))) {
                try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
            }
            # Ayni soruyu 5 dk sonra tekrar sorma: sayaci sifirla.
            # Butce kaydi zaten yazilmadi (yalnizca PendingRebootUtc vardi), o yuzden
            # burada butceden kayit silinmez; PendingRebootUtc temizlenir.
            try {
                $null = Invoke-StateUpdate {
                    param($st)
                    $st.ConsecutiveFailures = 0
                    $st.PendingRebootUtc = ''
                    $st.OutageStartUtc = ''
                    $st.RebootCancelledUtc = (Get-Date).ToString('o')
                }
            } catch { }
            Send-Telegram ('[BILDIRIM] ' + $env:COMPUTERNAME + ' yeniden baslatma iptal edildi (sistem acik kaldi)')
            # msg.exe KULLANILMAZ: panel zaten ekranda anons + balon gosteriyor ve
            # msg.exe 10 dk acik kalan bir pencere oldugu icin kullaniciya iki kutu cikiyordu.
            Write-Log 'ALERT' ('KULLANICI BILDIRIMI: yeniden baslatma iptal edildi - ' + $Reason)
            return $false
        }
        # 2) Geri sayim sirasinda internet toparlandi mi?
        $tick += 1
        if (($tick % 12) -eq 0) {
            try {
                <#
                    HIZLI YOKLAMA: once sert zaman asimli TCP (1,2 sn). DNS'te asilmaz, HTTP
                    basligi beklemez. 1.1.1.1 engelli bir agda olumsuz donerse HTTP yoklamasi
                    da yapilir; IKISI DE "baglanti var" demedikce iptal edilmez (yanlis
                    iptal, sadece bir restart'i engelledigi icin en kotu hali sinirli).
                #>
                $ok = $false
                if ((Get-TcpMs -HostName '1.1.1.1' -Port 443 -TimeoutMs 1200) -ge 0) { $ok = $true }
                if (-not $ok) {
                    try { $r = Invoke-Probe -Url 'https://www.google.com/generate_204' -TimeoutSec 3; if ($r.Ok) { $ok = $true } } catch { }
                }
                if ($ok) {
                    Write-Log 'INFO' 'restart iptal edildi: geri sayim sirasinda internet SAGLIKLI cikti'
                    shutdown.exe /a 2>&1 | Out-Null
                    foreach ($f in @($RebootCancelFile, $RebootPendingFile)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { } }
                    $null = Invoke-StateUpdate {
                        param($st)
                        $st.ConsecutiveFailures = 0
                        $st.NetResetPendingReboot = 0
                        $st.PendingRebootUtc = ''
                        $st.OutageStartUtc = ''
                        $st.LastOkUtc = (Get-Date).ToString('o')
                    }
                    $null = Write-RebootAnnounce -Text 'Bağlantı geri geldi, yeniden başlatma iptal edildi.' -CountdownSeconds 0 -Force -VoiceKey 'rebootcancel'
                    return $false
                }
            } catch { }
            # Hatirlatma anonsu: kullanici baska isle mesgulse duysun.
            $left = [int][math]::Ceiling(($end - (Get-Date)).TotalSeconds)
            if ($left -le 30 -and $left -gt 10) {
                $null = Write-RebootAnnounce -Text ('Bilgisayar ' + $left + ' saniye içinde yeniden açılacak. İptal edebilirsiniz.') -CountdownSeconds 0 -Force -VoiceKey 'reminder'
            }
        } catch {
            <#  Geri sayim ortasinda hata olsa bile restart yapilir: kullaniciyi asla acikta birakmayalim. #>
            Write-Log 'ERR' ('restart geri sayiminda hata: ' + $_.Exception.Message + ' - yine de yeniden baslatma deneniyor')
        }
        Start-Sleep -Milliseconds 500
    }

    # Son kontrol: kullanici tam sayi bittiginde tikladiysa yine de yakalayalim.
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $RebootCancelFile) {
        Write-Log 'ALERT' 'yeniden baslatma son anda iptal edildi'
        shutdown.exe /a 2>&1 | Out-Null
        try {
            $ack = [ordered]@{ cancelled = $true; at = (Get-Date).ToString('o'); reason = $Reason } | ConvertTo-Json
            [System.IO.File]::WriteAllText($RebootAckFile, $ack, (New-Object System.Text.UTF8Encoding $true))
        } catch { }
        foreach ($f in @($RebootCancelFile, $RebootPendingFile, (Join-Path $BaseDir 'pending-voice.json'))) {
            try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
        }
        try {
            $null = Invoke-StateUpdate {
                param($st)
                $st.ConsecutiveFailures = 0
                $st.PendingRebootUtc = ''
            }
        } catch { }
        return $false
    }

    Write-Log 'ALERT' 'geri sayim bitti, yeniden baslatma tetiklendi'
    try { Remove-Item -LiteralPath $RebootPendingFile -Force -ErrorAction SilentlyContinue } catch { }
    <#
        DOGRULANABILIR RESTART. Dogrudan "shutdown.exe /r /t 0" CAGRILMAZ: cikis kodu
        2>&1 | Out-Null ile atiliyordu, tek log yoktu ve geri sayim bitse bile restart
        gerceklesmeyince (digeri oturum, komut reddi) sistem sessizce acik kaliyordu;
        gunluk butce ise "restart gerceklesmis" sayiyordu. Confirm-Reboot sirasiyla
        shutdown.exe -> WMI Reboot -> Restart-Computer dener ve hangisinin restart
        ilettigini yazar. Butce kaydi ancak gercekten yeniden acilinda (Sync-RebootAccounting)
        yazilir; PendingRebootUtc o ana kadar durur.
    #>
    if (-not (Confirm-Reboot)) {
        Write-Log 'ERR' 'restart iletilemedi: butce yazilmadi, PendingRebootUtc duruyor (bir sonraki dongude yeniden denenecek)'
        return $false
    }
    return $true
}

function Show-Results {
    $bad = @($script:Results | Where-Object { -not $_.Ok -and -not $_.Skipped })
    foreach ($r in $script:Results) {
        $tag = if ($r.Skipped) { 'ATLANDI' } elseif ($r.Ok) { 'TAMAM   ' } else { 'SORUN   ' }
        Write-Host ('  [{0}] {1,-24} {2}' -f $tag, $r.Name, $r.Detail)
        if ($r.Repair) { Write-Host ('            onarim: ' + $r.Repair) }
    }
    if ($bad.Count -eq 0) { Write-Log 'INFO' 'SONUC: tum kontroller tamam.' } else { Write-Log 'WARN' ('SONUC: ' + $bad.Count + ' sorun -> ' + (($bad | ForEach-Object { $_.Name }) -join ', ')) }
    return $bad.Count
}

function Write-RepairStatusPatch {
    <#
        Onarim sonrasi last-run.json'u YERINDE gunceller: mevcut kontroller (checks), state ve config
        korunur, sadece zaman damgasi / onarim sonucu / ozet degisir.
        Boylece 60 sn'lik izleyici, panelin kontrol listesini 5 dakika boyunca bosaltmaz.
    #>
    param([bool]$Ok, [string]$Summary, [int]$BadCount = 0)
    $path = Join-Path $BaseDir 'last-run.json'
    $cur = $null
    if (Test-Path -LiteralPath $path) { try { $cur = Read-Status -Path $path } catch { } }
    if (-not $cur) { $null = Write-JsonStatus -AllOk $Ok -Summary $Summary -BadCount $BadCount; return }
    $cur.generated = (Get-Date).ToString('o')
    $cur.ok = $Ok
    $cur.summary = $Summary
    $cur.badCount = $BadCount
    $cur.lastRepair = $script:LastRepair
    $null = Write-Status -Path $path -Object $cur
}

function Write-JsonStatus {
    param([bool]$AllOk, [string]$Summary, [int]$BadCount)
    $cfg = $global:cfg
    $state = Get-State
    $lastRepair = $null
    if ($script:LastRepair) { $lastRepair = $script:LastRepair }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $taskKnown = $true
    if (-not $task -and -not (Test-Admin)) { $taskKnown = $false }
    $checks = @()
    foreach ($r in $script:Results) {
        $checks += [ordered]@{ name = $r.Name; ok = [bool]$r.Ok; skipped = [bool]$r.Skipped; detail = $r.Detail; repair = $r.Repair; metrics = $(if ($r.Metrics) { $r.Metrics } else { @{} }) }
    }
    $obj = [ordered]@{
        generated = (Get-Date).ToString('o')
        host = $env:COMPUTERNAME
        user = $env:USERNAME
        version = $script:AppVersion
        role = 'host'
        ok = $AllOk
        badCount = $BadCount
        summary = $Summary
        uptimeMinutes = (Get-UptimeMinutes)
        publicIp = $script:PublicIp
        lastRepair = $lastRepair
        repairWatch = $(if (Get-ScheduledTask -TaskName 'RemoteHostRepairWatch' -ErrorAction SilentlyContinue) { 1 } else { 0 })
        taskInstalled = $(if ($task) { $true } elseif ($taskKnown) { $false } else { 'unknown' })
        taskVisible = $taskKnown
        taskState = $(if ($task) { [string]$task.State } else { 'yok' })
        inBlackout = (Test-InBlackout)
        isHoliday = (Test-IsHoliday)
        checks = $checks
        state = [ordered]@{
            consecutiveFailures = [int]$state.ConsecutiveFailures
            netRepairRung = [int]$state.NetRepairRung
            netResetPendingReboot = [int]$state.NetResetPendingReboot
            crdNoConnCycles = [int]$state.CrdNoConnCycles
            alertKey = [string]$state.AlertKey
            lastOkUtc = [string]$state.LastOkUtc
            lastUserNotifyUtc = [string]$state.LastUserNotifyUtc
            <#  RebootsUtc artik YALNIZCA gercek restartlari icerir (dogrulama:
            PendingRebootUtc damgasi, makine yeniden acilinca butceye yazilir). #>
            reboots24h = @($state.RebootsUtc).Count
            pendingRebootUtc = [string]$state.PendingRebootUtc
            lastBootUtc = [string]$state.LastBootUtc
            outageStartUtc = [string]$state.OutageStartUtc
        }
        config = [ordered]@{
            intervalMinutes = $(if ($task) {
                    $iv = @(foreach ($tg in @($task.Triggers)) { $tg.Repetition.Interval }) | Where-Object { $_ } | Select-Object -First 1
                    $ivn = 0
                    if ($iv -and [int]::TryParse((([string]$iv) -replace '^PT', '' -replace 'M$', ''), [ref]$ivn)) { $ivn } else { 0 }
                } else { 0 })
            restartPolicy = [string]$cfg.RestartPolicy
            minOutageMinutes = [int]$cfg.MinOutageMinutes
            blackoutStart = $cfg.BlackoutStart
            blackoutEnd = $cfg.BlackoutEnd
            blackoutFullDays = @($cfg.BlackoutFullDays)
            holidayMode = [string]$cfg.HolidayMode
            holidays = @(Get-HolidayList)
        }
    }
    $json = $obj | ConvertTo-Json -Depth 6
    $null = Write-Status -Path (Join-Path $BaseDir 'last-run.json') -Object $obj -NoSkip:$NoJson
    if ($Json) { Write-Output $json }
    return $json
}

function Invoke-Watchdog {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $global:cfg = Get-Config
    Write-Log 'INFO' ('dongu basladi | admin=' + (Test-Admin) + ' | rapor=' + $Check.IsPresent + ' | uptime=' + (Get-UptimeMinutes) + 'dk')
    $internetOk = Test-Internet
    if ($internetOk) {
        # Genel IP yalnizca internet VARKEN sorulur: dusuk agda bu cagri 8 sn zaman asimini
        # bekleyip karari/eylemi geciktiriyordu (internet yokken zaten ise yaramaz).
        try { $ip = Invoke-Probe -Url 'https://api.ipify.org' -TimeoutSec 5; if ($ip.Ok) { $script:PublicIp = [string]$ip.Raw.Content } } catch { }
        Test-Clock
        Test-NetworkLayer
        Test-CrdService
        Test-Rdp
        Test-Tunnel
        Test-ServiceRecovery
    } else {
        Write-Log 'WARN' 'internet yok, ag kontrolleri atlaniyor'
    }
    Test-Panel
    Test-ServerPower
    # Onarim istegi bu calisma sirasinda gelmisse (panelden tiklandi) beklemeden uygula
    if (Test-RepairRequestPending) {
        $req2 = Read-RepairRequest
        if ($req2) {
            $null = Invoke-NetworkRepairFlow -MaxRung $req2.Rung -Reason ('panel istedi (' + $req2.RequestedBy + ')')
            Test-NetworkLayer
        }
    }
    $badCount = Show-Results
    $allOk = ($badCount -eq 0)
    $summary = @($script:Results | ForEach-Object { $_.Name + '=' + $(if ($_.Skipped) { 'SKIP' } elseif ($_.Ok) { 'OK' } else { 'FAIL' }) }) -join '; '
    if ($script:PublicIp) { $summary += ' | ip=' + $script:PublicIp }
    Send-Heartbeat -Ok $allOk -Summary $summary
    Invoke-Alerts -AllOk $allOk -Summary $summary
    Invoke-RebootIfNeeded -AllOk $allOk
    $null = Write-JsonStatus -AllOk $allOk -Summary $summary -BadCount $badCount
    return $badCount
}

function Install-Watchdog {
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'), '-Install', '-IntervalMinutes', $IntervalMinutes)
    if ($HeartbeatUrl) { $forward += @('-HeartbeatUrl', ('"' + $HeartbeatUrl + '"')) }
    if ($TelegramToken) { $forward += @('-TelegramToken', ('"' + $TelegramToken + '"')) }
    if ($TelegramChatId) { $forward += @('-TelegramChatId', ('"' + $TelegramChatId + '"')) }
    if ($TunnelName) { $forward += @('-TunnelName', ('"' + $TunnelName + '"')) }
    if ($EnableTunnelRepair) { $forward += '-EnableTunnelRepair' }
    if ($KeepSleep) { $forward += '-KeepSleep' }
    if (-not (Test-Admin)) { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $forward; Write-Host 'Yonetici yetkisiyle yeniden baslatildi.'; return }
    $global:cfg = Get-Config
    if ($HeartbeatUrl) { $global:cfg.HeartbeatUrl = $HeartbeatUrl }
    if ($TelegramToken) { $global:cfg.TelegramToken = $TelegramToken }
    if ($TelegramChatId) { $global:cfg.TelegramChatId = $TelegramChatId }
    if ($TunnelName) { $global:cfg.TunnelName = $TunnelName }
    if ($EnableTunnelRepair) { $global:cfg.TunnelRepair = $true }
    if ($KeepSleep) {
        $global:cfg.ServerMode = $false
        $global:cfg.DisableHibernation = $false
        $global:cfg.DisableFastStartup = $false
        Write-Log 'INFO' ' profil: dizustu (uyku ve Fast Startup oldugu gibi birakildi)'
    }
    Save-Config $global:cfg
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"')
    $trgStartup = New-ScheduledTaskTrigger -AtStartup
    $trgLogon = New-ScheduledTaskTrigger -AtLogOn
    $trgRep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $stg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger @($trgStartup, $trgLogon, $trgRep) -Principal $prn -Settings $stg -Force | Out-Null
    Write-Log 'INFO' ('zamanlanmış görev kuruldu: ' + $TaskName + ' (acilista + oturum acilista + her ' + $IntervalMinutes + ' dk)')
    # Panelden "Agi / interneti onar" icin ayri, tetikleyicisiz (on-demand) gorev.
    # Ana gorev MultipleInstances=IgnoreNew oldugu icin calisirken baslatilamiyor; bu gorev her zaman aninda baslar.
    try {
        $rAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -RepairNetwork')
        $rPrn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $rStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(20)) -Hidden
        Register-ScheduledTask -TaskName 'RemoteHostRepair' -Action $rAct -Principal $rPrn -Settings $rStg -Force | Out-Null
        Write-Log 'INFO' '-panel onarim gorevi kuruldu: RemoteHostRepair (SYSTEM, sadece panelden tetiklenir, beklemez)'
    } catch { Write-Log 'WARN' ('panel onarim gorevi kurulamadi: ' + $_.Exception.Message) }
    # Normal kullanici SYSTEM gorevlerini adıyla baslatamaz; bu yuzden istek dosyasi 60 sn'de bir kontrol edilir.
    try {
        $wAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -RepairWatch')
        $wTrg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Seconds 60)
        $wStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) -Hidden
        Register-ScheduledTask -TaskName 'RemoteHostRepairWatch' -Action $wAct -Trigger $wTrg -Principal $rPrn -Settings $wStg -Force | Out-Null
        Write-Log 'INFO' 'panel onarim izleyicisi kuruldu: RemoteHostRepairWatch (SYSTEM, her 60 sn; istek yoksa aninda cikar)'
    } catch { Write-Log 'WARN' ('panel onarim izleyicisi kurulamadi: ' + $_.Exception.Message) }
    $saver = Join-Path (Split-Path -Parent $ScriptPath) 'Protect-OpenDocuments.ps1'
    if (Test-Path -LiteralPath $saver) {
    $officeTask = 'RemoteHostOfficeSaver'
    $officeVbs = Join-Path (Split-Path -Parent $ScriptPath) 'Start-OfficeSaver.vbs'
    if (Test-Path -LiteralPath $officeVbs) {
        $act2 = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $officeVbs + '"')
    } else {
        $act2 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $saver + '"')
    }
        $trg2 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $trg2b = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 2)
        $prn2 = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $stg2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
        try {
            Register-ScheduledTask -TaskName $officeTask -Action $act2 -Trigger @($trg2, $trg2b) -Principal $prn2 -Settings $stg2 -Force | Out-Null
            Write-Log 'INFO' ('belge kaydetme gorevi kuruldu: ' + $officeTask + ' (kullanici ' + $env:USERNAME + ', her 2 dk)')
        } catch { Write-Log 'WARN' ('belge kaydetme gorevi kurulamadi: ' + $_.Exception.Message) }
    } else { Write-Log 'WARN' ('bulge kaydetme betigi yok, reboot oncesi belge koruma devre disi: ' + $saver) }
    # Konsol penceresi olmasin diye wscript ile baslatma: Windows Terminal varsayilan terminal
    # oldugunda -WindowStyle Hidden yok sayilir ve siyah/mavi ekranlar bir gelip bir gider.
    $hiddenVbs = Join-Path (Split-Path -Parent $ScriptPath) 'Start-Hidden.vbs'
    $userTask = 'RemoteHostWatchdogUser'
    try {
        if (Test-Path -LiteralPath $hiddenVbs) {
            $uAct = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $hiddenVbs + '" "' + $ScriptPath + '" -UserFallback')
        } else {
            $uAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -UserFallback')
        }
        $uTrg1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $uTrg2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $uPrn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        $uStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $userTask -Action $uAct -Trigger @($uTrg1, $uTrg2) -Principal $uPrn -Settings $uStg -Force | Out-Null
        Write-Log 'INFO' ('kullanici yedek gorevi kuruldu: ' + $userTask + ' (kullanici ' + $env:USERNAME + ', her ' + $IntervalMinutes + ' dk; SYSTEM gorevi saglamsa bekler, silinirse devreye girer)')
    } catch { Write-Log 'WARN' ('kullanici yedek gorevi kurulamadi: ' + $_.Exception.Message) }
    $probeTask = 'RemoteHostFastProbe'
    try {
        if (Test-Path -LiteralPath $hiddenVbs) {
            $fAct = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $hiddenVbs + '" "' + $ScriptPath + '" -FastProbe')
        } else {
            $fAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -FastProbe')
        }
        $fTrg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $fPrn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $fStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
        Register-ScheduledTask -TaskName $probeTask -Action $fAct -Trigger @($fTrg) -Principal $fPrn -Settings $fStg -Force | Out-Null
        Write-Log 'INFO' ('hizli yoklama gorevi kuruldu: ' + $probeTask + ' (kullanici ' + $env:USERNAME + ', her 1 dk; sorun gorurse tam donguyu tetikler)')
    } catch { Write-Log 'WARN' ('hizli yoklama gorevi kurulamadi: ' + $_.Exception.Message) }
    <#
        SUREKLI ag olay dinleyicisi: 60 sn'lik gorev kapanip acildigi icin kablo cekilmesi
        gibi ANLIK olaylari yakalayamaz. Bu gorev surekli calisir ve Windows'un NetworkChange
        olaylarini dinler. 1 dk'lik FastProbe gorevi YEDEK olarak calismaya devam eder
        (yonlendirici/ISP tarafi sorunlarda olay gelmez, 1 dk'de bir yakalanir).
    #>
    $listenTask = 'RemoteHostNetListen'
    try {
        if (Test-Path -LiteralPath $hiddenVbs) {
            $lAct = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $hiddenVbs + '" "' + $ScriptPath + '" -NetListen')
        } else {
            $lAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -NetListen')
        }
        $lTrg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $lPrn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        # -Once TEKRAR YOK: surekli calisir, olayinda kendini yeniden baslatir
        $lStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $listenTask -Action $lAct -Trigger @($lTrg) -Principal $lPrn -Settings $lStg -Force | Out-Null
        Write-Log 'INFO' ('ag olay dinleyici gorevi kuruldu: ' + $listenTask + ' (kullanici ' + $env:USERNAME + ', surekli; kablo/adaptor/IP degisimi anlik yakalanir)')
    } catch { Write-Log 'WARN' ('ag olay dinleyici gorevi kurulamadi: ' + $_.Exception.Message) }
    Write-Host ('Kuruldu. Elle calistirmak icin: Start-ScheduledTask -TaskName ' + $TaskName)
    Write-Host 'Sunucu modu: BIOS icinde "Restore on AC Power Loss = Power On" ve "Wake on LAN" acik olmali.'
}

function Uninstall-Watchdog {
    if (-not (Test-Admin)) { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'), '-Uninstall'); return }
    Write-Log 'WARN' ('Uninstall-Watchdog CALISTIRILDI (PID ' + $PID + ') - zamanlanmis gorevler kaldiriliyor')
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host ('Zamanlanmis gorev kaldirildi: ' + $TaskName) }
    if (Get-ScheduledTask -TaskName 'RemoteHostRepair' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'RemoteHostRepair' -Confirm:$false; Write-Host 'Zamanlanmis gorev kaldirildi: RemoteHostRepair' }
    if (Get-ScheduledTask -TaskName 'RemoteHostRepairWatch' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'RemoteHostRepairWatch' -Confirm:$false; Write-Host 'Zamanlanmis gorev kaldirildi: RemoteHostRepairWatch' }
    if (Get-ScheduledTask -TaskName 'RemoteHostOfficeSaver' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'RemoteHostOfficeSaver' -Confirm:$false; Write-Host 'Zamanlanmis gorev kaldirildi: RemoteHostOfficeSaver' }
    if (Get-ScheduledTask -TaskName 'RemoteHostWatchdogUser' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'RemoteHostWatchdogUser' -Confirm:$false; Write-Host 'Zamanlanmis gorev kaldirildi: RemoteHostWatchdogUser' }
    if (Get-ScheduledTask -TaskName 'RemoteHostFastProbe' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'RemoteHostFastProbe' -Confirm:$false; Write-Host 'Zamanlanmis gorev kaldirildi: RemoteHostFastProbe' }
    if (Get-ScheduledTask -TaskName 'RemoteHostNetListen' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'RemoteHostNetListen' -Confirm:$false; Write-Host 'Zamanlanmis gorev kaldirildi: RemoteHostNetListen' }
    Write-Host ('Config/loglar korundu: ' + $BaseDir)
}

function Test-SystemWatchdogActive {
    <#
        SYSTEM (varsayilan) dongu saglam mi?
        BELIRLEYICI: system-heartbeat.json. Dosyayi SADECE varsayilan yol (zamanlanmis
        SYSTEM gorevi) yazar; kullanici yedegi (-UserFallback) ve canli yoklama YAZMAZ.
        Onceki surum iki seyden birine bakiyordu:
          - Get-ScheduledTask: bu makinede SYSTEM gorevi kurulu DEGIL, hep bos donuyordu
          - last-run.json'in "user" alani: bu alani herkes yazabiliyor, guvenilmez
        Sonuc: kullanici yedegi "SYSTEM saglam" sanip kendini kapatiyor, ortada HIC dongu
        kalmiyordu. Isaret dosyasi 2 dongu + 2 dk'de bir tazelenmezse yedek devreye girer.
    #>
    param([int]$StaleMinutes = 0)
    if ($StaleMinutes -le 0) { $StaleMinutes = ([int]$IntervalMinutes * 2 + 2) }
    $hb = Join-Path $BaseDir 'system-heartbeat.json'
    if (Test-Path -LiteralPath $hb) {
        try { return (((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalMinutes -lt $StaleMinutes) } catch { return $false }
    }
    <#  Isaret dosyasi yok (ilk kurulum / eski surum): gorev + rapor tazeligi ile devam et. #>
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { return $false }
    $lr = Join-Path $BaseDir 'last-run.json'
    if (-not (Test-Path -LiteralPath $lr)) { return $false }
    try { return (((Get-Date) - (Get-Item -LiteralPath $lr).LastWriteTime).TotalMinutes -lt $StaleMinutes) } catch { return $false }
}

function Get-ProbeStateInfo {
    <#  probe-state.json icerigi (nesne veya $null). #>
    $f = Join-Path $BaseDir 'probe-state.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-ProbeState {
    <#  Hizli yoklamanin sonucu: 'ok' | 'bad' | '' (hic calismadi). #>
    $j = Get-ProbeStateInfo
    if (-not $j) { return '' }
    return [string]$j.last
}

function Send-NetDownAnnounce {
    <#
        ANLIK ag sorunu algilandiginda sesli anons. Iki kanaldan birden gider:
          1) pending-voice.json -> panel dosyayi okuyup TURKCE KONUSUR (kullanici duyar).
          2) msg.exe + Telegram -> ekran/telefon bildirimi.
        Bastirma (throttle): kablo takilip cikarildiginda saniyeler icinde arka arkaya olay
        gelir; kullanici her seferinde duymasin diye ayni sorun icin kisa surede tekrar
        anons yapilmaz. "Saglandi" anonsu bastirmadan gecmeli, cunku her seferinde degil,
        sadece gercekten toparlanma aninda soylenmeli.
    #>
    param([string]$Detay = '', [bool]$YeniSorun = $true)
    $cfg = $global:cfg
    # Ayni kesintinin tekrari: onceki durum da 'bad' ise bu yeni olay degil, ayni sorun.
    if (-not $YeniSorun) { return $false }

    $eksik = ([string]$Detay).Trim()
    if (-not $eksik) { $eksik = 'baglanti' }
    $metin = 'Ağ sorunu algılandı. Eksik: ' + $eksik + '. Onarım başlatılıyor.'
    Write-Log 'ALERT' ('ANLIK AG SORUNU: ' + $metin)

    # 1) Panel icin bekleyen anons (dosya; panel okuyup konusur)
    # NOT: pending-voice.json TEK dosya ve restart anonsu da onu yazar. Buraya yazdigimiz
    # anonsu bir restart bildirimi ezebilirdi (canli testte boyle oldu), bu yuzden onarim
    # anonsunu KALICI (kuyruk) dosyasina yaziyoruz; panel her iki dosyayi da okur.
    # voiceKey: sabit cumlenin onbellekteki adi. 'Eksik: ...' kismi DINAMIK oldugu icin
    # metin birebir eslesmez; panel bu anahtarla kismi eslesme yapar ve internetsiz
    # kadin sesli anonsu onceden uretilmis dosyadan calar.
    try {
        if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
        $vfRepair = Join-Path $BaseDir 'pending-repair.json'
        <#  Ayni metin 10 dk'dan tazeyse tekrar yazma: panel ayni cumleyi kuyruga almasin. #>
        $yazilsin = $true
        if (Test-Path -LiteralPath $vfRepair) {
            try {
                $eski = Get-Content -LiteralPath $vfRepair -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($eski -and ([string]$eski.text -eq [string]$metin)) {
                    $yas = 999
                    try { $yas = ((Get-Date) - [datetime]::Parse([string]$eski.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes } catch { }
                    if ($yas -lt 10) { $yazilsin = $false }
                }
            } catch { }
        }
        if ($yazilsin) {
            ([ordered]@{ text = [string]$metin; sfx = 'warn'; voiceKey = 'netdown'; at = (Get-Date).ToString('o') } | ConvertTo-Json) |
                Set-Content -LiteralPath $vfRepair -Encoding UTF8
        }
    } catch { Write-Log 'WARN' ('anlik sorun anonsu dosyasi yazilamadi: ' + $_.Exception.Message) }
    # 2) Ekran + Telegram (kullanici basinda oturum yoksa Telegram devrede kalir)
    $null = Show-ScreenMessage -Text $metin -Seconds 300
    try { Send-Telegram ('[UYARI] ' + $env:COMPUTERNAME + ': ' + $metin) } catch { }
    return $true
}

function Save-ProbeState {
    <#
        Sonucu ve zamani yazar; -Beat ile "yoklama calisiyor" log zamani da guncellenir.
        -Full ile "tam dongu tetiklendi" zamani (fullAt) damgalanir; canli yoklamanin
        geri sayimini (bkz. Test-FullCycleDue) bu deger belirler.
        Dogrudan yazar; es zamanli yoklamalarda nadiren olusabilen yazma hatasinda birkac kez
        tekrar dener ve sonunda gunluk satirina yazar (sessizce yutmaz).
    #>
    param([string]$Last, [switch]$Beat, [switch]$Full)
    $f = Join-Path $BaseDir 'probe-state.json'
    $old = Get-ProbeStateInfo
    # DİKKAT: değişken adı $beatDeger olmalı; PowerShell 5.1'de $beat/$Beat farkı yok sayılır
    # ("-not $Beat" ifadesi yerel $beat değişkenine bağlanıp hata veriyordu).
    $beatDeger = (Get-Date).ToString('o')
    if ($old -and ($old.PSObject.Properties.Name -contains 'beat') -and $old.beat -and (-not $Beat)) { $beatDeger = [string]$old.beat }
    $fullDeger = ''
    if ($old -and ($old.PSObject.Properties.Name -contains 'fullAt') -and $old.fullAt) { $fullDeger = [string]$old.fullAt }
    <#  fullAt YALNIZCA gercekten tam dongu tetiklendiginde (/ -Full) guncellenir. Saglam
        durumda damgalamak yanlisti: ag 1 dk once saglikliyken 2 dk once de tetiklenmis bir
        dongunun ardindan koptsa yeni kesinti geri sayimda kalip sessizce gecikmis olurdu. #>
    if ($Full) { $fullDeger = (Get-Date).ToString('o') }
    $json = [ordered]@{ last = $Last; at = (Get-Date).ToString('o'); beat = $beatDeger; fullAt = $fullDeger } | ConvertTo-Json
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Set-Content -LiteralPath $f -Value $json -Encoding UTF8 -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds (150 * ($i + 1))
        }
    }
    Write-Log 'WARN' 'probe-state.json yazilamadi (dosya kilitli olabilir)'
}

function Get-FullCycleBackoffMinutes {
    <#
        Kesinti surerken iki tam dongu arasinda gecmesi gereken en az dakika.
        AMAC GERI SAYIM DEGIL, SADECE FIRTINA KORUMASI: ayni saniyede birden fazla surecin
        tam dongu acmasini engellemek. Bu yuzden SIKI tutulur (varsayilan 1 dk): karar
        gecikmesin. Cifte calismayi zaten Global\RemoteWatchdogCycle kilidi engelliyor.
    #>
    $iv = 0
    try { $iv = [int]$IntervalMinutes } catch { }
    if ($iv -le 0) { try { $iv = [int]$global:cfg.IntervalMinutes } catch { } }
    if ($iv -le 0) { return 1 }
    return [math]::Max(1, [math]::Min(3, [int][math]::Round($iv / 5)))
}

function Test-FullCycleDue {
    <#  Canli yoklama icin tam dongu tetikleme zamani geldi mi? (ilk tespit her zaman) #>
    $j = Get-ProbeStateInfo
    if (-not $j -or -not ($j.PSObject.Properties.Name -contains 'fullAt') -or -not $j.fullAt) { return $true }
    try {
        $son = [datetime]::Parse([string]$j.fullAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        return (((Get-Date) - $son).TotalMinutes -ge (Get-FullCycleBackoffMinutes))
    } catch { return $true }
}

function Test-ProbeBeatDue {
    <#  "Yoklama calisiyor" logu 30 dakikada bir yazilsin mi? (gunluk kirliligini onler) #>
    $j = Get-ProbeStateInfo
    if (-not $j -or -not ($j.PSObject.Properties.Name -contains 'beat') -or -not $j.beat) { return $true }
    try { return (((Get-Date) - [datetime]::Parse([string]$j.beat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes -ge 30) } catch { return $true }
}

function Test-CycleRunning {
    <#  Su an baska bir tam dongu calisiyor mu? (ayni anda tek dongu kurali) #>
    try {
        $m = New-Object System.Threading.Mutex($false, 'Global\RemoteWatchdogCycle')
        $got = $m.WaitOne(0)
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
        return (-not $got)
    } catch { return $false }
}

function Invoke-CycleLocked {
    <#
        Tam donguyu Global\RemoteWatchdogCycle kilidiyle sarar: ayni anda ikinci bir dongu
        CALISMAZ.
        Neden sart: -UserFallback yolu (canli yoklamanin tetikledigi yol) onceki surumde
        kilidi hic almadan Invoke-Watchdog cagiriyordu. Bu yuzden Test-CycleRunning her
        zaman "calismiyor" diyor ve 1 dakikalik FastProbe her seferinde YENI bir dongu
        baslatiyordu. Sonuc: saniyede bir tam dongu, cift sayimlar, restart butcesinin
        sahte kayitlarla dolmasi ve msg.exe kutu birikimi.
        Döner: $true ise iş yapıldı, $false ise başka bir döngü çalışıyordu (atlandı).
    #>
    param([scriptblock]$Action)
    $m = $null
    $owns = $true
    try {
        $m = New-Object System.Threading.Mutex($false, 'Global\RemoteWatchdogCycle')
        $owns = $m.WaitOne(0)
    } catch { $owns = $true }
    if ($owns) {
        try { $null = & $Action } finally { if ($m) { try { $m.ReleaseMutex() } catch { }; try { $m.Dispose() } catch { } } }
        return $true
    }
    if ($m) { try { $m.Dispose() } catch { } }
    return $false
}

function Start-FullCycle {
    <#
        Tam donguyu baslatir (canli yoklama/olay dinleyicisi bir sorun veya duzelme gorunce).
        Zamanlanmis gorev yerine gizli ayri surec kullanilir: gorev icinden Start-ScheduledTask
        cagrisi bu ortamda takilip dongunun hic baslamamasina yol aciyordu.

        ONEMLI: burada -UserFallback GONDERILMEZ. O bayrak "SYSTEM gorevi saglamsa hemen cik"
        demektir; tetiklenen dongunun amaci tam da KONTROLU HEMEN YAPIP KARAR VERMEK oldugu
        icin onu kullanmak yanlisti: canli yoklama sorunu goruyor, tetikliyor, ama dongu
        "SYSTEM saglam" diyip hicbir sey yapmadan cikiyor ve karar bir sonraki 5 dakikalik
        SYSTEM dongusune kaliyordu (12:21'de tetiklendi, karar 12:25'te verildi).
        Varsayilan yol ayni kilidi (Invoke-CycleLocked) kullandigi icin cifte calisma olmaz;
        yonetici olmadigimizdan system-heartbeat.json da yazilmaz.

        Geri sayim damgasi (fullAt) YALNIZCA dongu gercekten baslatildiginda vurulur; kilit
        mesgulse (baska bir dongu zaten kontrolleri yapiyor) damga vurulmaz ki sonraki yoklama
        bosa beklemesin, bir dakika sonra yeniden denesin.
    #>
    if (Test-CycleRunning) { return 'zaten calisiyor' }
    $hiddenVbs = Join-Path (Split-Path -Parent $ScriptPath) 'Start-Hidden.vbs'
    try {
        if (Test-Path -LiteralPath $hiddenVbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $hiddenVbs + '" "' + $ScriptPath + '"') -WindowStyle Hidden | Out-Null
        } else {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) -WindowStyle Hidden | Out-Null
        }
        # Tetikleme damgasi: canli yoklamanin geri sayimi bu andan isler.
        Save-ProbeState (Get-ProbeState) -Full
        return 'baslatildi'
    } catch { return ('hata: ' + $_.Exception.Message) }
}

function Get-QuickNetState {
    <#
        CANLI YOKLAMA icin HAFIF ag olcumu. Neden ayri: Get-NetworkHealth tam teshis
        yapar (3 IP denemesi + mtalk + DNS cozumlemesi + https + netstat) ve DUSUK agda
        her adim kendi zaman asimini bekledigi icin 20 saniyeye kadar surabilir. Canli
        yoklama saniyede karar vermeli; burada yalnizca 3 kisa TCP denemesi var (her biri
        1,2 sn). Gercek teshis zaten tetiklenen tam dongude yapilir.
        Donus: [pscustomobject]@{ Ip; Dns; Https; Signal; Detail }
    #>
    param([int]$TimeoutMs = 1200)
    <#
        KISA YOL: ilk IP dener. IP aciliyorsa internet vardir (DNS/HTTPS da dolayli olarak
        calisir) - isim cozumleme yapan iki ek probu atlayarak saglikli tespiti ~0.1 sn'ye
        indiririz (duzelme/duzelme anonsinin gecikmesin diye). Yalnizca IP KAPALIYSA isim
        tabanli proba gideriz ki "DNS mi sorun" ayrimi yapilabilsin.
    #>
    $ip = $false
    foreach ($adr in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
        if ((Get-TcpMs -HostName $adr -Port 443 -TimeoutMs $TimeoutMs) -ge 0) { $ip = $true; break }
    }
    if ($ip) {
        return [pscustomobject]@{ Ip = $true; Dns = $true; Https = $true; Signal = $true; Detail = '' }
    }
    # IP yok: DNS cozumlemeyi ve sinyal yolunu ayri ayri olc (akis burada zaten kotudur)
    $dns = ((Get-TcpMs -HostName 'google.com' -Port 443 -TimeoutMs $TimeoutMs) -ge 0)
    $signal = ((Get-TcpMs -HostName 'mtalk.google.com' -Port 443 -TimeoutMs $TimeoutMs) -ge 0)
    $eksik = @(@(if (-not $ip) { 'IP' }) + @(if (-not $dns) { 'DNS' }) + @(if (-not $dns) { 'HTTPS' }) + @(if (-not $signal) { 'sinyal' }) -join ',')
    return [pscustomobject]@{ Ip = $ip; Dns = $dns; Https = $dns; Signal = $signal; Detail = $eksik }
}

function Get-FastProbeDecision {
    <#
        Hafif ag sagligi olcer ve NE YAPILACAGINI dondurur. exit CAGIRMAZ, cunku hem 60 sn
        gorevi hem de surekli olay dinleyicisi ayni karar mantigini kullanir.
        Donus: [pscustomobject]@{ Action='ok'|'full'; Detay='...' }
    #>
    $global:cfg = Get-Config
    $q = Get-QuickNetState
    $bad = -not ($q.Ip -and $q.Dns -and $q.Signal)
    $prev = Get-ProbeState
    $raporBozuk = $false
    $lr = Join-Path $BaseDir 'last-run.json'
    if (Test-Path -LiteralPath $lr) { try { $raporBozuk = (-not [bool](Get-Content -LiteralPath $lr -Raw -Encoding UTF8 | ConvertFrom-Json).ok) } catch { } }
    $duzeldi = (-not $bad) -and (($prev -eq 'bad') -or $raporBozuk)
    if (-not $bad -and -not $duzeldi) {
        $beat = Test-ProbeBeatDue
        Save-ProbeState 'ok' -Beat:$beat
        if ($beat) { Write-Log 'INFO' 'hizli yoklama calisiyor (olay dinleyici + 1 dk yedegi) - ag saglikli' }
        return [pscustomobject]@{ Action = 'ok'; Detay = ''; YeniSorun = $false }
    }
    if ($bad) {
        Save-ProbeState 'bad'
        $eksik = [string]$q.Detail
        <#
            GERI SAYIM (backoff): kesinti surerken her dakika YENI tam dongu baslatmak
            anlamsizdi (internet yokken onarim kademeleri de calisamaz) ama gunlugu, durum
            dosyasini ve restart kararini dakikada bir bozuyordu.
            ONEMLI: geri sayim YALNIZCA kesinti zaten surerken ($prev -eq 'bad') gecerli.
            Yeni bir kesinti (once saglikliyken) HER ZAMAN beklemez: yoksa ag 2 dakika
            once saglikliyken 1 dakika once de tetiklenmis bir dongunun ardindan koparsa
            kesinti sessizce 3 dakika gecikmeli kalir ve "ag sorunu" anonsu hic duyulmaz.
        #>
        $kesintiSuruyor = ($prev -eq 'bad')
        if ($kesintiSuruyor -and -not (Test-FullCycleDue)) {
            $beat = Test-ProbeBeatDue
            Save-ProbeState 'bad' -Beat:$beat
            if ($beat) { Write-Log 'INFO' ('hizli yoklama sorun gordu (' + $eksik + ') - kesinti suruyor, tam dongu kisa surede tekrar calistirilmayacak') }
            return [pscustomobject]@{ Action = 'wait'; Detay = $eksik; YeniSorun = $false }
        }
        <#  Geri sayim damgasini Start-FullCycle vurur (dongu GERCEKTEN baslarsa). Boylece
            kilit mesgul oldugu icin tetikleme yapilamazsa yoklama bosa beklemez. #>
        Save-ProbeState 'bad'
        Write-Log 'WARN' ('hizli yoklama sorun gordu (' + $eksik + ') -> tam dongu tetikleniyor')
        # Yeni kesinti mi? (onceki 'bad' degilse). Anonsu burada yapmiyoruz: Save-ProbeState
        # 'bad' yazdigi icin Send-NetDownAnnounce bastirmaya dusup sessizce cikarirdi.
        return [pscustomobject]@{ Action = 'full'; Detay = $eksik; YeniSorun = (-not $kesintiSuruyor) }
    }
    Save-ProbeState 'ok'
    Write-Log 'INFO' 'hizli yoklama baglanti yeniden geldi -> duzelme kaydi icin tam dongu tetikleniyor'
    return [pscustomobject]@{ Action = 'full'; Detay = 'duzeldi'; YeniSorun = $false }
}

function Invoke-FastProbe {
    <#
        Hafif canli yoklama (60 sn gorevi): sadece ag sagligini olcer (~bir kac sn).
        Saglikliysa sessiz cikar; sorun varsa tam donguyu tetikler. DUSEGECI DE YAKALAR:
        onceki durum kotuydu (veya son rapor hataliysa) ve ag duzeldiyse tam dongu tetiklenir,
        boylece "baglanti duzeldi" kaydi ve sesli anons olusur.
    #>
    $d = Get-FastProbeDecision
    if ($d.Action -eq 'full') {
        # Anlik sorun anonsu: once "duzeldi" gelirse soylenmez, yalnizca yeni kesintide
        if ($d.YeniSorun) { try { $null = Send-NetDownAnnounce -Detay $d.Detay -YeniSorun $true } catch { Write-Log 'WARN' ('anlik sorun anonsu hatasi: ' + $_.Exception.Message) } }
        $gorev = Start-FullCycle
        Write-Log 'INFO' ('tam dongu tetikleme sonucu: ' + $gorev)
    }
    exit 0
}

function Start-NetEventListener {
    <#
        SUREKLI ag olay dinleyicisi. 60 sn'lik gorev kapanip acildigi icin kablo cekilmesi
        gibi ANLIK olaylari yakalayamaz; bu dinleyici Windows'un kendi ag olaylarini dinler
        (System.Net.NetworkInformation.NetworkChange):
            - NetworkAvailabilityChanged : baglanti koptu / geri geldi (kablo, modem, DHCP)
            - NetworkAddressChanged      : IP degisti
        Olay gelince Get-FastProbeDecision calisir; ag sagliysa sessizce cikar, sorunlu/
        duzelmis ise tam donguyu tetikler.

        NEDEN "PORT DINLEME" DEGIL: internet kesildiginde aradaki baglanti kopar, yerel
        soket acik kalir ama yanit gelmez. Kesinti ancak disariya bir baglanti acilip yanit
        alinip alinmadigiyla anlasilir (Get-TcpMs / generate_204) - yani bu olay sadece
        FIZIKSEL katmani (kablo/adaptor/IP) anlik bildirir. Yonlendirici/ISP tarafi sorun
        olursa sinyal gelmez; onun icin 1 dakikalik FastProbe gorevi yedek olarak durur.
    #>
    Write-Log 'INFO' 'ag olay dinleyicisi basliyor (NetworkChange: kablo/adaptor/IP degisimi anlik; 1 dk yedegi devam ediyor)'
    $cs = @'
using System;
using System.Threading;
public class RwNetWatch {
  public static AutoResetEvent Signal = new AutoResetEvent(false);
  public static void Hook() {
    System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += delegate(object s, System.Net.NetworkInformation.NetworkAvailabilityEventArgs e) {
      Signal.Set();
    };
    System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += delegate(object s, System.EventArgs e) {
      Signal.Set();
    };
  }
  public static bool Wait(int ms) { return Signal.WaitOne(ms); }
}
'@
    try { Add-Type -TypeDefinition $cs -ErrorAction Stop } catch { Write-Log 'WARN' ('olay dinleyici yuklenemedi: ' + $_.Exception.Message); return 1 }
    try { [RwNetWatch]::Hook() } catch { Write-Log 'WARN' ('olay aboneligi kurulamadi: ' + $_.Exception.Message); return 1 }

    # Baslangicta bir kez yokla (acilista zaten kotu ise hemen yakala)
    $d = Get-FastProbeDecision
    if ($d.Action -eq 'full') { try { $null = Start-FullCycle; Write-Log 'INFO' 'olay dinleyicisi baslangic kontrolu: sorun vardi, tam dongu tetiklendi' } catch { } }
    $son = Get-Date
    while ($true) {
        try {
            # 60 sn'de bir zaman asimi: yedek yoklama (olay gelmezse de calisir)
            if ([RwNetWatch]::Wait(60000)) {
                <#  1 sn: adaptor acilisinda IP/DHCP'nin oturmasina kucak bir pay. Eskiden 3 sn
                    idi ve tespit -> restart zincirine 3 sn saf gecikme ekliyordu. #>
                Start-Sleep -Seconds 1
                Write-Log 'INFO' 'ag olayi geldi (kablo/adaptor/IP degisti) -> anlik yoklama'
                $son = Get-Date
                # Adaptor kapanip acilmasinda birkac deneme: IP/DHCP oturmasini bekle
                for ($i = 1; $i -le 3; $i++) {
                    $dd = Get-FastProbeDecision
                    if ($dd.Action -eq 'full') {
                        if ($dd.YeniSorun) { try { $null = Send-NetDownAnnounce -Detay $dd.Detay -YeniSorun $true } catch { Write-Log 'WARN' ('anlik sorun anonsu hatasi: ' + $_.Exception.Message) } }
                        try { $null = Start-FullCycle; Write-Log 'INFO' 'olay sonrasi tam dongu tetiklendi' } catch { }
                        break
                    }
                    if ($i -lt 3) { Start-Sleep -Seconds 5 }
                }
            } elseif (((Get-Date) - $son).TotalMinutes -ge 1) {
                $dd = Get-FastProbeDecision
                if ($dd.Action -eq 'full') {
                    if ($dd.YeniSorun) { try { $null = Send-NetDownAnnounce -Detay $dd.Detay -YeniSorun $true } catch { Write-Log 'WARN' ('anlik sorun anonsu hatasi: ' + $_.Exception.Message) } }
                    try { $null = Start-FullCycle } catch { }
                    <#  ONCEDEN BURADA 'break' vardi: dinleyici tam donguyu tetikledikten sonra
                        KENDINI KAPATIYORDU ve gorev zamanlayicisinin onu 1 dk sonra yeniden
                        baslatmasina birakiliyordu. Artik durur yok, kesintinin toparlanmasini
                        dinlemeye devam eder. #>
                }
                $son = Get-Date
            }
        } catch { Write-Log 'WARN' ('dinleyici hatasi: ' + $_.Exception.Message); Start-Sleep -Seconds 5 }
    }
}

function Show-Status {
    Write-Host ('=== ' + $TaskName + ' ===')
    <#
        ONEMLI: yonetici OLMAYAN bir oturumdan Get-ScheduledTask, SYSTEM hesabina ait
        gorevleri GOREMEZ (bos doner). Bu yuzden yalnizca gorev tanimlayicisina bakmak
        "zamanlanmis gorev YOK" gibi YANLIS bir sonuc veriyordu. Guvenilir isaret:
        system-heartbeat.json (yalnizca yetkili varsayilan dongu yazar).
    #>
    $systemAktif = Test-SystemWatchdogActive
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ('durum=' + $t.State + ' | son calisma=' + $info.LastRunTime + ' | son sonuc=' + $info.LastTaskResult + ' | sure=' + $t.Settings.ExecutionTimeLimit)
    } elseif ($systemAktif) {
        Write-Host 'SYSTEM gorevi calisiyor (bu oturumdan tanimlayicisi gorunmuyor; yonetici olmayan oturum SYSTEM gorevlerini goremez)'
    } else {
        Write-Host 'zamanlanmis gorev YOK (-Install calistir)'
    }
    $hb = Join-Path $BaseDir 'system-heartbeat.json'
    if (Test-Path -LiteralPath $hb) {
        try { Write-Host ('SYSTEM nabzi: ' + (Get-Item -LiteralPath $hb).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) } catch { }
    }
    $state = Get-State
    Write-Host ('ardisik basarisiz dongu: ' + $state.ConsecutiveFailures + ' | son basari: ' + $state.LastOkUtc + ' | son alarm: ' + $state.AlertKey)
    Write-Host ('gercek restart (24s): ' + @($state.RebootsUtc).Count + ' | bekleyen restart: ' + $(if ([string]$state.PendingRebootUtc) { $state.PendingRebootUtc } else { 'yok' }))
    $ut = Get-ScheduledTask -TaskName 'RemoteHostWatchdogUser' -ErrorAction SilentlyContinue
    Write-Host ('kullanici yedegi: ' + $(if ($ut) { $ut.State } else { 'YOK' }) + ' | SYSTEM devrede: ' + (Test-SystemWatchdogActive))
    $ft = Get-ScheduledTask -TaskName 'RemoteHostFastProbe' -ErrorAction SilentlyContinue
    Write-Host ('hizli yoklama: ' + $(if ($ft) { $ft.State } else { 'YOK' }) + ' (her 1 dk, yedek)')
    $lt = Get-ScheduledTask -TaskName 'RemoteHostNetListen' -ErrorAction SilentlyContinue
    Write-Host ('ag olay dinleyici: ' + $(if ($lt) { $lt.State } else { 'YOK' }) + ' (surekli, anlik kablo/adaptor/IP)')
    Write-Host ('=== son loglar (' + $LogFile + ') ===')
    if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 40 | ForEach-Object { Write-Host $_ } } else { Write-Host 'log yok' }
}

if ($Status) { Show-Status; exit 0 }
if ($Version) { Write-Host ('RemoteHostWatchdog ' + $script:AppVersion); exit 0 }
if ($Uninstall) { Uninstall-Watchdog; exit 0 }
if ($AddHoliday) { $global:cfg = Get-Config; Add-HolidayToFile -Dates (@($AddHoliday -split '[,;\s]+' | Where-Object { $_ })); exit 0 }
if ($RemoveHoliday) { $global:cfg = Get-Config; Remove-HolidayFromFile -Dates (@($RemoveHoliday -split '[,;\s]+' | Where-Object { $_ })); exit 0 }
if ($ListHolidays) {
    $global:cfg = Get-Config
    Write-Host ('Tatil modu: ' + $cfg.HolidayMode + ' (full = tatil gunu tamamen blackout, default = normal mesai kurali, none = yok say)')
    Write-Host ('Bugun: ' + (Get-Date).ToString('yyyy-MM-dd dddd') + ' | tatil mi: ' + (Test-IsHoliday))
    $list = Get-HolidayList
    Write-Host ('Kayitli tatil sayisi: ' + $list.Count)
    $list | Sort-Object | ForEach-Object { Write-Host ('  ' + $_) }
    exit 0
}
if ($Install) { Install-Watchdog; exit 0 }
if ($UserFallback) {
    if (Test-SystemWatchdogActive) { exit 0 }
    <#  Bilgi seviyesinde: kullanici kurulumunda (SYSTEM gorevi yok) bu normal durumdur.
        Her 5 dakikada bir WARN yazmak gunlugu sisiriyordu. #>
    Write-Log 'INFO' 'varsayilan (SYSTEM) dongu yok veya veri eski -> kullanici yedeği devrede (tam dongu calisiyor)'
    <#  KILIT ONEMLI: bu yol canli yoklamanin tetikledigi yoldur. Kilit alinmazsa her
        yoklama yeni bir dongu acar ve donguler birbirinin durum dosyasini ezer. #>
    if (-not (Invoke-CycleLocked { $null = Invoke-Watchdog })) {
        Write-Log 'INFO' 'baska bir tam dongu calisiyor, bu calisma atlandi'
    }
    exit 0
}
if ($FastProbe) { Invoke-FastProbe; exit 0 }
if ($NetListen) { exit (Start-NetEventListener) }
function Invoke-NetEventNow {
    <#
        Dinleyicinin olaydan sonra yaptigi isi elle tetikler (test/deniz aslani icin).
        -NetTestEvent ile cagrilir: "olay geldi" varsayilir ve ayni karar zinciri isler.
    #>
    Write-Log 'INFO' 'olay elle tetiklendi (-NetTestEvent): anlik yoklama baslatiliyor'
    $son = Get-Date
    for ($i = 1; $i -le 3; $i++) {
        $dd = Get-FastProbeDecision
        if ($dd.Action -eq 'full') {
            if ($dd.YeniSorun) { try { $null = Send-NetDownAnnounce -Detay $dd.Detay -YeniSorun $true } catch { Write-Log 'WARN' ('anlik sorun anonsu hatasi: ' + $_.Exception.Message) } }
            try { $null = Start-FullCycle; Write-Log 'INFO' 'olay sonrasi tam dongu tetiklendi (elle test)' } catch { }
            break
        }
        if ($i -lt 3) { Start-Sleep -Seconds 5 }
    }
    exit 0
}

if ($NetTestEvent) { Invoke-NetEventNow }
if ($RepairWatch) {
    # Hafif izleyici: her 60 sn bir kez calisir. Istek dosyasi yoksa aninda cikar (gunluk/JSON dokunulmaz).
    $wReq = Read-RepairRequest
    if (-not $wReq) { exit 0 }
    $global:cfg = Get-Config
    Write-Log 'INFO' ('panel onarim istegi alindi (60 sn izleyici) -> isteme: ' + $wReq.RequestedBy)
    $null = Invoke-NetworkRepairFlow -MaxRung $wReq.Rung -Reason ('panel istedi (' + $wReq.RequestedBy + ')')
    $wH = Get-NetworkHealth
    $wBad = 0
    if (-not ($wH.Ip -and $wH.Dns -and $wH.Https)) { $wBad = 1 }
    Write-RepairStatusPatch -Ok ($wBad -eq 0) -Summary ('ag onarimi (izleyici): basarili=' + $script:LastRepair.ok) -BadCount $wBad
    Send-Telegram ('[BILDIRIM] ' + $env:COMPUTERNAME + ' ag onarimi bitti (izleyici): basarili=' + $script:LastRepair.ok)
    exit 0
}
if ($ForceReboot) {
    $global:cfg = Get-Config
    $state = Get-State
    $state.ConsecutiveFailures = [int]$cfg.RebootAfterFailedCycles
    $state.NetResetPendingReboot = 1
    Save-State $state
    Write-Log 'ALERT' 'elle restart istendi (pano butonu), geri sayimli yeniden baslatma: ' + $cfg.RebootDelaySeconds + ' sn'
    Send-Telegram ('[BILDIRIM] ' + $env:COMPUTERNAME + ' elle restart istendi, ' + $cfg.RebootDelaySeconds + ' sn sonra yeniden baslatilacak')
    if (-not (Request-OfficeSave -TimeoutSeconds ([int]$cfg.OfficeSaveTimeoutSeconds))) {
        Write-Log 'ALERT' 'elle restart iptal: kaydedilmemiş belge var, once kaydedip kapatin'
        Send-Telegram ('[UYARI] ' + $env:COMPUTERNAME + ' restart iptal: kaydedilmemiş Word/Excel belgesi var')
        $null = Invoke-StateUpdate { param($st) $st.PendingRebootUtc = '' }
        exit 1
    }
    # Ayni geri sayimli/iptal edilebilir yol: panel de modal acsin, anons yapsin.
    $null = Start-CountdownReboot -Reason 'siz istediniz (panel butonu)'
    exit 0
}
<#  Varsayilan tam dongu: canli yoklama yoluyla AYNI kilidi kullanir. #>
if (-not (Invoke-CycleLocked {
        $null = Invoke-Watchdog
        <#
            SYSTEM nabzi. Yalnizca GERCEK ve YETKILI bir dongude yazilir:
              - varsayilan (zamanlanmis SYSTEM gorevi, yonetici) yolu yazar
              - kullanici yedegi / canli yoklama YAZMAZ (onlar -UserFallback dalinda cikar)
              - -Check (salt rapor modu) YAZMAZ: "hicbir sey degistirmez" sozu bozulmasin ve
                elle/panelden calistirilan bir rapor, olmayan SYSTEM gorevini "saglikli"
                gostermesin
              - yonetici OLMAYAN elle calistirma da YAZMAZ: aksi halde olmayan SYSTEM
                gorevini taklit edip kullanici yedegini bostan bekletirdi
            Test-SystemWatchdogActive bu dosyaya bakar.
        #>
        if ((-not $Check) -and (Test-Admin)) {
            try { Set-Content -LiteralPath (Join-Path $BaseDir 'system-heartbeat.json') -Value ((Get-Date).ToString('o')) -Encoding UTF8 -ErrorAction Stop } catch { }
        }
    })) {
    Write-Log 'INFO' 'baska bir tam dongu calisiyor, bu calisma atlandi'
}
exit 0
