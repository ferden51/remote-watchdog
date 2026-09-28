#Requires -Version 5.1
<#
    RemoteHostWatchdog - UZAK MAKINE tarafi (host)
    Kendini periyodik test eder, bozulan parcalari onarir, olculmezse makineyi yeniden baslatir,
    disariya nabiz (heartbeat) ve Telegram uyarisi gonderir. Sunucu gibi calisacak sekilde ayarlar.

    .\RemoteHostWatchdog.ps1 -Check     sadece rapor, hicbir sey degistirmez
    .\RemoteHostWatchdog.ps1            bir onarim dongusu
    .\RemoteHostWatchdog.ps1 -UserFallback  SYSTEM gorevi saglamsa cikis, yoksa/eskise tam dongu (kullanici yedegi)
    .\RemoteHostWatchdog.ps1 -FastProbe     hafif 60 sn yoklamasi: sorun varsa tam donguyu hemen tetikler
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
$StateFile = Join-Path $BaseDir 'host-state.json'
$ConfigFile = Join-Path $BaseDir 'config.json'
$TaskName = 'RemoteHostWatchdog'
$script:Results = New-Object System.Collections.ArrayList
$script:PublicIp = $null
$global:cfg = $null
$RebootableProblems = @('Internet', 'Saat senkronu', 'Ag katmani', 'Windows RDP', 'Guc/uyku ayarlari')

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    try {
        if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        $all = @(Get-Content -LiteralPath $LogFile -Encoding UTF8)
        if ($all.Count -gt 5000) { $all[($all.Count - 4000)..($all.Count - 1)] | Set-Content -LiteralPath $LogFile -Encoding UTF8 }
    } catch { }
    Write-Host $line
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
        RebootAfterFailedCycles = 3
        RebootDelaySeconds = 60
        MaxRestartsPerDay = 3
        RebootCooldownMinutes = 60
        HealthyMinutesToReset = 60
        RebootSkipIfUnregistered = $true
        MinUptimeMinutes = 30
        OfficeSaveBeforeReboot = $true
        OfficeSaveTimeoutSeconds = 120
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
    $s = [pscustomobject]@{ ConsecutiveFailures = 0; CrdNoConnCycles = 0; NetRepairRung = 0; NetResetPendingReboot = 0; RebootsUtc = @(); LastBootUtc = ''; LastHealthyUtc = ''; AlertKey = ''; AlertUtc = ''; LastOkUtc = ''; LastUserNotifyUtc = '' }
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
    try { $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
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
    $healthy = Test-NetworkHealthy
    Write-Log 'WARN' ('elle ag onarimi basladi: ' + $Reason + ' (saatlim: ' + $healthy + ')')
    if ($healthy) {
        Write-Log 'INFO' 'ag saglikli, hicbir kademe uygulanmadi'
    } else {
        for ($r = 1; $r -le $MaxRung; $r++) {
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
        rungs = $rungs
        actions = $applied
        stillBad = $still
        elapsedSec = [int]$sw.Elapsed.TotalSeconds
    }
    Write-Log $(if ($script:LastRepair.ok) { 'INFO' } else { 'WARN' }) ('ag onarimi bitti: basarili=' + $script:LastRepair.ok + ', kademe=' + ($rungs -join ',') + ', sure=' + $script:LastRepair.elapsedSec + ' sn' + $(if ($still.Count) { ', kalan sorun: ' + ($still -join ', ') } else { '' }))
    return $script:LastRepair
}

function Read-RepairRequest {
    <#  Panelin bir dosya birakerek istedigi onarim: panel, görevi SYSTEM olarak çalıştırır, UAC gerekmez. #>
    $reqPath = Join-Path $BaseDir 'repair-request.json'
    if (-not (Test-Path -LiteralPath $reqPath)) { return $null }
    $req = $null
    try { $req = Get-Content -LiteralPath $reqPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    try { Remove-Item -LiteralPath $reqPath -Force -ErrorAction SilentlyContinue } catch { }
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
        $state.NetRepairRung = 0
    } else {
        $rung = [int]$state.NetRepairRung + 1
        if ($rung -gt [int]$cfg.NetMaxRepairRung) { $rung = [int]$cfg.NetMaxRepairRung }
        $repair += ('bozuk: eksik=' + (@(if (-not $h.Ip) { 'IP' }) + @(if (-not $h.Dns) { 'DNS' }) + @(if (-not $h.Https) { 'HTTPS' }) -join ','))
        if ($cfg.FixNetwork -and (Test-Admin) -and -not $Check) {
            $repair += (Invoke-NetworkRepair -Rung $rung) -join '; '
            if ($rung -ge [int]$cfg.NetMaxRepairRung) { $state.NetResetPendingReboot = 1; $repair += 'onerilen: makineyi yeniden baslat' }
        } else {
            $repair += 'kademe ' + $rung + ' uygulanmadi (admin gerekir)'
        }
        $state.NetRepairRung = $rung
    }
    Save-State $state
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
    $state = Get-State
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
        $state.CrdNoConnCycles = [int]$state.CrdNoConnCycles + 1
        # CRD baglantisi olmamasi bir hata veya reboot nedeni degildir, sadece bos durum / sinyal bilgisi olarak kaydedilir
        $detail += ' (bosta veya baglanti yok)'
        if ($state.CrdNoConnCycles -ge [int]$cfg.CrdNoConnRestartCycles -and $cfg.FixCrd -and (Test-Admin) -and -not $Check -and -not (Get-CrdActiveSession)) {
            try {
                Stop-Service -Name 'chromoting' -Force -ErrorAction Stop
                Get-Process -Name 'remoting_host', 'remoting_start_host' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 2
                Start-Service -Name 'chromoting' -ErrorAction Stop
                $state.CrdNoConnCycles = 0
                $repair += 'uzun sure baglanti olmadi, chromoting servisi tazelendi'
            } catch { $repair += 'servis tazeleme basarisiz: ' + $_.Exception.Message }
        }
    } else {
        $state.CrdNoConnCycles = 0
        if ($cfg.CrdRestartAfterHours -gt 0 -and $ageH -gt [double]$cfg.CrdRestartAfterHours -and -not (Get-CrdActiveSession) -and -not $Check) {
            try { Stop-Service -Name 'chromoting' -Force -ErrorAction Stop; Start-Sleep 2; Start-Service -Name 'chromoting' -ErrorAction Stop; $repair += 'onleyici yeniden baslatma' } catch { }
        }
    }
    Save-State $state
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
        $r = Invoke-WebRequest -Uri $url -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
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
    $state = Get-State
    $now = Get-Date
    $bad = @($script:Results | Where-Object { -not $_.Ok -and -not $_.Skipped })
    $key = if ($AllOk) { 'OK' } else { (($bad | ForEach-Object { $_.Name }) -join '|') }
    $send = $false
    $recovered = $false
    if ($state.AlertKey -ne $key) {
        $send = $true
        $recovered = ($key -eq 'OK' -and $state.AlertKey -ne '' -and $state.AlertKey -ne 'OK')
    } elseif ($state.AlertUtc) {
        $last = [datetime]::Parse([string]$state.AlertUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (($now - $last).TotalHours -ge [double]$cfg.AlertRepeatHours) { $send = $true }
    }
    if ($send) {
        $state.AlertKey = $key
        $state.AlertUtc = $now.ToString('o')
        if ($key -eq 'OK') { $state.LastOkUtc = $now.ToString('o') }
        Save-State $state
        $head = if ($recovered) { '[DUZELDI] ' } elseif ($key -eq 'OK') { '[BİLGİ] ' } else { '[UYARI] ' }
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

function Send-UserNotification {
    param([string]$Text, [string]$Title = 'Uzak Makine Uyarisi')
    $cfg = $global:cfg
    $state = Get-State
    $now = Get-Date
    $repeat = [double]$cfg.NotifyRepeatHours
    if ($state.LastUserNotifyUtc) {
        $last = [datetime]::Parse([string]$state.LastUserNotifyUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (($now - $last).TotalHours -lt $repeat) {
            Write-Log 'INFO' ('kullanici bildirimi bastan sona gonderildi, tekrar icin ' + $repeat + ' saat beklenecek')
            return $false
        }
    }
    $state.LastUserNotifyUtc = $now.ToString('o')
    Save-State $state
    Write-Log 'ALERT' ('KULLANICI BILDIRIMI: ' + $Text)
    Send-Telegram ('[BILDIRIM] ' + $env:COMPUTERNAME + ' - ' + $Title + ': ' + $Text)
    try {
        msg.exe * /TIME:600 ('[' + $env:COMPUTERNAME + '] ' + $Title + ': ' + $Text) 2>&1 | Out-Null
        Write-Log 'INFO' 'ekran bildirimi gosterildi (msg.exe, 10 dk)'
    } catch { Write-Log 'WARN' 'ekran bildirimi gosterilemedi' }
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

function Invoke-RebootIfNeeded {
    param([bool]$AllOk)
    $cfg = $global:cfg
    if ($Check) { Write-Log 'INFO' 'rapor modu (-Check): yeniden baslatma degerlendirmesi ve durum sayaci degistirilmedi'; return }
    $state = Get-State
    if ($AllOk) {
        $state.ConsecutiveFailures = 0
        if ($state.LastHealthyUtc) {
            try {
                $lh = [datetime]::Parse([string]$state.LastHealthyUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                if (((Get-Date) - $lh).TotalMinutes -ge [double]$cfg.HealthyMinutesToReset) {
                    if (@($state.RebootsUtc).Count -gt 0) { Write-Log 'INFO' ('uzun sure saglikli kaldi, restart butcesi sifirlandi (' + [int]$cfg.HealthyMinutesToReset + ' dk)') }
                    $state.RebootsUtc = @()
                }
            } catch { }
        } else { $state.LastHealthyUtc = (Get-Date).ToString('o') }
        $state.LastOkUtc = (Get-Date).ToString('o')
        Save-State $state
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
    $state.ConsecutiveFailures = [int]$state.ConsecutiveFailures + 1
    Save-State $state
    $limit = [int]$cfg.RebootAfterFailedCycles
    if ([int]$state.NetResetPendingReboot -eq 1) { $limit = [math]::Min($limit, 1); Write-Log 'INFO' 'winsock/IP reset uygulanmisti, etkisi icin yeniden baslatma bir sonraki dongude yapilacak' }
    Write-Log 'INFO' ('basarisiz dongu ' + $state.ConsecutiveFailures + '/' + $limit)
    if ($limit -le 0 -or $state.ConsecutiveFailures -lt $limit) { return }
    $uptime = Get-UptimeMinutes
    if ($uptime -lt [int]$cfg.MinUptimeMinutes) {
        Write-Log 'INFO' ('restart ertelendi: makine sadece ' + $uptime + ' dk acik (esik ' + $cfg.MinUptimeMinutes + ' dk)')
        return
    }
    $badNames = ($bad | ForEach-Object { $_.Name }) -join ', '
    $decision = Get-RebootDecision -State $state -Now (Get-Date) -BadNames @($bad | ForEach-Object { $_.Name })
    if (-not $decision.Allowed) {
        if ($decision.Reason -eq 'outside-blackout' -or $decision.Reason -eq 'policy-never') {
            Write-Log 'INFO' ('yeniden başlatma yapılmayacak (' + $decision.Text + '); kullanıcıya bildiriliyor')
            Send-UserNotification -Title 'Bağlantı sorunu - karar sizin' -Text ('Uzaktan erişim onarılamadı (' + $state.ConsecutiveFailures + ' deneme). Sorun: ' + $badNames + '. Bilgisayarı istediğiniz zaman yeniden başlatabilirsiniz; zorla kapatma yapılmadı.')
            $state.ConsecutiveFailures = 0
            Save-State $state
            return
        }
        Write-Log 'ALERT' ('yeniden başlatma DURDURULDU (devre kesici): ' + $decision.Text)
        Send-UserNotification -Title 'Otomatik restart durduruldu' -Text ($decision.Text + '. Sorun: ' + $badNames + '. Elle müdahale gerekiyor; bütçe veya bekleme süresi dolunca yeniden değerlendirilecek.')
        $state.ConsecutiveFailures = 0
        Save-State $state
        return
    }
    Write-Log 'INFO' ('restart kararı: ' + $decision.Text)
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
    $kept += (Get-Date).ToString('o')
    $state.RebootsUtc = $kept
    Save-State $state
    Write-Log 'ALERT' ('yeniden başlatma tetiklendi: ' + $cfg.RebootDelaySeconds + ' sn sonra (24 saatte ' + $kept.Count + '/' + [int]$cfg.MaxRestartsPerDay + ' restart)')
    shutdown.exe /r /t $cfg.RebootDelaySeconds /c 'RemoteHostWatchdog: onarilamayan baglanti sorunu' 2>&1 | Out-Null
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
        }
        config = [ordered]@{
            intervalMinutes = $(if ($task) {
                    $iv = @(foreach ($tg in @($task.Triggers)) { $tg.Repetition.Interval }) | Where-Object { $_ } | Select-Object -First 1
                    $ivn = 0
                    if ($iv -and [int]::TryParse((([string]$iv) -replace '^PT', '' -replace 'M$', ''), [ref]$ivn)) { $ivn } else { 0 }
                } else { 0 })
            restartPolicy = [string]$cfg.RestartPolicy
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
    try { $ip = Invoke-Probe -Url 'https://api.ipify.org' -TimeoutSec 8; if ($ip.Ok) { $script:PublicIp = [string]$ip.Raw.Content } } catch { }
    Test-Internet
    Test-Clock
    Test-NetworkLayer
    Test-CrdService
    Test-Rdp
    Test-Panel
    Test-ServerPower
    Test-Tunnel
    Test-ServiceRecovery
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
    $userTask = 'RemoteHostWatchdogUser'
    try {
        $uAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -UserFallback')
        $uTrg1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $uTrg2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $uPrn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        $uStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $userTask -Action $uAct -Trigger @($uTrg1, $uTrg2) -Principal $uPrn -Settings $uStg -Force | Out-Null
        Write-Log 'INFO' ('kullanici yedek gorevi kuruldu: ' + $userTask + ' (kullanici ' + $env:USERNAME + ', her ' + $IntervalMinutes + ' dk; SYSTEM gorevi saglamsa bekler, silinirse devreye girer)')
    } catch { Write-Log 'WARN' ('kullanici yedek gorevi kurulamadi: ' + $_.Exception.Message) }
    $probeTask = 'RemoteHostFastProbe'
    try {
        $fAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -FastProbe')
        $fTrg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $fPrn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $fStg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
        Register-ScheduledTask -TaskName $probeTask -Action $fAct -Trigger @($fTrg) -Principal $fPrn -Settings $fStg -Force | Out-Null
        Write-Log 'INFO' ('hizli yoklama gorevi kuruldu: ' + $probeTask + ' (kullanici ' + $env:USERNAME + ', her 1 dk; sorun gorurse tam donguyu tetikler)')
    } catch { Write-Log 'WARN' ('hizli yoklama gorevi kurulamadi: ' + $_.Exception.Message) }
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
    Write-Host ('Config/loglar korundu: ' + $BaseDir)
}

function Test-SystemWatchdogActive {
    <#
        SYSTEM gorevi saglam mi: gorev var VE last-run.json taze (2 dongu + 2 dk icinde).
        Yedek gorev (-UserFallback) cift calismayi onlemek icin bunu kontrol eder.
    #>
    param([int]$StaleMinutes = 0)
    if ($StaleMinutes -le 0) { $StaleMinutes = ([int]$IntervalMinutes * 2 + 2) }
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    $lr = Join-Path $BaseDir 'last-run.json'
    if (-not (Test-Path -LiteralPath $lr)) { return $false }
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $lr).LastWriteTime
        return ($age.TotalMinutes -lt $StaleMinutes)
    } catch { return $false }
}

function Invoke-FastProbe {
    <#
        Hafif canli yoklama (60 sn gorevi): sadece ag sagligini olcer (~bir kac sn).
        Saglikliysa sessiz cikar; sorun varsa tam donguyu hemen tetikler (5 dk beklenmez).
    #>
    $global:cfg = Get-Config
    $h = Get-NetworkHealth
    if ($h.Ip -and $h.Dns -and $h.Https -and $h.Signal) { exit 0 }
    $eksik = @(@(if (-not $h.Ip) { 'IP' }) + @(if (-not $h.Dns) { 'DNS' }) + @(if (-not $h.Https) { 'HTTPS' }) + @(if (-not $h.Signal) { 'sinyal' }) -join ',')
    Write-Log 'WARN' ('hizli yoklama sorun gordu (' + $eksik + ') -> tam dongu tetikleniyor')
    try { Start-ScheduledTask -TaskName 'RemoteHostWatchdogUser' -ErrorAction Stop; exit 0 }
    catch {
        try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop; exit 0 }
        catch { Write-Log 'WARN' ('tam dongu gorevle baslatilamadi, dogrudan calisiyor: ' + $_.Exception.Message) }
    }
    $null = Invoke-Watchdog
    exit 0
}

function Show-Status {
    Write-Host ('=== ' + $TaskName + ' ===')
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ('durum=' + $t.State + ' | son calisma=' + $info.LastRunTime + ' | son sonuc=' + $info.LastTaskResult + ' | sure=' + $t.Settings.ExecutionTimeLimit)
    } else { Write-Host 'zamanlanmis gorev YOK (-Install calistir)' }
    $state = Get-State
    Write-Host ('ardisik basarisiz dongu: ' + $state.ConsecutiveFailures + ' | son basari: ' + $state.LastOkUtc + ' | son alarm: ' + $state.AlertKey)
    $ut = Get-ScheduledTask -TaskName 'RemoteHostWatchdogUser' -ErrorAction SilentlyContinue
    Write-Host ('kullanici yedegi: ' + $(if ($ut) { $ut.State } else { 'YOK' }) + ' | SYSTEM devrede: ' + (Test-SystemWatchdogActive))
    $ft = Get-ScheduledTask -TaskName 'RemoteHostFastProbe' -ErrorAction SilentlyContinue
    Write-Host ('hizli yoklama: ' + $(if ($ft) { $ft.State } else { 'YOK' }) + ' (her 1 dk)')
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
    Write-Log 'WARN' 'SYSTEM gorevi yok veya veri eski -> kullanici yedegi devrede (tam dongu calisiyor)'
    $null = Invoke-Watchdog
    exit 0
}
if ($FastProbe) { Invoke-FastProbe; exit 0 }
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
    Write-Log 'ALERT' ('elle restart istendi (pano butonu), gecikmeli yeniden baslatma: ' + $cfg.RebootDelaySeconds + ' sn')
    Send-Telegram ('[BILDIRIM] ' + $env:COMPUTERNAME + ' elle restart istendi, ' + $cfg.RebootDelaySeconds + ' sn sonra yeniden baslatilacak')
    if (-not (Request-OfficeSave -TimeoutSeconds ([int]$cfg.OfficeSaveTimeoutSeconds))) {
        Write-Log 'ALERT' 'elle restart iptal: kaydedilmemiş belge var, once kaydedip kapatin'
        Send-Telegram ('[UYARI] ' + $env:COMPUTERNAME + ' restart iptal: kaydedilmemiş Word/Excel belgesi var')
        exit 1
    }
    shutdown.exe /r /t $cfg.RebootDelaySeconds /c 'RemoteHostWatchdog: kullanici restart istedi' 2>&1 | Out-Null
    exit 0
}
$null = Invoke-Watchdog
exit 0
