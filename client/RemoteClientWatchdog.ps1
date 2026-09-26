#Requires -Version 5.1
<#
    RemoteClientWatchdog - YEREL (istemci) taraf
    Uzak makineye erisimi periyodik test eder, erisilemiyorsa Telegram/e-posta uyarisi gonderir,
    erisim duzeldugunde istemciyi (RDP / tarayici) otomatik acar ve oturumu canli tutar.

    .\RemoteClientWatchdog.ps1 -Check                  sadece rapor
    .\RemoteClientWatchdog.ps1                         bir kontrol dongusu
    .\RemoteClientWatchdog.ps1 -Install                kullanici bazli zamanlanmis gorev (admin gerektirmez)
    .\RemoteClientWatchdog.ps1 -Uninstall
    .\RemoteClientWatchdog.ps1 -Status
    Ornek:
      .\RemoteClientWatchdog.ps1 -Install -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\finrex.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Check,
    [switch]$Status,
    [switch]$Json,
    [int]$IntervalMinutes = 10,
    [string[]]$Target = @(),
    [string]$RdpFile = '',
    [string]$BrowserUrl = 'https://remotedesktop.google.com',
    [string]$TelegramToken = '',
    [string]$TelegramChatId = '',
    [string]$HeartbeatUrl = ''
)

$ErrorActionPreference = 'Continue'
$ScriptPath = $PSCommandPath
$BaseDir = Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog'
$LogFile = Join-Path $BaseDir 'client-watchdog.log'
$StateFile = Join-Path $BaseDir 'state.json'
$ConfigFile = Join-Path $BaseDir 'config.json'
$TaskName = 'RemoteClientWatchdog'
$script:Results = New-Object System.Collections.ArrayList
$global:cfg = $null

function Get-Config {
    $cfg = [ordered]@{
        Targets = @()
        RdpFile = ''
        BrowserUrl = 'https://remotedesktop.google.com'
        LaunchOnRecover = $true
        KeepAliveMinutes = 0
        TelegramToken = ''
        TelegramChatId = ''
        HeartbeatUrl = ''
        HeartbeatFailPath = '/fail'
        AlertRepeatHours = 3
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
    $Cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
}

function Write-Log {
    param([string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    try {
        if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        $all = @(Get-Content -LiteralPath $LogFile -Encoding UTF8)
        if ($all.Count -gt 3000) { $all[($all.Count - 2000)..($all.Count - 1)] | Set-Content -LiteralPath $LogFile -Encoding UTF8 }
    } catch { }
    Write-Host $line
}

function Get-State {
    $s = [pscustomobject]@{ LastOkUtc = ''; AlertKey = ''; AlertUtc = ''; LastLaunchUtc = '' }
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
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [string]$Repair = '')
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Repair = $Repair })
    Write-Log 'CHECK' ('{0} {1} | {2}{3}' -f $(if ($Ok) { 'TAMAM    ' } else { 'SORUN    ' }), $Name, $Detail, $(if ($Repair) { ' | aksiyon: ' + $Repair } else { '' }))
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port = 3389, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

function Test-LocalNet {
    $dnsOk = $false
    try { $dnsOk = [bool](Resolve-DnsName -Name 'remotedesktop.google.com' -Type A -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { }
    $webOk = $false
    try { $r = Invoke-WebRequest -Uri 'https://remotedesktop.google.com' -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop; $webOk = ($r.StatusCode -lt 500) } catch { }
    $mtalk = Test-TcpPort -HostName 'mtalk.google.com' -Port 443
    Add-Result 'Yerel baglanti' ($dnsOk -and $webOk -and $mtalk) ('dns=' + $dnsOk + ', web=' + $webOk + ', mtalk:443=' + $mtalk)
}

function Test-RemoteTargets {
    $cfg = $global:cfg
    $targets = @($cfg.Targets)
    if ($targets.Count -eq 0) { Add-Result 'Uzak hedefler' $true 'hedef tanimli degil (atlandi)' ''; return $true }
    $all = $true
    foreach ($t in $targets) {
        $parts = [string]$t -split ':'
        $h = $parts[0]
        $p = if ($parts.Count -gt 1) { [int]$parts[1] } else { 3389 }
        $up = Test-TcpPort -HostName $h -Port $p -TimeoutMs 4000
        if (-not $up) { $all = $false }
        Add-Result ('Hedef ' + $h + ':' + $p) $up $(if ($up) { 'ACIK' } else { 'KAPALI/timeout' })
    }
    return $all
}

function Test-CrdServicePath {
    $endpoints = @('remotedesktop.google.com', 'clients6.google.com', 'mtalk.google.com')
    $down = @()
    foreach ($e in $endpoints) { if (-not (Test-TcpPort -HostName $e -Port 443 -TimeoutMs 4000)) { $down += $e } }
    Add-Result 'CRD/Google sinyal yolu' ($down.Count -eq 0) $(if ($down.Count -eq 0) { '443/443/443 acik' } else { 'kapali: ' + ($down -join ',') })
    return ($down.Count -eq 0)
}

function Invoke-Launcher {
    param([bool]$Recovered)
    $cfg = $global:cfg
    $state = Get-State
    $now = Get-Date
    if ($cfg.KeepAliveMinutes -gt 0 -and $state.LastLaunchUtc) {
        $last = [datetime]::Parse([string]$state.LastLaunchUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (($now - $last).TotalMinutes -lt [double]$cfg.KeepAliveMinutes) { return }
    }
    if ($recovered -and -not $cfg.LaunchOnRecover) { return }
    if ($cfg.RdpFile -and (Test-Path -LiteralPath $cfg.RdpFile)) {
        try { Start-Process -FilePath 'mstsc.exe' -ArgumentList ('"' + $cfg.RdpFile + '"') -ErrorAction Stop; Write-Log 'INFO' ('RDP acildi: ' + $cfg.RdpFile) } catch { Write-Log 'WARN' ('mstsc baslatilamadi: ' + $_.Exception.Message) }
    } elseif ($cfg.BrowserUrl) {
        try { Start-Process -FilePath $cfg.BrowserUrl -ErrorAction Stop; Write-Log 'INFO' ('tarayici acildi: ' + $cfg.BrowserUrl) } catch { Write-Log 'WARN' ('tarayici acilamadi: ' + $_.Exception.Message) }
    }
    $state.LastLaunchUtc = $now.ToString('o')
    Save-State $state
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
    $key = if ($AllOk) { 'OK' } else { 'FAIL' }
    $send = $false
    $recovered = $false
    if ($state.AlertKey -ne $key) { $send = $true; $recovered = ($key -eq 'OK' -and $state.AlertKey -ne '') }
    elseif ($state.AlertUtc) {
        $last = [datetime]::Parse([string]$state.AlertUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (($now - $last).TotalHours -ge [double]$cfg.AlertRepeatHours) { $send = $true }
    }
    if ($send) {
        $state.AlertKey = $key
        $state.AlertUtc = $now.ToString('o')
        if ($key -eq 'OK') { $state.LastOkUtc = $now.ToString('o') }
        Save-State $state
        $head = if ($recovered) { '[DUZELDI] ' } elseif ($key -eq 'OK') { '[TAMAM] ' } else { '[KOPUK] ' }
        Write-Log 'ALERT' ($head + $env:COMPUTERNAME + ' istemci | ' + $Summary)
        Send-Telegram ($head + $env:COMPUTERNAME + ' istemci | ' + $Summary)
    }
}

function Send-Heartbeat {
    param([bool]$Ok, [string]$Summary)
    $cfg = $global:cfg
    if (-not $cfg.HeartbeatUrl) { return }
    $url = $cfg.HeartbeatUrl
    if (-not $Ok) { $url = $url.TrimEnd('/') + $cfg.HeartbeatFailPath }
    $payload = [pscustomobject]@{ host = $env:COMPUTERNAME; role = 'client'; time = (Get-Date).ToString('s'); ok = $Ok; summary = $Summary; checks = $script:Results } | ConvertTo-Json -Depth 5
    try { Invoke-WebRequest -Uri $url -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop | Out-Null } catch { Write-Log 'WARN' ('heartbeat basarisiz: ' + $_.Exception.Message) }
}

function Write-JsonStatus {
    param([bool]$AllOk, [string]$Summary)
    $state = Get-State
    $checks = @()
    foreach ($r in $script:Results) { $checks += [ordered]@{ name = $r.Name; ok = [bool]$r.Ok; detail = $r.Detail } }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $obj = [ordered]@{
        generated = (Get-Date).ToString('o')
        host = $env:COMPUTERNAME
        user = $env:USERNAME
        role = 'client'
        ok = $AllOk
        summary = $Summary
        taskInstalled = [bool]$task
        taskState = $(if ($task) { [string]$task.State } else { 'yok' })
        lastOkUtc = [string]$state.LastOkUtc
        alertKey = [string]$state.AlertKey
        checks = $checks
        config = [ordered]@{ targets = @($cfg.Targets); rdpFile = [string]$cfg.RdpFile; browserUrl = [string]$cfg.BrowserUrl; heartbeatUrl = [string]$cfg.HeartbeatUrl }
    }
    $json = $obj | ConvertTo-Json -Depth 6
    try { Set-Content -LiteralPath (Join-Path $BaseDir 'last-run.json') -Value $json -Encoding UTF8 } catch { }
    if ($Json) { Write-Output $json }
}

function Invoke-Cycle {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $global:cfg = Get-Config
    $state = Get-State
    $wasOk = ($state.AlertKey -eq 'OK')
    Write-Log 'INFO' ('dongu basladi | rapor=' + $Check.IsPresent)
    Test-LocalNet
    $signal = Test-CrdServicePath
    $targets = Test-RemoteTargets
    $allOk = $signal -and $targets
    foreach ($r in $script:Results) { if (-not $r.Ok) { $allOk = $false } }
    foreach ($r in $script:Results) {
        $tag = if ($r.Ok) { 'TAMAM   ' } else { 'SORUN   ' }
        Write-Host ('  [{0}] {1,-26} {2}' -f $tag, $r.Name, $r.Detail)
    }
    $summary = @($script:Results | ForEach-Object { $_.Name + '=' + $(if ($_.Ok) { 'OK' } else { 'FAIL' }) }) -join '; '
    Write-Log $(if ($allOk) { 'INFO' } else { 'WARN' }) ('SONUC: ' + $(if ($allOk) { 'uzak erisim hat sagligi' } else { 'ERISIM SORUNU' }))
    $null = Write-JsonStatus -AllOk $allOk -Summary $summary
    if (-not $Check) {
        Send-Heartbeat -Ok $allOk -Summary $summary
        Invoke-Alerts -AllOk $allOk -Summary $summary
        if ($allOk -and (-not $wasOk)) { Invoke-Launcher -Recovered $true }
        elseif ($allOk) { Invoke-Launcher -Recovered $false }
    }
}

function Install-Watchdog {
    $global:cfg = Get-Config
    if ($Target.Count -gt 0) { $global:cfg.Targets = @($Target) }
    if ($RdpFile) { $global:cfg.RdpFile = $RdpFile }
    if ($BrowserUrl) { $global:cfg.BrowserUrl = $BrowserUrl }
    if ($TelegramToken) { $global:cfg.TelegramToken = $TelegramToken }
    if ($TelegramChatId) { $global:cfg.TelegramChatId = $TelegramChatId }
    if ($HeartbeatUrl) { $global:cfg.HeartbeatUrl = $HeartbeatUrl }
    Save-Config $global:cfg
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"')
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $prn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $stg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $prn -Settings $stg -Force | Out-Null
        Write-Host ('Kuruldu: ' + $TaskName + ' (her ' + $IntervalMinutes + ' dk, kullanici oturumunda)')
    } catch {
        Write-Host 'Zamanlanmis gorev kurulamadi, periyodik olarak kendini baslatan dongu kuruluyor.'
        $run = 'Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""' + $ScriptPath + """"
        Set-ItemProperty -Path ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') -Name 'RemoteClientWatchdog' -Value $run -ErrorAction SilentlyContinue
    }
    Write-Host ('Config: ' + $ConfigFile)
}

function Uninstall-Watchdog {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host ('Kaldirildi: ' + $TaskName) }
    Remove-ItemProperty -Path ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') -Name 'RemoteClientWatchdog' -ErrorAction SilentlyContinue
    Write-Host ('Config/loglar korundu: ' + $BaseDir)
}

function Show-Status {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { $i = Get-ScheduledTaskInfo -TaskName $TaskName; Write-Host ('gorev=' + $t.State + ' son calisma=' + $i.LastRunTime + ' son sonuc=' + $i.LastTaskResult) } else { Write-Host 'zamanlanmis gorev YOK' }
    $state = Get-State
    Write-Host ('son durum=' + $state.AlertKey + ' | son basari=' + $state.LastOkUtc + ' | son acma=' + $state.LastLaunchUtc)
    Write-Host ('=== son loglar (' + $LogFile + ') ===')
    if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 30 | ForEach-Object { Write-Host $_ } } else { Write-Host 'log yok' }
}

if ($Status) { Show-Status; exit 0 }
if ($Uninstall) { Uninstall-Watchdog; exit 0 }
if ($Install) { Install-Watchdog; exit 0 }
Invoke-Cycle
exit 0
