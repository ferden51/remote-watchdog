#Requires -Version 5.1
<#
    RemoteHostWatchdog - UZAK MAKINE tarafi (host)
    Kendini periyodik test eder, bozulan parcalari onarir, olculmezse makineyi yeniden baslatir,
    disariya nabiz (heartbeat) ve Telegram uyarisi gonderir. Sunucu gibi calisacak sekilde ayarlar.

    .\RemoteHostWatchdog.ps1 -Check     sadece rapor, hicbir sey degistirmez
    .\RemoteHostWatchdog.ps1            bir onarim dongusu
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
    [switch]$KeepSleep
)

$ErrorActionPreference = 'Continue'
$ScriptPath = $PSCommandPath
$BaseDir = Join-Path $env:ProgramData 'RemoteWatchdog'
$LogFile = Join-Path $BaseDir 'host-watchdog.log'
$StateFile = Join-Path $BaseDir 'host-state.json'
$ConfigFile = Join-Path $BaseDir 'config.json'
$TaskName = 'RemoteHostWatchdog'
$script:Results = New-Object System.Collections.ArrayList
$script:PublicIp = $null
$global:cfg = $null
$RebootableProblems = @('Internet', 'Saat senkronu', 'Ag yigini', 'Windows RDP', 'Guc/uyku ayarlari', 'CRD servisi')

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
        ServerMode = $true
        DisableHibernation = $true
        DisableFastStartup = $true
        ServiceAutoStart = $true
        ServiceCrashRecovery = $true
        RebootAfterFailedCycles = 3
        RebootDelaySeconds = 60
        RebootSkipIfUnregistered = $true
        MinUptimeMinutes = 30
        CrdRestartAfterHours = 0
        CrdSignalPorts = @(443, 5222, 5223, 19302, 19303, 8443, 4433)
        CrdNoConnRestartCycles = 3
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
    $s = [pscustomobject]@{ ConsecutiveFailures = 0; CrdNoConnCycles = 0; LastBootUtc = ''; AlertKey = ''; AlertUtc = ''; LastOkUtc = '' }
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
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [string]$Repair = '', [bool]$Skipped = $false)
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Skipped = $Skipped; Detail = $Detail; Repair = $Repair })
    $tag = if ($Skipped) { 'ATLANDI ' } elseif ($Ok) { 'TAMAM    ' } else { 'SORUN    ' }
    Write-Log 'CHECK' ('{0} {1} | {2}{3}' -f $tag, $Name, $Detail, $(if ($Repair) { ' | onarim: ' + $Repair } else { '' }))
}

function Invoke-Probe {
    param([string]$Url, [int]$TimeoutSec = 10, [string]$Method = 'GET')
    try {
        $r = Invoke-WebRequest -Uri $Url -Method $Method -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Status = [int]$r.StatusCode; Raw = $r; Error = '' }
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        return [pscustomobject]@{ Ok = $false; Status = $code; Raw = $null; Error = $_.Exception.Message }
    }
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
            if ($matches[1] -eq 'ESTABLISHED' -and ($Ports -contains [int]$matches[2]) -and ($pids -contains [int]$matches[4])) { $count++ }
        }
    }
    return $count
}

function Test-Internet {
    $r = Invoke-Probe -Url 'https://www.google.com/generate_204' -TimeoutSec 8
    $mtalk = Test-NetConnection -ComputerName 'mtalk.google.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    $ok = $r.Ok -and $mtalk
    Add-Result 'Internet' $ok ('google204=' + $(if ($r.Ok) { $r.Status } else { 'HATA' }) + ', mtalk:443=' + $(if ($mtalk) { 'acik' } else { 'KAPALI' })) $(if ($ok) { '' } else { 'CRD kayit olamaz' })
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

function Test-NetworkStack {
    $repair = @()
    try { ipconfig /flushdns 2>&1 | Out-Null } catch { }
    $dns = $null
    try { $dns = [bool](Resolve-DnsName -Name 'remotedesktop.google.com' -Type A -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { }
    $ok = $true
    if (-not $dns) {
        $ok = $false
        if ($global:cfg.FixNetwork -and (Test-Admin) -and -not $Check) {
            foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                try { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep 2; Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue; $repair += ($a.Name + ' yeniden baslatildi') } catch { }
            }
        } else { $repair = 'DNS cozumlenmiyor, adaptor yeniden baslatilamadi (admin)' }
    }
    Add-Result 'Ag yigini (DNS)' $ok ('remotedesktop.google.com=' + $(if ($dns) { 'cozuldu' } else { 'COZULEMEDI' })) ($repair -join '; ')
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
    if (Test-Path -LiteralPath $cfgPath) {
        try { $hostId = (Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json).host_id; $registered = [bool]$hostId } catch { }
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
    $daemon = Get-CrdDaemon
    $ageH = 0
    if ($daemon.Count -gt 0) { $ageH = ((Get-Date) - ($daemon | Sort-Object StartTime | Select-Object -First 1).StartTime).TotalHours }
    $conns = Get-CrdSignalConnections -Ports $cfg.CrdSignalPorts
    $detail = 'start=' + $svc.StartType + ', durum=' + $svc.Status + ', daemon=' + $daemon.Count + ', yas=' + [math]::Round($ageH, 1) + 'sa, host_id=' + $(if ($registered) { 'var' } else { 'YOK' }) + ', googleBaglanti=' + $conns
    $state = Get-State
    if ($daemon.Count -eq 0) {
        $ok = $false
        if ($cfg.FixCrd -and (Test-Admin) -and -not $Check) {
            try {
                Stop-Service -Name 'chromoting' -Force -ErrorAction SilentlyContinue
                Get-Process -Name 'remoting_host', 'remoting_start_host' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 2
                Start-Service -Name 'chromoting' -ErrorAction Stop
                $repair += 'daemon yeniden baslatildi'
            } catch { $repair += 'yeniden baslatma basarisiz: ' + $_.Exception.Message }
        } else { $repair += 'daemon yok' }
    } elseif ($registered -and $conns -eq 0) {
        $state.CrdNoConnCycles = [int]$state.CrdNoConnCycles + 1
        $ok = $false
        $repair += 'Google baglantisi yok (' + $state.CrdNoConnCycles + '/' + $cfg.CrdNoConnRestartCycles + '. dongu)'
        if ($state.CrdNoConnCycles -ge [int]$cfg.CrdNoConnRestartCycles -and $cfg.FixCrd -and (Test-Admin) -and -not $Check -and -not (Get-CrdActiveSession)) {
            try {
                Stop-Service -Name 'chromoting' -Force -ErrorAction Stop
                Get-Process -Name 'remoting_host', 'remoting_start_host' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 2
                Start-Service -Name 'chromoting' -ErrorAction Stop
                $state.CrdNoConnCycles = 0
                $repair += 'takilmis host yeniden baslatildi'
            } catch { $repair += 'yeniden baslatma basarisiz: ' + $_.Exception.Message }
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
    Add-Result 'CRD servisi' $ok $detail ($repair -join '; ')
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
    $ok = $true
    $repair = ''
    if (-not $running) {
        $ok = $false
        if ($cfg.TunnelRepair -and -not $Check) {
            if ([Environment]::UserInteractive) {
                Start-Process -FilePath $codeCmd.Source -ArgumentList @('tunnel', '--name', $cfg.TunnelName) -ErrorAction SilentlyContinue
                $repair = 'code tunnel baslatildi'
                $ok = $true
            } else { $repair = 'tunnel yok; SYSTEM altinda baslatilamaz' }
        } else { $repair = 'calisan tunnel yok' }
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
        $head = if ($recovered) { '[DUZELDI] ' } elseif ($key -eq 'OK') { '[SAYGI] ' } else { '[UYARI] ' }
        $text = $head + $env:COMPUTERNAME + ' | ' + $Summary
        Write-Log 'ALERT' $text
        Send-Telegram $text
    }
}

function Invoke-RebootIfNeeded {
    param([bool]$AllOk)
    $cfg = $global:cfg
    $state = Get-State
    if ($AllOk) { $state.ConsecutiveFailures = 0; Save-State $state; return }
    $bad = @($script:Results | Where-Object { -not $_.Ok -and -not $_.Skipped })
    $unregistered = @($bad | Where-Object { $_.Name -eq 'CRD servisi' -and $_.Detail -match 'host_id=YOK' }).Count -gt 0
    if ($unregistered -and $cfg.RebootSkipIfUnregistered) {
        Write-Log 'INFO' 'yeniden baslatma atlandi: host.json yok, restart ile duzelmez (host yeniden kaydedilmeli)'
        return
    }
    $rebootable = @($bad | Where-Object { $RebootableProblems -contains $_.Name }).Count -gt 0
    if (-not $rebootable) { return }
    $state.ConsecutiveFailures = [int]$state.ConsecutiveFailures + 1
    Save-State $state
    $limit = [int]$cfg.RebootAfterFailedCycles
    Write-Log 'INFO' ('basarisiz dongu ' + $state.ConsecutiveFailures + '/' + $limit)
    if ($limit -le 0 -or $state.ConsecutiveFailures -lt $limit) { return }
    $uptime = Get-UptimeMinutes
    if ($uptime -lt [int]$cfg.MinUptimeMinutes) {
        Write-Log 'INFO' ('restart ertelendi: makine sadece ' + $uptime + ' dk acik (esik ' + $cfg.MinUptimeMinutes + ' dk)')
        return
    }
    Send-Telegram ('[KRITIK] ' + $env:COMPUTERNAME + ' ' + $state.ConsecutiveFailures + ' kez onarilamadi, ' + $cfg.RebootDelaySeconds + ' sn sonra yeniden baslatiliyor')
    Write-Log 'ALERT' ('yeniden baslatma tetiklendi: ' + $cfg.RebootDelaySeconds + ' sn sonra')
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

function Invoke-Watchdog {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $global:cfg = Get-Config
    Write-Log 'INFO' ('dongu basladi | admin=' + (Test-Admin) + ' | rapor=' + $Check.IsPresent + ' | uptime=' + (Get-UptimeMinutes) + 'dk')
    try { $ip = Invoke-Probe -Url 'https://api.ipify.org' -TimeoutSec 8; if ($ip.Ok) { $script:PublicIp = [string]$ip.Raw.Content } } catch { }
    Test-Internet
    Test-Clock
    Test-NetworkStack
    Test-CrdService
    Test-Rdp
    Test-ServerPower
    Test-Tunnel
    Test-ServiceRecovery
    $badCount = Show-Results
    $allOk = ($badCount -eq 0)
    $summary = @($script:Results | ForEach-Object { $_.Name + '=' + $(if ($_.Skipped) { 'SKIP' } elseif ($_.Ok) { 'OK' } else { 'FAIL' }) }) -join '; '
    if ($script:PublicIp) { $summary += ' | ip=' + $script:PublicIp }
    Send-Heartbeat -Ok $allOk -Summary $summary
    Invoke-Alerts -AllOk $allOk -Summary $summary
    Invoke-RebootIfNeeded -AllOk $allOk
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
    Write-Log 'INFO' ('zamanlanmis gorev kuruldu: ' + $TaskName + ' (acilista + oturum acilista + her ' + $IntervalMinutes + ' dk)')
    Write-Host ('Kuruldu. Elle calistirmak icin: Start-ScheduledTask -TaskName ' + $TaskName)
    Write-Host 'Sunucu modu: BIOS icinde "Restore on AC Power Loss = Power On" ve "Wake on LAN" acik olmali.'
}

function Uninstall-Watchdog {
    if (-not (Test-Admin)) { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'), '-Uninstall'); return }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host ('Zamanlanmis gorev kaldirildi: ' + $TaskName) }
    Write-Host ('Config/loglar korundu: ' + $BaseDir)
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
    Write-Host ('=== son loglar (' + $LogFile + ') ===')
    if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 40 | ForEach-Object { Write-Host $_ } } else { Write-Host 'log yok' }
}

if ($Status) { Show-Status; exit 0 }
if ($Uninstall) { Uninstall-Watchdog; exit 0 }
if ($Install) { Install-Watchdog; exit 0 }
$null = Invoke-Watchdog
exit 0
