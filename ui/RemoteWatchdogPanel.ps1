#Requires -Version 5.1
<#
    RemoteWatchdogPanel - RemoteWatchdog icin modern kontrol paneli (WPF, koyu tema)

    Durum, bekleyen isler, ayarlar, gunluk sekmeleri; sistem tepsisi simgesi; balloon bildirimleri.
    Mantik host/RemoteHostWatchdog.ps1 ve client/RemoteClientWatchdog.ps1 ile paylasir; onlarin
    last-run.json ve config.json dosyalarini okur, ayarlari oraya yazar.

    .\RemoteWatchdogPanel.ps1              pencereyi acar
    .\RemoteWatchdogPanel.ps1 -TrayOnly    sadece tepside calisir
    .\RemoteWatchdogPanel.ps1 -Install     oturum acilinda otomatik baslatir
    .\RemoteWatchdogPanel.ps1 -Uninstall
    .\RemoteWatchdogPanel.ps1 -SelfTest    arayuzu kurar, PNG onizleme uretir, cikar
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SelfTest,
    [switch]$TrayOnly,
    [switch]$NoBalloon,
    [switch]$Background,
    [string]$PreviewPage = 'conn',
    [string]$PreviewPath = '',
    [switch]$ShowWindow,
    [switch]$ClickTest
)

$ErrorActionPreference = 'Continue'
$ScriptPath = $PSCommandPath
$UiDir = Split-Path -Parent $ScriptPath
$Root = Split-Path -Parent $UiDir
$HostScript = Join-Path $Root 'host\RemoteHostWatchdog.ps1'
$HostDiag = Join-Path $Root 'host\Collect-Diagnostics.ps1'
$HostDocs = Join-Path $Root 'host\Protect-OpenDocuments.ps1'
$ClientScript = Join-Path $Root 'client\RemoteClientWatchdog.ps1'
$HostData = Join-Path $env:ProgramData 'RemoteWatchdog'
$HostJson = Join-Path $HostData 'last-run.json'
$HostConfig = Join-Path $HostData 'config.json'
$HostLog = Join-Path $HostData 'host-watchdog.log'
$ClientData = Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog'
$ClientJson = Join-Path $ClientData 'last-run.json'
$ClientConfig = Join-Path $ClientData 'config.json'
$ClientLog = Join-Path $ClientData 'client-watchdog.log'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'RemoteWatchdogTray'
$ShowRequest = Join-Path $env:TEMP 'RemoteWatchdog-show.flag'

$script:Win = $null
$script:Icon = $null
$script:Silent = [bool]((Get-ItemProperty -Path $RunKey -Name ($RunName + 'Silent') -ErrorAction SilentlyContinue).($RunName + 'Silent'))
$script:BalloonMode = 'critical'
$script:Background = [bool]$Background
$script:LastState = ''
$script:LastColor = $null
$script:HIcon = [IntPtr]::Zero
$script:ExitRequested = $false
$script:RoleCache = $null
$script:RoleCacheUntil = [datetime]::MinValue
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\RemoteWatchdogPanel')
$script:Page = 'overview'
$script:CheckBusy = $false
$script:CheckBusySince = $null
$script:CheckProcs = @()
$script:IntervalCacheMin = 0
$script:IntervalCacheSrc = ''
$script:IntervalCacheUntil = [datetime]::MinValue
$script:ConnSummary = @{ Ok = 0; Bad = 0; Info = 0; LastRun = $null }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:MutexAcquired = $false
$script:OtherInstance = $null
try {
    $script:MutexAcquired = $script:Mutex.WaitOne(0)
} catch { $script:MutexAcquired = $true }
if (-not $script:MutexAcquired -and -not $SelfTest) {
    $script:OtherInstance = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match ('-File\s+"?[^"]*' + [regex]::Escape([string]$ScriptPath)) -and $_.ProcessId -ne $PID })
    if (-not $Background -and -not $SelfTest) {
        try { Set-Content -LiteralPath $ShowRequest -Value (Get-Date).ToString('o') -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
        foreach ($o in $script:OtherInstance) {
            try {
                $pr = Get-Process -Id $o.ProcessId -ErrorAction SilentlyContinue
                if (-not $pr) { continue }
                $pr.Refresh()
                if ($pr.MainWindowHandle -ne 0) {
                    if (-not ('PanelWinFocus' -as [type])) {
                        Add-Type -Name PanelWinFocus -Namespace Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
                    }
                    [void][Native.PanelWinFocus]::ShowWindow($pr.MainWindowHandle, 9)
                    [void][Native.PanelWinFocus]::SetForegroundWindow($pr.MainWindowHandle)
                }
            } catch { }
        }
    }
    exit 0
}

$script:C = @{
    Bg = '#0F1114'
    Side = '#14161A'
    Card = '#1A1D22'
    Card2 = '#21252B'
    Line = '#2A2F36'
    Text = '#E8EAED'
    Muted = '#98A0AA'
    Accent = '#4C8DFF'
    Ok = '#3FB950'
    Warn = '#E3B341'
    Bad = '#F85149'
    Info = '#58A6FF'
}

function Bx { param([string]$Hex) if ($script:C.ContainsKey($Hex)) { $Hex = $script:C[$Hex] } return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }
function El { param($Window, [string]$Name) return $Window.FindName($Name) }

# --- Otomatik denetim sayaci yardimcilari (kalan sure, sn) ---
function Format-ShortSpan {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $s = [int][math]::Ceiling($Seconds)
    if ($s -ge 3600) { return ([string][int][math]::Floor($s / 3600) + ' sa ' + [string][int](($s % 3600) / 60) + ' dk') }
    if ($s -ge 60) { return (([int][math]::Floor($s / 60)).ToString('00') + ':' + ($s % 60).ToString('00')) }
    return ([string]$s + ' sn')
}

function Resolve-CheckInterval {
    param([switch]$Force)
    if (-not $Force -and $script:IntervalCacheMin -ge 1 -and $script:IntervalCacheUntil -gt (Get-Date)) { return $script:IntervalCacheMin }
    $min = 0
    $src = ''
    $hj = Get-Json $HostJson
    if ($hj -and $hj.config -and $hj.config.intervalMinutes) { $min = [double]$hj.config.intervalMinutes; $src = 'zamanlanmis gorev' }
    if ($min -lt 1) {
        $cfg = Get-HostConfig
        if ([double]$cfg.IntervalMinutes -ge 1) { $min = [double]$cfg.IntervalMinutes; $src = 'panel ayari (config.json)' }
    }
    if ($min -lt 1) {
        $ccfg = Get-Json $ClientConfig
        if ($ccfg -and $ccfg.IntervalMinutes) { $min = [double]$ccfg.IntervalMinutes; $src = 'istemci gorevi' }
    }
    if ($min -lt 1) { $min = 5; $src = 'varsayilan 5 dk' }
    $script:IntervalCacheMin = $min
    $script:IntervalCacheSrc = $src
    $script:IntervalCacheUntil = (Get-Date).AddSeconds(90)
    return $min
}

function Get-NextCheck {
    $st = Get-StatusInfo
    $mins = Resolve-CheckInterval
    $last = $null
    $src = ''
    foreach ($pair in @(@{ J = $st.Host; N = 'host' }, @{ J = $st.Client; N = 'istemci' })) {
        if ($last -or -not $pair.J -or -not $pair.J.generated) { continue }
        try {
            $last = [datetime]::Parse([string]$pair.J.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $src = [string]$pair.N
        } catch { }
    }
    if (-not $last -and (Test-Path -LiteralPath $HostJson)) {
        try { $last = (Get-Item -LiteralPath $HostJson).LastWriteTime; $src = 'host (dosya)' } catch { }
    }
    if (-not $last) {
        return [pscustomobject]@{
            Known = $false; Last = $null; Next = $null; Source = ''; IntervalMinutes = $mins; IntervalSource = $script:IntervalCacheSrc
            RemainingSeconds = 0; OverdueSeconds = 0; AgeSeconds = 0
        }
    }
    $now = Get-Date
    $next = $last.AddMinutes($mins)
    return [pscustomobject]@{
        Known = $true; Last = $last; Next = $next; Source = $src; IntervalMinutes = $mins; IntervalSource = $script:IntervalCacheSrc
        RemainingSeconds = [double]($next - $now).TotalSeconds
        OverdueSeconds = [double]($now - $next).TotalSeconds
        AgeSeconds = [double]($now - $last).TotalSeconds
    }
}

function Write-Trace {
    param([string]$Text)
    try {
        if (-not (Test-Path -LiteralPath $HostData)) { New-Item -ItemType Directory -Force -Path $HostData | Out-Null }
        Add-Content -LiteralPath (Join-Path $HostData 'panel.log') -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Text) -Encoding UTF8
    } catch { }
}

function Get-RoleInfo {
    if ((Get-Date) -lt $script:RoleCacheUntil) { return $script:RoleCache }
    $hj = Get-Json $HostJson
    $cj = Get-Json $ClientJson
    $clientData = [ordered]@{}
    if ($ClientConfig -and (Test-Path -LiteralPath $ClientConfig)) { $clientData = Read-ConfigFile $ClientConfig }
    $hostInstalled = $false
    if ($hj -and $hj.generated) {
        try { $hostInstalled = (((Get-Date) - [datetime]::Parse([string]$hj.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes -lt 30) } catch { }
    }
    if (-not $hostInstalled -and $hj -and $null -ne $hj.taskInstalled) { $hostInstalled = [bool]$hj.taskInstalled }
    if (-not $hostInstalled) { $hostInstalled = [bool](Get-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue) }
    $clientTask = Get-ScheduledTask -TaskName 'RemoteClientWatchdog' -ErrorAction SilentlyContinue
    $clientFresh = $false
    if ($cj -and $cj.generated) {
        try { $clientFresh = (((Get-Date) - [datetime]::Parse([string]$cj.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes -lt 30) } catch { }
    }
    $clientInstalled = ([bool]$clientTask) -or $clientFresh -or $clientData.Contains('Targets')
    $targets = @()
    if ($clientData.Contains('Targets')) { $targets = @($clientData['Targets']) }
    $remoteName = 'uzak makine'
    if ($clientData.Contains('RemoteName') -and $clientData['RemoteName']) { $remoteName = [string]$clientData['RemoteName'] }
    $role = 'none'
    if ($hostInstalled -and $clientInstalled) { $role = 'both' }
    elseif ($hostInstalled) { $role = 'host' }
    elseif ($clientInstalled) { $role = 'client' }
    else { $role = 'manual' }
    $text = switch ($role) { 'host' { 'UZAK HOST' } 'client' { 'ISTEMCI' } 'both' { 'HOST + ISTEMCI' } default { 'KURULU DEGIL' } }
    $tip = switch ($role) {
        'host' { 'Bu makine uzaktan erisilen host. CRD, RDP ve ag burada izleniyor; zorla kapatma bu makinede uygulanir.' }
        'client' { 'Bu makine uzak makineye baglanan istemci. Hedef: ' + $remoteName + ' | ' + (@($targets) -join ', ') + ' | Restart bu makineye uygulanmaz, uzak makine kendi politikasina gore karar verir.' }
        'both' { 'Bu makine hem host hem istemci olarak calisiyor.' }
        default { 'Ne host ne istemci gorevi kurulu. Install-Host.ps1 veya Install-Client.ps1 calistirin.' }
    }
    $script:RoleCache = [pscustomobject]@{ Role = $role; RoleText = $text; Tip = $tip; HostTask = $hostInstalled; ClientTask = $clientInstalled; Targets = $targets; RemoteName = $remoteName }
    $script:RoleCacheUntil = (Get-Date).AddMinutes(5)
    return $script:RoleCache
}

function Get-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-HostConfig {
    $cfg = [ordered]@{
        IntervalMinutes = 5;         RestartPolicy = 'blackout'; BlackoutEnabled = $true; BlackoutStart = 18; BlackoutEnd = 8
        MaxRestartsPerDay = 3; RebootCooldownMinutes = 60; HealthyMinutesToReset = 60
        BlackoutFullDays = @('Cmt', 'Paz'); BlackoutNights = @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')
        HolidayMode = 'full'; Holidays = @(); HolidaysFile = ''
        RebootAfterFailedCycles = 3; RebootDelaySeconds = 60; MinUptimeMinutes = 30; RebootSkipIfUnregistered = $true
        ForceRestartAlways = $false; ForceRestartUntil = ''
        FixNetwork = $true; NetMaxRepairRung = 4; FixRdp = $true; FixCrd = $true; FixClock = $true
        CrdNoConnRestartCycles = 3; CrdRestartAfterHours = 0; CrdSignalPorts = @(443, 5222, 5223, 19302, 19303, 8443, 4433)
        ServiceAutoStart = $true; ServiceCrashRecovery = $true
        TunnelRepair = $false; TunnelName = 'uzak-pc'
        ServerMode = $true; DisableFastStartup = $true; OfficeSaveBeforeReboot = $true
        OfficeSaveTimeoutSeconds = 120; OfficeAbortRebootIfStillOpen = $true; OfficeAbortRebootIfUnsaved = $true
        TelegramToken = ''; TelegramChatId = ''; HeartbeatUrl = ''; AlertRepeatHours = 12; NotifyRepeatHours = 4
    }
    if (Test-Path -LiteralPath $HostConfig) {
        try {
            $s = Get-Content -LiteralPath $HostConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) { if ($s.PSObject.Properties.Name -contains $k) { $cfg[$k] = $s.$k } }
        } catch { }
    }
    return $cfg
}

function Save-HostConfig {
    param($Values)
    if (-not (Test-Path -LiteralPath $HostData)) { New-Item -ItemType Directory -Force -Path $HostData | Out-Null }
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $HostConfig) {
        try {
            $raw = Get-Content -LiteralPath $HostConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        } catch { }
    }
    foreach ($k in $Values.Keys) { $obj[$k] = $Values[$k] }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $HostConfig -Encoding UTF8
}

function Invoke-Script {
    param([string]$Path, [Alias('Args')][string[]]$ScriptArgs = @(), [switch]$Wait, [switch]$WindowStyle)
    if (-not (Test-Path -LiteralPath $Path)) { [System.Windows.MessageBox]::Show('Dosya bulunamadi: ' + $Path) | Out-Null; return }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Path + '"')) + $ScriptArgs
    if ($Wait) { return (Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Wait -PassThru -WindowStyle Hidden).ExitCode }
    if ($WindowStyle) {
        $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Path + '"')) + $ScriptArgs
        Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Normal | Out-Null
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden | Out-Null
    }
}

function Get-StatusInfo {
    $hj = Get-Json $HostJson
    $cj = Get-Json $ClientJson
    $crit = 0
    if ($hj) { $crit = @($hj.checks | Where-Object { -not $_.ok }).Count }
    $cjCrit = 0
    if ($cj) { $cjCrit = @($cj.checks | Where-Object { -not $_.ok }).Count }
    $total = $crit + $cjCrit
    $age = $null
    if ($hj -and $hj.generated) {
        try { $age = (Get-Date) - [datetime]::Parse([string]$hj.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    }
    return [pscustomobject]@{ Host = $hj; Client = $cj; Bad = $total; Age = $age }
}

function Get-Actions {
    $st = Get-StatusInfo
    $hj = $st.Host
    $cfg = Get-HostConfig
    $a = New-Object System.Collections.ArrayList
    if (-not $hj) {
        [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = 'Uzak makine verisi yok'; Detail = 'Watchdog kurulu degil veya hic calismadi.'; Key = 'host'; Action = 'Kur' })
        return $a
    }
    if ($hj) {
        $fresh = $false
        try { $fresh = (((Get-Date) - [datetime]::Parse([string]$hj.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes -lt 30) } catch { }
        $hState = 'bilinmiyor'
        if ($hj.taskInstalled -eq $true) { $hState = 'calisiyor' }
        elseif ($hj.taskInstalled -eq $false) { $hState = 'KURULU DEGIL' }
        elseif ($fresh) { $hState = 'gorunmuyor-ama-calisiyor' }
        else { $hState = 'calismiyor' }
        if ($hState -eq 'KURULU DEGIL' -or $hState -eq 'calismiyor') {
            [void]$a.Add([pscustomobject]@{ Level = 'bad'; Title = 'Zamanlanmış görev kurulu değil'; Detail = 'RemoteHostWatchdog görevi bulunamadı. Bu görev olmadan kontrol, onarım, alarm ve restart politikası çalışmaz. Kurulum: install\Install-Host.ps1 (yönetici) ya da aşağıdaki Kur işlemi.'; Key = 'host'; Action = 'Kur' })
        } elseif ($hState -eq 'gorunmuyor-ama-calisiyor') {
            [void]$a.Add([pscustomobject]@{ Level = 'ok'; Title = 'Zamanlanmış görev çalışıyor'; Detail = 'RemoteHostWatchdog SYSTEM hesabına ait olduğu için normal kullanıcı sorgusunda görünmez; ancak veriler taze, yani görev düzenli çalışıyor.'; Key = ''; Action = '' })
        }
    }
    if ($st.Age -and $st.Age.TotalMinutes -gt ([double]$cfg.IntervalMinutes * 3)) {
        [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = ('Watchdog donmuyor (' + [math]::Round($st.Age.TotalMinutes) + ' dk once)'); Detail = 'Gorev durmus olabilir veya makine uyuyor.'; Key = 'run'; Action = 'Şimdi denetle' })
    }
    foreach ($c in @($hj.checks)) {
        if ($c.ok -or $c.skipped) { continue }
        $key = 'run'
        $act = 'Logları aç'
        if ($c.name -eq 'CRD servisi' -and [string]$c.detail -match 'host_id=YOK') { $key = 'crd'; $act = 'CRD sayfası'; $lvl = 'bad' } else { $lvl = 'warn' }
        if ($c.name -match 'Ag katmani') { $key = 'run'; $act = 'Ağ onarımı' }
        [void]$a.Add([pscustomobject]@{ Level = $lvl; Title = $c.name; Detail = [string]$c.detail; Key = $key; Action = $act })
    }
    $docsState = Join-Path $env:windir 'Temp\RemoteWatchdog-docs.json'
    if (Test-Path -LiteralPath $docsState) {
        try {
            $ds = Get-Content -LiteralPath $docsState -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$ds.unsaved -gt 0) { [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = ($ds.unsaved + ' kaydedilmemiş belge'); Detail = (@($ds.names) -join ', '); Key = 'docs'; Action = 'Kaydet ve kapat' }) }
        } catch { }
    }
    if ($hj.state -and [int]$hj.state.netResetPendingReboot -eq 1) { [void]$a.Add([pscustomobject]@{ Level = 'bad'; Title = 'winsock/IP reset uygulandi'; Detail = 'Etkisi icin makine yeniden baslatilmali.'; Key = 'reboot'; Action = 'Yeniden başlat' }) }
    if ($hj.state -and [int]$hj.state.consecutiveFailures -gt 0) { [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = ('Ardisik basarisiz deneme: ' + $hj.state.consecutiveFailures); Detail = 'Blackout saatlerinde otomatik restart yapilir, disinda sadece bilgilendirilir.'; Key = 'reboot'; Action = 'Yeniden başlat' }) }
    if ($a.Count -eq 0) { [void]$a.Add([pscustomobject]@{ Level = 'ok'; Title = 'Bekleyen is yok'; Detail = 'Her sey yolunda.'; Key = ''; Action = '' }) }
    return $a
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RemoteWatchdog" Height="720" Width="1080" MinHeight="600" MinWidth="900"
        Background="#0F1114" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bgc" Color="#0F1114"/>
    <SolidColorBrush x:Key="Side" Color="#14161A"/>
    <SolidColorBrush x:Key="Card" Color="#1A1D22"/>
    <SolidColorBrush x:Key="Card2" Color="#21252B"/>
    <SolidColorBrush x:Key="Line" Color="#2A2F36"/>
    <SolidColorBrush x:Key="Tx" Color="#E8EAED"/>
    <SolidColorBrush x:Key="Mut" Color="#98A0AA"/>
    <SolidColorBrush x:Key="Acc" Color="#4C8DFF"/>
    <SolidColorBrush x:Key="Ok" Color="#3FB950"/>
    <SolidColorBrush x:Key="Warn" Color="#E3B341"/>
    <SolidColorBrush x:Key="Bad" Color="#F85149"/>

    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="14"/>
    </Style>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="H3" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Mut}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style x:Key="Small" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Mut}"/>
      <Setter Property="FontSize" Value="11.5"/>
    </Style>
    <Style x:Key="Mono" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#C9D1D9"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="11.5"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Card2}"/>
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2B313A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Acc}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Acc}"/>
      <Setter Property="Foreground" Value="#0B1220"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Bad}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Bad}"/>
      <Setter Property="Foreground" Value="#1A0B0B"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="ToggleBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="16,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Nav" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Mut}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" CornerRadius="8" Padding="12,10">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1D2127"/>
                <Setter Property="Foreground" Value="{StaticResource Tx}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#0E1013"/>
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="CaretBrush" Value="{StaticResource Tx}"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style x:Key="Combo" TargetType="ComboBox">
      <Setter Property="Background" Value="#0E1013"/>
      <Setter Property="Foreground" Value="{StaticResource Tx}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>

    <DataTemplate x:Key="StatusCard">
      <Border Style="{StaticResource CardStyle}" Width="228" Margin="0,0,12,12">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Ellipse Width="10" Height="10" Margin="0,0,10,0" VerticalAlignment="Top" Fill="{Binding Brush}"/>
          <StackPanel Grid.Column="1">
            <TextBlock Text="{Binding Title}" Style="{StaticResource H2}" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Detail}" Style="{StaticResource Small}" Margin="0,5,0,0" TextWrapping="Wrap" MaxHeight="46"/>
            <TextBlock Text="{Binding Repair}" Foreground="{StaticResource Acc}" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap" MaxHeight="34"/>
          </StackPanel>
        </Grid>
      </Border>
    </DataTemplate>

    <DataTemplate x:Key="ActionRow">
      <Border Style="{StaticResource CardStyle}" Margin="0,0,0,10" Padding="16,13">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="4"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Background="{Binding Brush}" CornerRadius="2"/>
          <StackPanel Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
            <TextBlock Text="{Binding Title}" Style="{StaticResource H2}"/>
            <TextBlock Text="{Binding Detail}" Style="{StaticResource Small}" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
          <Button Grid.Column="2" Content="{Binding Action}" Style="{StaticResource Btn}" VerticalAlignment="Center"
                  Tag="{Binding Key}" MinWidth="120"/>
        </Grid>
      </Border>
    </DataTemplate>

    <DataTemplate x:Key="ConnRow">
      <Border Style="{StaticResource CardStyle}" Margin="0,0,0,10" Padding="16,13">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="215"/><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <Border Grid.Column="0" Width="4" CornerRadius="2" Background="{Binding Brush}" Margin="0,1,14,1"/>

          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <TextBlock Text="{Binding Name}" Style="{StaticResource H2}" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Sub}" Style="{StaticResource Small}" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>

          <Border Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Left" CornerRadius="6" Padding="10,4" Background="{Binding PillBg}">
            <TextBlock Text="{Binding StateText}" Foreground="{Binding StateFg}" FontWeight="SemiBold" FontSize="12"/>
          </Border>

          <TextBlock Grid.Column="3" Text="{Binding Measure}" Style="{StaticResource Mono}" VerticalAlignment="Center" Margin="14,0,14,0" TextWrapping="Wrap"/>

          <Button Grid.Column="4" Tag="{Binding Key}" MinWidth="118" VerticalAlignment="Center" Content="{Binding Action}">
            <Button.Style>
              <Style TargetType="Button" BasedOn="{StaticResource Btn}">
                <Style.Triggers>
                  <DataTrigger Binding="{Binding Action}" Value="">
                    <Setter Property="Visibility" Value="Collapsed"/>
                  </DataTrigger>
                </Style.Triggers>
              </Style>
            </Button.Style>
          </Button>
        </Grid>
      </Border>
    </DataTemplate>

    <DataTemplate x:Key="SettingRow">
      <Grid Margin="0,0,0,11">
        <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="{Binding Title}" Style="{StaticResource Body}" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,14,0"/>
        <ContentPresenter Grid.Column="1" Content="{Binding Control}" VerticalAlignment="Center"/>
      </Grid>
    </DataTemplate>
  </Window.Resources>

  <Grid Background="{StaticResource Bgc}">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

    <!-- UST BAR -->
    <Border Grid.Row="0" Background="{StaticResource Side}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="22,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="34" Height="34" CornerRadius="9" Background="#1D2733" Margin="0,0,12,0">
            <Ellipse x:Name="StatusDot" Width="12" Height="12" Fill="#98A0AA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="RemoteWatchdog" Style="{StaticResource H1}" FontSize="17"/>
            <TextBlock x:Name="TxtSubtitle" Text=" kontrol yukleniyor..." Style="{StaticResource Small}"/>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,12,0">
          <Border x:Name="RoleBadge" Background="#1D2733" CornerRadius="14" Padding="12,6" Margin="0,0,10,0">
            <TextBlock x:Name="TxtRole" Text="" Foreground="{StaticResource Ok}" FontWeight="SemiBold" FontSize="11.5"/>
          </Border>
          <Border x:Name="Pill" Background="#1D2733" CornerRadius="14" Padding="14,6">
            <TextBlock x:Name="TxtPill" Text="..." Foreground="{StaticResource Mut}" FontWeight="SemiBold" FontSize="12.5"/>
          </Border>
          <Border x:Name="NextBadge" Background="#1D2733" CornerRadius="14" Padding="12,6" Margin="10,0,0,0">
            <TextBlock x:Name="TxtNext" Text="Otomatik: -" Foreground="{StaticResource Mut}" FontWeight="SemiBold" FontSize="11.5"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnCheck" Content="Şimdi denetle" Style="{StaticResource BtnAccent}" Margin="0,0,8,0"/>
          <Button x:Name="BtnReboot" Content="Yeniden başlat" Style="{StaticResource BtnDanger}"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- GOVDE -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- KENAR CUBUGU -->
      <Border Grid.Column="0" Background="{StaticResource Side}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0" Padding="14,18">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <Button x:Name="NavConn" Content="Bağlantılar" Style="{StaticResource Nav}" Tag="conn" Margin="0,0,0,4"/>
            <Button x:Name="NavOverview" Content="Genel durum" Style="{StaticResource Nav}" Tag="overview" Margin="0,0,0,4"/>
            <Button x:Name="NavActions" Content="Bekleyen işler" Style="{StaticResource Nav}" Tag="actions" Margin="0,0,0,4"/>
            <Button x:Name="NavSettings" Content="Ayarlar" Style="{StaticResource Nav}" Tag="settings" Margin="0,0,0,4"/>
            <Button x:Name="NavLog" Content="Günlük" Style="{StaticResource Nav}" Tag="log" Margin="0,0,0,4"/>
          </StackPanel>
          <StackPanel Grid.Row="2">
            <Border Style="{StaticResource CardStyle}" Padding="12,10">
              <StackPanel>
                <TextBlock x:Name="TxtBlackout" Text="Blackout: -" Style="{StaticResource Small}"/>
                <TextBlock x:Name="TxtTaskState" Text="Gorev: -" Style="{StaticResource Small}" Margin="0,4,0,0"/>
                <TextBlock x:Name="TxtUptime" Text="Uptime: -" Style="{StaticResource Small}" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
            <Button x:Name="BtnDiag" Content="Teşhis raporu üret" Style="{StaticResource Btn}" Margin="0,10,0,0"/>
            <Button x:Name="BtnInstall" Content="Watchdog kur" Style="{StaticResource Btn}" Margin="0,8,0,0"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- ICERIK -->
      <Grid Grid.Column="1">
        <!-- BAGLANTILAR -->
        <ScrollViewer x:Name="PageConn" VerticalScrollBarVisibility="Auto" Padding="22,20">
          <StackPanel>
            <TextBlock Text="Bağlantılar" Style="{StaticResource H1}" Margin="0,0,0,4"/>
            <TextBlock x:Name="TxtConnSub" Text="" Style="{StaticResource Small}" Margin="0,0,0,16"/>
            <ItemsControl x:Name="ConnList"/>
          </StackPanel>
        </ScrollViewer>

        <!-- GENEL -->
        <ScrollViewer x:Name="PageOverview" VerticalScrollBarVisibility="Auto" Padding="22,20">
          <StackPanel>
            <TextBlock Text="Genel durum" Style="{StaticResource H1}" Margin="0,0,0,4"/>
            <TextBlock x:Name="TxtOverviewSub" Text="" Style="{StaticResource Small}" Margin="0,0,0,16"/>
            <ItemsControl x:Name="Cards">
              <ItemsControl.ItemsPanel>
                <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
              </ItemsControl.ItemsPanel>
            </ItemsControl>
            <Border Style="{StaticResource CardStyle}" Margin="0,4,0,0">
              <StackPanel>
                <TextBlock Text="Ortam" Style="{StaticResource H2}" Margin="0,0,0,10"/>
                <TextBlock x:Name="TxtEnv" Style="{StaticResource Mono}" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- BEKLEYEN ISLER -->
        <ScrollViewer x:Name="PageActions" VerticalScrollBarVisibility="Auto" Padding="22,20" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="Bekleyen işler" Style="{StaticResource H1}" Margin="0,0,0,4"/>
            <TextBlock x:Name="TxtActionsSub" Text="" Style="{StaticResource Small}" Margin="0,0,0,16"/>
            <ItemsControl x:Name="ActionList"/>
            <Border Style="{StaticResource CardStyle}" Background="#1A1512" BorderBrush="#4A3410">
              <StackPanel>
                <TextBlock Text="Zorla kapatma" Style="{StaticResource H2}" Foreground="{StaticResource Warn}" Margin="0,0,0,6"/>
                <TextBlock Style="{StaticResource Small}" TextWrapping="Wrap"
                           Text="Blackout saatlerinde (varsayilan 18:00-08:00 ve Cumartesi-Pazar) Word/Excel/PPT zorla kapatilip makine yeniden baslatilir. Diger saatlerde yalnizca bilgilendirilir ve karar size kalir."/>
                <Button x:Name="BtnForceNow" Content="Simdi zorla kapat ve yeniden baslat" Style="{StaticResource BtnDanger}" HorizontalAlignment="Left" Margin="0,12,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- AYARLAR -->
        <ScrollViewer x:Name="PageSettings" VerticalScrollBarVisibility="Auto" Padding="22,20" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="Ayarlar" Style="{StaticResource H1}" Margin="0,0,0,4"/>
            <TextBlock Text="Kaydettiginizde config.json guncellenir; bir sonraki denetimde gecerli olur." Style="{StaticResource Small}" Margin="0,0,0,16"/>
            <StackPanel x:Name="SettingsPanel"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="BtnSave" Content="Ayarları kaydet" Style="{StaticResource BtnAccent}" Margin="0,0,10,0"/>
              <Button x:Name="BtnReload" Content="Formu yenile" Style="{StaticResource Btn}"/>
              <TextBlock x:Name="TxtSaved" Text="" Style="{StaticResource Small}" VerticalAlignment="Center" Margin="14,0,0,0" Foreground="{StaticResource Ok}"/>
            </StackPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- GUNLUK -->
        <Grid x:Name="PageLog" Visibility="Collapsed" Margin="22,20">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
            <TextBlock Text="Günlük" Style="{StaticResource H1}" Margin="0,0,16,0" VerticalAlignment="Center"/>
            <Button x:Name="BtnLogRefresh" Content="Yenile" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
            <Button x:Name="BtnLogCopy" Content="Kopyala" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
            <Button x:Name="BtnLogOpen" Content="Dosyayı aç" Style="{StaticResource Btn}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource CardStyle}" Background="#0C0E11">
            <TextBox x:Name="TxtLog" Background="Transparent" Foreground="#C9D1D9" BorderThickness="0"
                     FontFamily="Cascadia Mono, Consolas" FontSize="11.5" IsReadOnly="True"
                     TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

function Get-HelpTopics {
    return @(
        [pscustomobject]@{ Title = 'Ayar yardımı 1/11 - Kontrol aralığı'; Text = 'Watchdog bu aralıkla bağlantıları kontrol eder. Varsayılan 5 dakika. Uzaktaki makine için 5 dk yeterlidir; çok kısa aralık gereksiz log ve trafik üretir.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 2/11 - Restart politikası'; Text = 'blackout = sadece tanımlı saatlerde restart eder. always = her koşulda. never = hiçbir zaman otomatik restart yapmaz, yalnızca bilgilendirir. Önerilen: blackout.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 3/11 - Blackout penceresi'; Text = 'Bu saatlerde program kendi kararıyla yeniden başlatabilir. Günüp saatleri 18:00, bitiş 8:00 girilirse gece yarısına sarar. Dışındaki saatlerde zorla kapatma olmaz, sadece bilgilendirme yapılır.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 4/11 - Tam gün blackout'; Text = 'Cumartesi ve Pazar gibi günlerin tamamı. Bir günü kaldırmak için o günün düğmesini kapatın. Boş bırakılırsa hafta sonu da mesai gibi korunur.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 5/11 - Tatil modu'; Text = 'full = resmi/dini tatiller tam gün blackout olur. default = normal saat kuralı uygulanır. none = tatiller yok sayılır. Tatil listesine her satır YYYY-AA-GG biçiminde gün ekleyin.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 6/11 - Google Remote Desktop kaydı'; Text = 'CRD kartı kırmızıysa cihaz Google hesabına kayıtlı değildir. Kayıt, bağlandığınız cihazdaki eklentiden değil, kendi makinesinden yapılır: remotedesktop.google.com/headless -> "Set up remote access" ile ad ve PIN alınır, sonra istemci cihazda Machines -> + ile eklenir. Tarayıcıda açık olan Google oturumu bu kaydı oluşturmaz.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 7/11 - Devre kesici (sonsuz restart koruması)'; Text = 'Otomatik restart sonsuz döngüye girmesin diye iki koruma var: 24 saatte en fazla MaxRestartsPerDay (varsayılan 3) kez restart edilir ve iki restart arasında RebootCooldownMinutes (varsayılan 60) dakika beklenir. Sınıra ulaşılınca otomatik restart durur, ekranda ve Telegram''da uyarı gider; bu süreden sonra yeniden denenir.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 8/11 - Sunucu modu'; Text = 'Açık: uyku, hibernasyon ve Fast Startup kapatılır, ağ adaptörü uykuya girmez. Dizüstü kullanıyorsanız kapatın (kurulumda -KeepSleep). Kapalıyken bu kontrol atlanır, zorla restart baskısı oluşmaz.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 9/11 - Belge koruma'; Text = 'Word/Excel belgeleri 2 dakikada bir otomatik kaydedilir. Restart öncesi kaydedilip kapatılır. Kaydedilemeyen belge varsa restart iptal edilir. "Daima zorla kapatma" bu korumayı baypaslar.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 10/11 - Ağ onarımı'; Text = 'Ağ bozulursa sırayla DNS, DHCP, adaptör/sürücü ve winsock onarımı uygulanır. Kademe 5 gerektiğinde restart önerilir. 4. kademe adaptörü sıfırlar; uzak erişiminiz tamamen kesilebilir.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 11/11 - Bildirimler ve dış izleme'; Text = 'Telegram token ve chat id girerseniz sorunlar anında telefonunuza düşer. Dış izleme (heartbeat) ise tersini yakalar: makine sessizce kapanırsa. healthchecks.io ücretsiz hesabı açıp ping adresini Ayarlar > Bildirim > Healthchecks alanına yazın; ya da install klasöründeki github-action-machine-health.yml dosyasını bir repoya kopyalayın (GitHub 15 dakikada bir kontrol eder, e-posta ve Telegram ile haber verir). Tepsi bildirimleri varsayılan olarak yalnızca kritik olayları gösterir.' }
    )
}

function Start-HelpTour {
    param([switch]$Restart)
    $topics = @(Get-HelpTopics)
    if ($topics.Count -eq 0) { return 0 }
    if (-not $Restart -and $script:HelpIndex -ge 0) { return $script:HelpIndex }
    $script:HelpTopics = $topics
    $script:HelpIndex = 0
    if ($script:HelpTimer) { try { $script:HelpTimer.Stop() } catch { } }
    $script:HelpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:HelpTimer.Interval = [TimeSpan]::FromSeconds(9)
    $script:HelpTimer.Add_Tick({
            if ($null -eq $script:HelpTopics -or $script:HelpIndex -ge $script:HelpTopics.Count) {
                try { $script:HelpTimer.Stop() } catch { }
                $script:HelpIndex = -1
                New-ItemProperty -Path $RunKey -Name ($RunName + 'Help') -Value (Get-Date).ToString('yyyy-MM-dd') -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Trace 'ayarlar yardım turu tamamlandi'
                return
            }
            $t = $script:HelpTopics[$script:HelpIndex]
            $script:HelpIndex = $script:HelpIndex + 1
            Show-Balloon -Title $t.Title -Text $t.Text -Icon 'Info' -Always
        })
    $script:HelpTimer.Start()
    Write-Trace ('ayarlar yardım turu başladı: ' + $topics.Count + ' konu')
    return 0
}

function New-Toggle {
    param([string]$Label = '', [bool]$On)
    $b = New-Object System.Windows.Controls.Button
    $b.Tag = [bool]$On
    $b.Content = $(if ($Label) { $Label } elseif ($On) { 'AÇIK' } else { 'KAPALI' })
    $b.Width = 92
    $b.Margin = New-Object System.Windows.Thickness(0)
    $style = $script:Win.TryFindResource('ToggleBtn')
    if ($style) { $b.Style = $style }
    $b.Background = $(if ($On) { Bx 'Ok' } else { Bx 'Card2' })
    $b.Foreground = $(if ($On) { Bx '#0B1220' } else { Bx 'Muted' })
    $b.BorderBrush = Bx 'Line'
    $tgl = $b
    $tgl.add_Click({
            $btn = $tgl
            $btn.Tag = -not ([bool]$btn.Tag)
            $on = [bool]$btn.Tag
            $tip = [string]$btn.ToolTip
            if ($tip -like 'days|*') { $btn.Content = $tip.Split('|')[2] }
            else { $btn.Content = $(if ($on) { 'AÇIK' } else { 'KAPALI' }) }
            $btn.Background = $(if ($on) { Bx 'Ok' } else { Bx 'Card2' })
            $btn.Foreground = $(if ($on) { Bx '#0B1220' } else { Bx 'Muted' })
        }.GetNewClosure())
    return $b
}

function New-TextBox {
    param([switch]$Multi, [int]$Width = 240, [int]$Height = 60, [string]$Text = '')
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $Text
    $t.Width = $Width
    if ($Multi) { $t.Height = $Height; $t.AcceptsReturn = $true; $t.TextWrapping = 'Wrap'; $t.VerticalScrollBarVisibility = 'Auto' } else { $t.Height = 30 }
    $t.Background = Bx '#0E1013'
    $t.Foreground = Bx 'Text'
    $t.BorderBrush = Bx 'Line'
    $t.BorderThickness = New-Object System.Windows.Thickness(1)
    $t.Padding = New-Object System.Windows.Thickness(8, 4, 8, 4)
    $t.FontSize = 12.5
    return $t
}

function New-Combo {
    param([string[]]$Items, [string]$Selected)
    $c = New-Object System.Windows.Controls.ComboBox
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    $c.Width = 200
    $c.Height = 30
    $c.SelectedItem = $Selected
    $c.Background = Bx '#0E1013'
    $c.Foreground = Bx 'Text'
    $c.BorderBrush = Bx 'Line'
    $c.Padding = New-Object System.Windows.Thickness(8, 4, 8, 4)
    return $c
}

function Get-Connections {
    $st = Get-StatusInfo
    $hj = $st.Host
    $cj = $st.Client
    $rows = New-Object System.Collections.ArrayList
    $col = @{ ok = $script:C.Ok; warn = $script:C.Warn; bad = $script:C.Bad; none = $script:C.Muted }
    $fg = @{ ok = '#0B1220'; warn = '#1A1206'; bad = '#1A0B0B'; none = '#0F1114' }

    function Add-Conn {
        param([string]$Name, [string]$Sub, [string]$Level, [string]$StateText, [string]$Measure, [string]$Key = '', [string]$Action = '')
        $lvl = $Level
        [void]$rows.Add([pscustomobject]@{
                Name = $Name; Sub = $Sub; StateText = $StateText; Measure = $Measure; Key = $Key; Action = $Action
                Brush = Bx $col[$lvl]; PillBg = Bx $col[$lvl]; StateFg = Bx $fg[$lvl]
            })
    }

    if (-not $hj) {
        Add-Conn 'Watchdog' 'hic calismadi' 'none' 'BİLİNMİYOR' 'last-run.json yok' 'host' 'Kur'
        return $rows
    }

    $byName = @{}
    foreach ($c in @($hj.checks)) { $byName[[string]$c.name] = $c }
    $mt = @{}
    $nw = $byName['Ag katmani']
    if ($nw -and $nw.metrics) { foreach ($k in $nw.metrics.PSObject.Properties.Name) { $mt[$k] = $nw.metrics.$k } }
    $inet = $byName['Internet']
    if ($inet -and $inet.metrics) { foreach ($k in $inet.metrics.PSObject.Properties.Name) { $mt[$k] = $inet.metrics.$k } }

    if ($inet) {
        $lvl = if ($inet.ok) { 'ok' } else { 'bad' }
        Add-Conn 'İnternet erişimi' 'genel çıkış (HTTPS 204)' $lvl $(if ($inet.ok) { 'BAGLI' } else { 'YOK' }) ('https ' + [string]$mt['google204ms'] + ' ms, mtalk ' + [string]$mt['mtalk443ms'] + ' ms') 'run' 'Yeniden denetle'
    }
    if ($mt.ContainsKey('ip443state')) {
        $lvl = if ($mt['ip443state'] -eq 'acik') { 'ok' } else { 'bad' }
        Add-Conn 'IP erişimi' '1.1.1.1:443 (DNS bağığı değil)' $lvl $(if ($lvl -eq 'ok') { 'BAGLI' } else { 'YOK' }) ([string]$mt['ip443'] + ' ms')
    }
    if ($mt.ContainsKey('dnsstate')) {
        $lvl = if ($mt['dnsstate'] -eq 'cozuldu') { 'ok' } else { 'bad' }
        Add-Conn 'DNS çözümlemesi' 'remotedesktop.google.com' $lvl $(if ($lvl -eq 'ok') { 'ÇÖZÜLDÜ' } else { 'HATA' }) ([string]$mt['dnsms'] + ' ms')
    }
    if ($mt.ContainsKey('signalstate')) {
        $lvl = if ($mt['signalstate'] -eq 'acik') { 'ok' } else { 'bad' }
        Add-Conn 'CRD sinyal yolu' 'mtalk.google.com:443' $lvl $(if ($lvl -eq 'ok') { 'BAGLI' } else { 'KAPALI' }) ([string]$mt['signalms'] + ' ms')
    }
    if ($mt.ContainsKey('link')) {
        Add-Conn 'Ağ adaptörü' ([string]$mt['link']) 'none' 'BİLGİ' ('DHCP=' + $(if ($mt['dhcp']) { 'acik' } else { 'kapali' }) + ', TIME_WAIT=' + [string]$mt['timewait'])
    }

    $crd = $byName['CRD servisi']
    if ($crd) {
        $m = @{}
        if ($crd.metrics) { foreach ($k in $crd.metrics.PSObject.Properties.Name) { $m[$k] = $crd.metrics.$k } }
        $registered = ($m['hostId'] -eq 'var')
        $lvl = if (-not $registered) { 'bad' } elseif ($crd.ok) { 'ok' } else { 'warn' }
        Add-Conn 'Google Remote Desktop kaydı' 'cihaz Google hesabında kayıtlı mı' $lvl $(if ($registered) { 'KAYITLI' } else { 'KAYITSIZ' }) ('host_id=' + $(if ($registered) { 'var' } else { 'YOK' })) 'crd' 'CRD sayfası'
        $gc = [int]($(if ($m.ContainsKey('googleBaglanti')) { $m['googleBaglanti'] } else { 0 }))
        $lvl2 = if ($gc -gt 0) { 'ok' } elseif ($registered) { 'warn' } else { 'none' }
        Add-Conn 'CRD canlı bağlantısı' 'CRD daemon Google bağlantısı' $lvl2 $(if ($gc -gt 0) { 'BAGLI' } else { 'YOK' }) ('baglanti=' + $gc + ', servis=' + [string]$m['servis'] + ', yas=' + [string]$m['yasSaat'] + 'sa') 'run' 'Yeniden denetle'
    }

    $rdp = $byName['Windows RDP']
    if ($rdp) {
        $lvl = if ($rdp.ok) { 'ok' } else { 'bad' }
        $fw = 0
        if ([string]$rdp.detail -match 'firewall kapali=(\d+)') { $fw = [int]$matches[1] }
        Add-Conn 'Windows RDP' '3389 + firewall' $lvl $(if ($rdp.ok) { 'HAZIR' } else { 'KAPALI' }) ('firewall kapali kural=' + $fw) 'log' 'Logları aç'
    }

    $tun = $byName['VS Code Tunnel']
    if ($tun) {
        $tunLvl = if ($tun.skipped -or $tun.ok) { 'ok' } else { 'warn' }
        $tunState = if ($tun.skipped) { 'İZLENMİYOR' } elseif ($tun.ok) { 'ÇALIŞIYOR' } else { 'KAPALI' }
        Add-Conn 'VS Code Tunnel' 'vscode.dev/tunels' $tunLvl $tunState ([string]$tun.detail) 'log' 'Logları aç'
    }

    $cfg = Get-HostConfig
    if ($cfg.HeartbeatUrl) {
        Add-Conn 'Dış izleme (heartbeat)' 'healthchecks.io ping adresi' 'ok' 'TANIMLI' ([string]$cfg.HeartbeatUrl) 'log' 'Logları aç'
    } else {
        $hbMsg = 'Kurulmadı. Makine sessizce kapanırsa dışarıdan fark edilmez. Seçenek 1: healthchecks.io ücretsiz hesabı açın, ping adresini Ayarlar > Bildirim > Healthchecks alanına yazın. Seçenek 2 (üçüncü hesap gerekmez): install\github-action-machine-health.yml dosyasını bir repoya .github\workflows altına kopyalayın; GitHub 15 dakikada bir kontrol eder, erişilemezse e-posta ve Telegram ile haber verir.'
        Add-Conn 'Dış izleme (heartbeat)' 'healthchecks.io veya GitHub Actions' 'none' 'KAPALI - kurun' $hbMsg 'settings' 'Ayarlar'
    }

    $cfg = Get-HostConfig
    $panelChk = $byName['Kontrol paneli']
    if ($panelChk) {
        Add-Conn 'Kontrol paneli' 'panel süreci (restart sonrası oturumda)' $(if ($panelChk.ok) { 'ok' } else { 'warn' }) $(if ($panelChk.ok) { 'ÇALIŞIYOR' } else { 'KAPALI' }) ([string]$panelChk.detail) 'panelstart' 'Paneli başlat'
    }

    $role = Get-RoleInfo
    if ($role.ClientTask) {
        foreach ($t in @($role.Targets)) {
            $tname = [string]$t
            $found = $false
            foreach ($cc in @($cj.checks)) {
                if ([string]$cc.name -ne $tname) { continue }
                $found = $true
                $lvl = $(if ($cc.ok) { 'ok' } else { 'bad' })
                $msTxt = ''
                if ([string]$cc.detail -match '(\d+) ms') { $msTxt = 'gecikme ' + $matches[1] + ' ms' }
                Add-Conn $role.RemoteName $tname $lvl $(if ($cc.ok) { 'ULAŞILABİLİR' } else { 'ULAŞILAMIYOR' }) $(if ($msTxt) { $msTxt } else { [string]$cc.detail }) 'log' 'Logları aç'
            }
            if (-not $found) { Add-Conn $role.RemoteName $tname 'warn' 'BİLİNMİYOR' 'istemci bir tur calismadi' 'run' 'Şimdi denetle' }
        }
        $cjLvl = $(if ($cj -and $cj.ok) { 'ok' } else { 'bad' })
        Add-Conn 'İstemci kontrol hattı' $(if ($role.HostTask) { 'bu makine (istemci + host)' } else { 'bu makine (istemci)' }) $cjLvl $(if ($cj -and $cj.ok) { 'TAMAM' } else { 'SORUN' }) $(if ($cj) { [string]$cj.summary } else { 'istemci çalışmadı' }) 'log' 'Logları aç'
    } elseif ($cj) {
        Add-Conn 'İstemci kontrol hattı' 'bu makine (host + istemci)' $(if ($cj.ok) { 'ok' } else { 'warn' }) $(if ($cj.ok) { 'TAMAM' } else { 'EK BİLGİ' }) ([string]$cj.summary) 'log' 'Logları aç'
    }
    return $rows
}

function Format-ConnSubLine {
    param($Next)
    $s = $script:ConnSummary
    $line = ([string]$s.Ok + ' saglikli') + $(if ($s.Bad -gt 0) { '  |  ' + $s.Bad + ' sorunlu' } else { '' }) + $(if ($s.Info -gt 0) { '  |  ' + $s.Info + ' bilgi' } else { '' })
    if ($s.LastRun) { $line += '   -   olcumler ' + ([datetime]$s.LastRun).ToString('HH:mm:ss') + ' (' + (Format-ShortSpan ((Get-Date) - [datetime]$s.LastRun).TotalSeconds) + ' once)' }
    else { $line += '   -   olcum zamani bilinmiyor' }
    if ($script:CheckBusy) {
        $line += '   -   DENETLENIYOR (' + [int]((Get-Date) - $script:CheckBusySince).TotalSeconds + ' sn)'
    } elseif ($null -ne $Next -and $Next.Known -and $Next.RemainingSeconds -gt 0) {
        $line += '   -   sonraki otomatik denetim ' + $Next.Next.ToString('HH:mm:ss') + ' (' + [int][math]::Ceiling($Next.RemainingSeconds) + ' sn sonra)'
    } elseif ($null -ne $Next -and $Next.Known) {
        $line += '   -   otomatik denetim zamani geldi (' + [int][math]::Ceiling($Next.OverdueSeconds) + ' sn gecikme)'
    } else {
        $line += '   -   sonraki otomatik denetim bilinmiyor'
    }
    return $line
}

function Update-ConnSub {
    param($Next)
    $w = $script:Win
    if (-not $w) { return }
    $el = El $w 'TxtConnSub'
    if (-not $el) { return }
    $el.Text = (Format-ConnSubLine $Next)
    $el.Foreground = $(if ($script:ConnSummary.Bad -gt 0) { Bx 'Warn' } else { Bx 'Muted' })
}

function Update-Connections {
    $rows = Get-Connections
    $items = @()
    $okc = 0; $badc = 0; $info = 0
    foreach ($r in $rows) {
        $items += $r
        if ($r.StateText -in @('BİLGİ', 'BİLİNMİYOR')) { $info++ }
        elseif ($r.StateText -in @('YOK', 'KAPALI', 'KAYITSIZ', 'HATA')) { $badc++ }
        else { $okc++ }
    }
    $cl = El $script:Win 'ConnList'
    $cl.ItemsSource = $items
    $cl.ItemTemplate = $script:Win.Resources['ConnRow']
    $nx = Get-NextCheck
    $script:ConnSummary = @{ Ok = $okc; Bad = $badc; Info = $info; LastRun = $(if ($nx.Known) { $nx.Last } else { $null }) }
    Update-ConnSub $nx
}

function Update-Countdown {
    $w = $script:Win
    if (-not $w) { return }
    $txt = El $w 'TxtNext'
    if (-not $txt) { return }
    $badge = El $w 'NextBadge'
    $btn = El $w 'BtnCheck'
    if ($script:CheckBusy) {
        $el = [int]((Get-Date) - $script:CheckBusySince).TotalSeconds
        $txt.Text = 'Denetleniyor: ' + $el + ' sn'
        $txt.Foreground = Bx 'Accent'
        if ($badge) { $badge.ToolTip = 'Elle denetleme suruyor (' + $el + ' sn). Bitince baglantilar, genel durum ve bekleyen isler yenilenir.' }
        if ($btn) { $btn.Content = 'Denetleniyor... ' + $el + ' sn' }
        Update-ConnSub $null
        return
    }
    if ($btn -and ([string]$btn.Content) -ne 'Şimdi denetle') { $btn.Content = 'Şimdi denetle' }
    $n = Get-NextCheck
    $aralik = ([math]::Round([double]$n.IntervalMinutes, 1)).ToString()
    if (-not $n.Known) {
        $txt.Text = 'Otomatik: -'
        $txt.Foreground = Bx 'Muted'
        if ($badge) { $badge.ToolTip = 'Sonraki otomatik denetim bilinmiyor: last-run.json yok. Ayarlar sayfasindan "Watchdog kur" ile baslatin.' }
    } elseif ($n.RemainingSeconds -gt 0) {
        $txt.Text = 'Otomatik: ' + (Format-ShortSpan $n.RemainingSeconds) + ' (' + [int][math]::Ceiling($n.RemainingSeconds) + ' sn)'
        $txt.Foreground = Bx 'Muted'
        if ($badge) { $badge.ToolTip = 'Sonraki otomatik denetim: ' + $n.Next.ToString('HH:mm:ss') + '  (' + [int][math]::Ceiling($n.RemainingSeconds) + ' sn sonra)' + "`r`n" + 'Aralik: ' + $aralik + ' dk (' + $n.IntervalSource + ')   |   son kontrol: ' + $n.Last.ToString('HH:mm:ss') + '  (' + (Format-ShortSpan $n.AgeSeconds) + ' once, kaynak: ' + $n.Source + ')' }
    } elseif ($n.OverdueSeconds -le [math]::Max(90.0, ([double]$n.IntervalMinutes * 30.0))) {
        $txt.Text = 'Otomatik: bekleniyor (' + [int][math]::Ceiling($n.OverdueSeconds) + ' sn)'
        $txt.Foreground = Bx 'Info'
        if ($badge) { $badge.ToolTip = 'Denetim zamani geldi (' + [int][math]::Ceiling($n.OverdueSeconds) + ' sn once): zamanlanmis gorev birazdan calisir. Son kontrol: ' + $n.Last.ToString('HH:mm:ss') + '   |   aralik: ' + $aralik + ' dk (' + $n.IntervalSource + ')' }
    } else {
        $txt.Text = 'Otomatik: gecikti (' + (Format-ShortSpan $n.AgeSeconds) + ')'
        $txt.Foreground = Bx 'Warn'
        $hj = Get-Json $HostJson
        if ($badge) { $badge.ToolTip = 'Zamanlanmis gorev calismiyor olabilir: son kontrol ' + $n.Last.ToString('HH:mm:ss') + ' (' + (Format-ShortSpan $n.AgeSeconds) + ' once), beklenen aralik ' + $aralik + ' dk (' + $n.IntervalSource + '). Gorev durumu: ' + $(if ($hj) { [string]$hj.taskState } else { 'bilinmiyor' }) + '. Cozum: "Şimdi denetle" ile elle calistirin.' }
    }
    Update-ConnSub $n
}

function Invoke-ConnAction {
    param([string]$Key)
    switch ($Key) {
        'host' { Invoke-Script -Path $HostScript -Args @('-Install') }
        'run' { Start-ManualCheck }
        'crd' { Start-Process 'https://remotedesktop.google.com/headless' }
        'docs' { Invoke-Script -Path $HostDocs -Args @('-Force') -Wait }
        'log' { Show-Page 'log'; Update-Log }
        'settings' { Show-Page 'settings'; Build-Settings }
        'reboot' {
            $r = [System.Windows.MessageBox]::Show('Makine yeniden baslatilsin mi? Kaydedilmemis belge varsa once kaydedilir.', 'RemoteWatchdog', 'YesNo', 'Question')
            if ($r -eq 'Yes') { Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait }
        }
        default { }
    }
}

function Start-ManualCheck {
    if ($script:CheckBusy) {
        [System.Windows.MessageBox]::Show(('Denetleme zaten suruyor (' + [int]((Get-Date) - $script:CheckBusySince).TotalSeconds + ' sn). Bitmesini bekleyin; kalan sure sag ustteki sayacta gorunur.'), 'RemoteWatchdog') | Out-Null
        return
    }
    $procs = New-Object System.Collections.ArrayList
    foreach ($p in @($HostScript, $ClientScript)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $p + '"'))
        try { [void]$procs.Add((Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden -PassThru)) }
        catch { Write-Trace ('denetleme baslatilamadi (' + $p + '): ' + $_.Exception.Message) }
    }
    if ($procs.Count -eq 0) { [System.Windows.MessageBox]::Show('Denetleme baslatilamadi: watchdog betigi bulunamadi.', 'RemoteWatchdog') | Out-Null; return }
    $script:CheckBusy = $true
    $script:CheckBusySince = Get-Date
    $script:CheckProcs = @($procs)
    Write-Trace ('elle denetleme basladi (' + $script:CheckProcs.Count + ' surec) - arka planda, arayuz donmaz')
    Update-Countdown
}

function Test-ManualCheckRunning {
    if (-not $script:CheckBusy) { return $false }
    if (@($script:CheckProcs).Count -eq 0) { return $true }
    return (@($script:CheckProcs | Where-Object { $_.HasExited -eq $false }).Count -gt 0)
}

function Complete-ManualCheck {
    $el = [int]((Get-Date) - $script:CheckBusySince).TotalSeconds
    $script:CheckBusy = $false
    $script:CheckProcs = @()
    $btn = El $script:Win 'BtnCheck'
    if ($btn) { $btn.Content = 'Şimdi denetle' }
    Resolve-CheckInterval -Force | Out-Null
    Update-Connections
    Update-Overview
    Update-Actions
    if ($script:Page -eq 'log') { Update-Log }
    Refresh-Icon
    Update-Countdown
    Write-Trace ('elle denetleme bitti (' + $el + ' sn) - baglanti/genel durum/bekleyen is/gunluk yenilendi')
}

function Show-Page {
    param([string]$Name)
    $script:Page = $Name
    foreach ($n in @('conn', 'overview', 'actions', 'settings', 'log')) {
        (El $script:Win ('Page' + $n[0].ToString().ToUpper() + $n.Substring(1))).Visibility = $(if ($n -eq $Name) { 'Visible' } else { 'Collapsed' })
    }
    foreach ($n in @('NavConn', 'NavOverview', 'NavActions', 'NavSettings', 'NavLog')) {
        $b = El $script:Win $n
        $on = ($b.Tag -eq $Name)
        $b.Foreground = $(if ($on) { Bx 'Text' } else { Bx 'Muted' })
        $b.Background = $(if ($on) { Bx '#1D2127' } else { 'Transparent' })
    }
    if ($Name -eq 'log') { Update-Log }
}

function Update-Overview {
    $st = Get-StatusInfo
    $hj = $st.Host
    $cj = $st.Client
    $color = if ($null -eq $hj -and $null -eq $cj) { $script:C.Muted } elseif ($st.Bad -gt 0) { $script:C.Bad } else { $script:C.Ok }
    (El $script:Win 'StatusDot').Fill = Bx $color
    (El $script:Win 'Pill').Background = Bx '#1D2733'
    $pill = El $script:Win 'TxtPill'
    $pill.Foreground = Bx $color
    $pill.Text = $(if ($null -eq $hj -and $null -eq $cj) { 'VERI YOK' } elseif ($st.Bad -gt 0) { ([string]$st.Bad + ' SORUN') } else { 'AYAKTA' })
    $last = 'kontrol yok'
    if ($st.Age) { $last = 'son kontrol ' + [math]::Round($st.Age.TotalMinutes) + ' dk once' }
    $role = Get-RoleInfo
    (El $script:Win 'TxtSubtitle').Text = $role.RoleText + '  |  ' + $env:COMPUTERNAME + '  |  ' + $last
    (El $script:Win 'TxtRole').Text = $role.RoleText
    (El $script:Win 'TxtRole').Foreground = $(switch ($role.Role) { 'host' { Bx 'Ok' } 'client' { Bx 'Info' } 'both' { Bx 'Accent' } default { Bx 'Warn' } })
    (El $script:Win 'RoleBadge').ToolTip = $role.Tip
    (El $script:Win 'TxtOverviewSub').Text = $(if ($role.ClientTask -and -not $role.HostTask) { 'Izlenen uzak makine: ' + $role.RemoteName + '  (' + (@($role.Targets) -join ', ') + ')' } elseif ($hj) { [string]$hj.summary } else { 'Watchdog hic calismadi. "Watchdog kur" ile baslat.' })

    $cards = New-Object System.Collections.ArrayList
    $labels = @{
        'Internet' = 'İnternet erişimi'
        'Ag katmani' = 'Ağ katmanı (IP/DNS/HTTPS)'
        'CRD servisi' = 'Google Remote Desktop (CRD)'
        'Guc/uyku ayarlari' = 'Güç ve uyku ayarları'
        'Kontrol paneli' = 'Kontrol paneli'
    }
    $hints = @{
        'CRD servisi' = 'Kırmızıysa bu cihaz Google hesabına kayıtlı değil (host.json yok). Kayıt, bağlandığınız cihazdaki eklentiden değil, bu makinede tarayıcıdan yapılır: remotedesktop.google.com/headless -> "Set up remote access" (Brave veya Chrome; seçenek çıkmazsa Chrome kurun). Sonra kendi cihazınızda Machines -> + ile ad ve PIN girin.'
    }
    if ($hj) {
        foreach ($c in @($hj.checks)) {
            $col = if ($c.skipped) { 'Muted' } elseif ($c.ok) { 'Ok' } else { 'Bad' }
            $nm = [string]$c.name
            if ($labels.ContainsKey($nm)) { $nm = $labels[$nm] }
            $rp = [string]$c.repair
            if ($hints.ContainsKey([string]$c.name)) { $rp = $hints[[string]$c.name] }
            [void]$cards.Add([pscustomobject]@{ Title = $nm; Detail = [string]$c.detail; Repair = $rp; Brush = Bx $col })
        }
    }
    if ($cj) {
        foreach ($c in @($cj.checks)) {
            $col = if ($c.ok) { 'Ok' } else { 'Bad' }
            $nm = [string]$c.name
            if ($labels.ContainsKey($nm)) { $nm = $labels[$nm] }
            [void]$cards.Add([pscustomobject]@{ Title = ($nm + ' (istemci)'); Detail = [string]$c.detail; Repair = ''; Brush = Bx $col })
        }
    }
    $ic = El $script:Win 'Cards'
    $ic.ItemsSource = $cards
    $ic.ItemTemplate = $script:Win.Resources['StatusCard']

    $env = New-Object System.Collections.ArrayList
    if ($hj) {
        [void]$env.Add('son kontrol    : ' + $hj.generated)
        [void]$env.Add('uptime         : ' + [math]::Round([double]$hj.uptimeMinutes / 60, 1) + ' saat')
        [void]$env.Add('kamu IP        : ' + $(if ($hj.publicIp) { $hj.publicIp } else { '?' }))
        [void]$env.Add('gorev           : ' + $hj.taskState + $(if ($hj.taskInstalled) { '' } else { '  (kurulu degil)' }))
        [void]$env.Add('blackout        : ' + $(if ($hj.inBlackout) { 'AKTIF - zorla kapatma izinli' } else { 'kapali - sadece bilgilendirme' }))
        [void]$env.Add('tatil           : ' + $(if ($hj.isHoliday) { 'evet' } else { 'hayir' }) + '  (mod: ' + $hj.config.holidayMode + ')')
        [void]$env.Add('restart         : ' + $hj.config.restartPolicy + '  |  blackout ' + $hj.config.blackoutStart + ':00-' + $hj.config.blackoutEnd + ':00  |  tam gun: ' + ((@($hj.config.blackoutFullDays)) -join ','))
        [void]$env.Add('daima zorla     : ' + $(if ($hj.config.forceRestartAlways) { 'ACIK' } else { 'kapali' }) + $(if ($hj.config.forceRestartUntil) { '  (' + $hj.config.forceRestartUntil + ')' } else { '' }))
        [void]$env.Add('ardisik hata    : ' + $hj.state.consecutiveFailures + '  |  ag onarim kademesi: ' + $hj.state.netRepairRung)
        [void]$env.Add('tatil listesi   : ' + ((@($hj.config.holidays)) -join ', '))
        $nx = Get-NextCheck
        if ($nx.Known) { [void]$env.Add('sonraki kontrol : ' + $nx.Next.ToString('HH:mm:ss') + '  (kalan ' + [int][math]::Ceiling($nx.RemainingSeconds) + ' sn, aralik ' + ([math]::Round([double]$nx.IntervalMinutes, 1)) + ' dk - ' + $nx.IntervalSource + ')') }
        else { [void]$env.Add('sonraki kontrol : bilinmiyor (last-run.json yok)') }
    } else { [void]$env.Add('last-run.json bulunamadi: ' + $HostJson) }
    (El $script:Win 'TxtEnv').Text = ($env -join "`n")

    (El $script:Win 'TxtBlackout').Text = $(if ($hj -and $hj.inBlackout) { 'Blackout: AKTIF' } else { 'Blackout: kapali' })
    (El $script:Win 'TxtTaskState').Text = 'Gorev: ' + $(if ($hj) { $hj.taskState } else { 'yok' })
    $up = '-'
    if ($hj) { $up = ([math]::Round(([double]$hj.uptimeMinutes) / 60.0, 1)).ToString() + ' sa' }
    (El $script:Win 'TxtUptime').Text = 'Uptime: ' + $up
}

function Update-Actions {
    $list = Get-Actions
    $col = @{ ok = $script:C.Ok; warn = $script:C.Warn; bad = $script:C.Bad; info = $script:C.Muted }
    $items = @()
    foreach ($a in $list) {
        $items += [pscustomobject]@{ Title = [string]$a.Title; Detail = [string]$a.Detail; Action = [string]$a.Action; Key = [string]$a.Key; Brush = Bx $col[[string]$a.Level] }
    }
    $al = El $script:Win 'ActionList'
    $al.ItemsSource = $items
    $al.ItemTemplate = $script:Win.Resources['ActionRow']


    (El $script:Win 'TxtActionsSub').Text = (@($list | Where-Object { $_.Level -ne 'ok' }).Count.ToString() + ' is bekliyor')
}

function Update-Log {
    $lines = New-Object System.Collections.ArrayList
    foreach ($lf in @($HostLog, $ClientLog)) {
        if (Test-Path -LiteralPath $lf) {
            [void]$lines.Add('===== ' + $lf + ' =====')
            foreach ($l in @(Get-Content -LiteralPath $lf -Tail 200 -ErrorAction SilentlyContinue)) { [void]$lines.Add([string]$l) }
        }
    }
    if ($lines.Count -eq 0) { [void]$lines.Add('(log dosyasi yok)') }
    (El $script:Win 'TxtLog').Text = ($lines -join "`n")
    (El $script:Win 'TxtLog').ScrollToEnd()
}

$script:Defs = @(
    @{ Sec = 'ZAMANLAMA'; Type = 'section' }
    @{ Sec = 'Zamanlama'; Key = 'IntervalMinutes'; Title = 'Kontrol aralığı (dakika)'; Type = 'int' }
    @{ Sec = 'Zamanlama'; Key = 'AlertRepeatHours'; Title = 'Aynı alarm için tekrar aralığı (saat)'; Type = 'int' }
    @{ Sec = 'Zamanlama'; Key = 'NotifyRepeatHours'; Title = 'Kullanıcı bilgilendirme tekrar aralığı (saat)'; Type = 'int' }

    @{ Sec = 'RESTART POLITIKASI'; Type = 'section' }
    @{ Sec = 'Restart'; Key = 'RestartPolicy'; Title = 'Restart politikası'; Type = 'enum'; Options = @('blackout', 'always', 'never') }
    @{ Sec = 'Restart'; Key = 'BlackoutEnabled'; Title = 'Blackout penceresi (dışında sadece bilgilendirilir)'; Type = 'bool' }
    @{ Sec = 'Restart'; Key = 'BlackoutStart'; Title = 'Blackout başlangıç saati'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'BlackoutEnd'; Title = 'Blackout bitiş saati (geceye sarar)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'BlackoutFullDays'; Title = 'Tam gün blackout (hafta sonu)'; Type = 'days' }
    @{ Sec = 'Restart'; Key = 'BlackoutNights'; Title = 'Blackout geceleri'; Type = 'days' }
    @{ Sec = 'Restart'; Key = 'RebootAfterFailedCycles'; Title = 'Kaç başarısız denemeden sonra restart'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'RebootDelaySeconds'; Title = 'Restart gecikmesi (saniye)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'MaxRestartsPerDay'; Title = '24 saatte en fazla restart (0 = sınırsız)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'RebootCooldownMinutes'; Title = 'İki restart arası bekleme (dakika)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'HealthyMinutesToReset'; Title = 'Bu kadar sağlıklı kalınca bütçe sıfırlansın (dk)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'MinUptimeMinutes'; Title = 'Minimum uptime (dk, yeni açılan makine için bekle)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'RebootSkipIfUnregistered'; Title = 'CRD kayıtsızken restart etme'; Type = 'bool' }
    @{ Sec = 'Restart'; Key = 'ForceRestartAlways'; Title = 'DAIMA zorla kapat (saat fark etmez)'; Type = 'bool' }
    @{ Sec = 'Restart'; Key = 'ForceRestartUntil'; Title = 'Daima zorla kapat bitis zamani'; Type = 'datetime' }

    @{ Sec = 'OTOMATIK ONARIM'; Type = 'section' }
    @{ Sec = 'Onarim'; Key = 'FixNetwork'; Title = 'Ağ onarımıni uygula'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'NetMaxRepairRung'; Title = 'Ag onarim kademesi (1-5)'; Type = 'int' }
    @{ Sec = 'Onarim'; Key = 'FixRdp'; Title = 'RDP ayarlarini onar (firewall + servis)'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'FixCrd'; Title = 'CRD servisini onar'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'CrdNoConnRestartCycles'; Title = 'CRD baglantisi yoksa kac dongu sonra yeniden baslat'; Type = 'int' }
    @{ Sec = 'Onarim'; Key = 'CrdRestartAfterHours'; Title = 'CRD onleyici restart (saat, 0 = kapali)'; Type = 'int' }
    @{ Sec = 'Onarim'; Key = 'CrdSignalPorts'; Title = 'CRD sinyal portlari'; Type = 'csv' }
    @{ Sec = 'Onarim'; Key = 'FixClock'; Title = 'Saat senkronunu onar'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'ServiceAutoStart'; Title = 'Servisleri Automatic yap (acilista baslasin)'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'ServiceCrashRecovery'; Title = 'Servis cokerse Windows kendini yeniden bassin'; Type = 'bool' }

    @{ Sec = 'VS CODE TUNNEL'; Type = 'section' }
    @{ Sec = 'Tunnel'; Key = 'TunnelRepair'; Title = 'Tunnel yoksa yeniden baslat'; Type = 'bool' }
    @{ Sec = 'Tunnel'; Key = 'TunnelName'; Title = 'Tunnel adi'; Type = 'text' }

    @{ Sec = 'SISTEM VE BELGE KORUMA'; Type = 'section' }
    @{ Sec = 'Sistem'; Key = 'ServerMode'; Title = 'Sunucu modu (uyku/hibernasyon/adaptor gucu kapatilir)'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'DisableFastStartup'; Title = 'Fast Startup kapansın'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'DisableHibernation'; Title = 'Hibernasyonu tamamen kapat (powercfg /h off)'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'OfficeSaveBeforeReboot'; Title = 'Restart oncesi Word/Excel kaydedilsin'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'OfficeSaveTimeoutSeconds'; Title = 'Belge kaydetme bekleme suresi (sn)'; Type = 'int' }
    @{ Sec = 'Sistem'; Key = 'OfficeAbortRebootIfStillOpen'; Title = 'Uygulama kapanmazsa restart yapılmasın'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'OfficeAbortRebootIfUnsaved'; Title = 'kaydedilmemiş belge varsa restart yapılmasın'; Type = 'bool' }

    @{ Sec = 'BILDIRIM'; Type = 'section' }
    @{ Sec = 'Bildirim'; Key = 'TelegramToken'; Title = 'Telegram bot token'; Type = 'text' }
    @{ Sec = 'Bildirim'; Key = 'TelegramChatId'; Title = 'Telegram chat id'; Type = 'text' }
    @{ Sec = 'Bildirim'; Key = 'HeartbeatUrl'; Title = 'Healthchecks ping adresi'; Type = 'text' }

    @{ Sec = 'TATIL'; Type = 'section' }
    @{ Sec = 'Tatil'; Key = 'HolidayMode'; Title = 'Tatil modu (full = tam blackout)'; Type = 'enum'; Options = @('full', 'default', 'none') }
    @{ Sec = 'Tatil'; Key = 'Holidays'; Title = 'Tatiller (her satır YYYY-AA-GG)'; Type = 'lines' }
    @{ Sec = 'Tatil'; Key = 'HolidaysFile'; Title = 'Tatil dosyasi (bos birakilirsa betik yanindaki holidays.txt)'; Type = 'text' }

    @{ Sec = 'ISTEMCI (BU BİLGİSAYAR)'; Type = 'section' }
    @{ Sec = 'Istemci'; Key = 'RemoteName'; Title = 'Uzak makine adı (panelde bu ad kullanılır)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'Targets'; Title = 'Uzak hedefler (her satır ip:port)'; Type = 'lines'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'RdpFile'; Title = 'RDP dosyası (.rdp)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'BrowserUrl'; Title = 'Tarayıcı adresi (CRD)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'LaunchOnRecover'; Title = 'Bağlantı düzelince otomatik aç'; Type = 'bool'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'KeepAliveMinutes'; Title = 'Oturumu canlı tutma aralığı (dk, 0 = kapalı)'; Type = 'int'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'TelegramToken'; Title = 'Telegram bot token (istemci)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'TelegramChatId'; Title = 'Telegram chat id (istemci)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'HeartbeatUrl'; Title = 'Healthchecks ping adresi (istemci)'; Type = 'text'; Target = 'client' }

    @{ Sec = 'PANEL'; Type = 'section' }
    @{ Sec = 'Panel'; Key = 'PanelRepair'; Title = 'Panel kapanırsa watchdog yeniden başlatsın'; Type = 'bool' }
    @{ Sec = 'Panel'; Key = 'PanelScriptName'; Title = 'Panel betiği dosya adı'; Type = 'text' }

    @{ Sec = 'ISLEMLER'; Type = 'section' }
    @{ Sec = 'Islem'; Type = 'actions' }
)

function Read-ConfigFile {
    param([string]$Path)
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        } catch { }
    }
    return $obj
}

function Write-ConfigFile {
    param([string]$Path, $Values)
    $obj = Read-ConfigFile $Path
    foreach ($k in $Values.Keys) { $obj[$k] = $Values[$k] }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $Path))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ClientDefaults {
    return [ordered]@{
        Targets = @(); RemoteName = ''; RdpFile = ''; BrowserUrl = 'https://remotedesktop.google.com'
        LaunchOnRecover = $true; KeepAliveMinutes = 0
        TelegramToken = ''; TelegramChatId = ''; HeartbeatUrl = ''; AlertRepeatHours = 3
    }
}

function Get-CurrentValues {
    $host_ = Read-ConfigFile $HostConfig
    $client_ = Read-ConfigFile $ClientConfig
    $hDefaults = Get-HostConfig
    $cDefaults = Get-ClientDefaults
    $out = [ordered]@{}
    foreach ($d in $script:Defs) {
        if (-not $d.Key) { continue }
        $isClient = ($d.Target -eq 'client')
        $src = $(if ($isClient) { $client_ } else { $host_ })
        $v = $null
        if ($src.Contains($d.Key)) { $v = $src[$d.Key] }
        elseif ($isClient) { $v = $cDefaults[$d.Key] }
        else { $v = $hDefaults[$d.Key] }
        if ($null -eq $v) { $v = '' }
        $out[$d.Key + $(if ($isClient) { '|client' } else { '' })] = $v
    }
    return $out
}

function ConvertTo-DayNames {
    param($Val)
    $map = @{ 0 = 'Paz'; 1 = 'Pzt'; 2 = 'Sal'; 3 = 'Car'; 4 = 'Per'; 5 = 'Cum'; 6 = 'Cmt' }
    $out = @()
    foreach ($v in @($Val)) {
        if ($null -eq $v) { continue }
        $t = ([string]$v).Trim()
        if ($t -eq '') { continue }
        if ($t -match '^\d+$') { $out += $map[[int]$t] } else { $out += $t }
    }
    return @($out)
}

function New-Segmented {
    param([string[]]$Options, [string]$Selected, [string]$Key)
    if (-not $script:EnumSelect) { $script:EnumSelect = @{} }
    $script:EnumSelect[$Key] = $Selected
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Orientation = 'Horizontal'
    $buttons = New-Object System.Collections.ArrayList
    foreach ($o in $Options) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = [string]$o
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $b.Padding = New-Object System.Windows.Thickness(14, 6, 14, 6)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.FontSize = 12
        $style = $script:Win.TryFindResource('Btn')
        if ($style) { $b.Style = $style }
        $opt = [string]$o
        $kk = [string]$Key
        $b.add_Click({
                param($s, $e)
                $script:EnumSelect[$kk] = $opt
                $grp = $s.Source
                if (-not $grp) { $grp = $s.OriginalSource }
                if ($grp) { $grp = $grp.Parent }
                foreach ($x in @($grp.Children)) {
                    if (-not ($x -is [System.Windows.Controls.Button])) { continue }
                    if ([string]$x.Content -eq $opt) {
                        $x.Background = Bx 'Accent'
                        $x.Foreground = Bx '#0B1220'
                        $x.BorderBrush = Bx 'Accent'
                    } else {
                        $x.Background = Bx 'Card2'
                        $x.Foreground = Bx 'Muted'
                        $x.BorderBrush = Bx 'Line'
                    }
                }
            }.GetNewClosure())
        [void]$buttons.Add($b)
        [void]$p.Children.Add($b)
    }
    foreach ($b in $buttons) {
        if ([string]$b.Content -eq [string]$Selected) {
            $b.Background = Bx 'Accent'
            $b.Foreground = Bx '#0B1220'
            $b.BorderBrush = Bx 'Accent'
        } else {
            $b.Background = Bx 'Card2'
            $b.Foreground = Bx 'Muted'
            $b.BorderBrush = Bx 'Line'
        }
    }
    $p.ToolTip = 'enum|' + $Key
    return $p
}

function New-SettingRow {
    param([string]$Title, $Control)
    $dp = New-Object System.Windows.Controls.DockPanel
    $dp.Margin = New-Object System.Windows.Thickness(0, 0, 0, 11)
    $dp.LastChildFill = $true
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Title
    $lbl.Foreground = Bx 'Text'
    $lbl.FontSize = 12.5
    $lbl.VerticalAlignment = 'Center'
    $lbl.TextWrapping = 'Wrap'
    $lbl.Width = 250
    $lbl.Margin = New-Object System.Windows.Thickness(0, 0, 14, 0)
    [void]$dp.Children.Add($lbl)
    $Control.VerticalAlignment = 'Center'
    [void]$dp.Children.Add($Control)
    return $dp
}

function Build-Settings {
    $cur = Get-CurrentValues
    $panel = El $script:Win 'SettingsPanel'
    $panel.Children.Clear()
    $first = $true
    foreach ($d in $script:Defs) {
        if ($d.Type -eq 'section') {
            $hdr = New-Object System.Windows.Controls.TextBlock
            $hdr.Text = [string]$d.Sec
            $hdr.Foreground = Bx 'Accent'
            $hdr.FontSize = 11
            $hdr.FontWeight = 'SemiBold'
            $hdr.Margin = New-Object System.Windows.Thickness(0, $(if ($first) { 0 } else { 20 }), 0, 10)
            [void]$panel.Children.Add($hdr)
            $first = $false
            continue
        }
        if ($d.Type -eq 'actions') {
            $wrap = New-Object System.Windows.Controls.Border
            $style = $script:Win.TryFindResource('CardStyle')
            if ($style) { $wrap.Style = $style }
            Add-ActionBar -Container $wrap
            $wrap.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            [void]$panel.Children.Add($wrap)
            continue
        }
        $ck = [string]$d.Key + $(if ($d.Target -eq 'client') { '|client' } else { '' })
        $val = $cur[$ck]
        $ctrl = $null
        switch ($d.Type) {
            'bool' { $ctrl = New-Toggle -On ([bool]$val); $ctrl.ToolTip = $ck }
            'enum' { $ctrl = New-Segmented -Options $d.Options -Selected ([string]$val) -Key $ck }
            'int' { $ctrl = New-TextBox -Width 130; $ctrl.Text = [string]$val; $ctrl.ToolTip = $ck }
            'text' { $ctrl = New-TextBox -Width 300; $ctrl.Text = [string]$val; $ctrl.ToolTip = $ck }
            'datetime' {
                $ctrl = New-TextBox -Width 200
                $t = ''
                if ($val) { try { $t = ([datetime]::Parse([string]$val)).ToString('yyyy-MM-dd HH:mm') } catch { $t = '' } }
                $ctrl.Text = $t
                $ctrl.ToolTip = $ck
            }
            'lines' { $ctrl = New-TextBox -Multi -Width 430 -Height 66 -Text ((@($val)) -join "`n"); $ctrl.ToolTip = $ck }
            'csv' { $ctrl = New-TextBox -Width 300; $ctrl.Text = ((@($val)) -join ', '); $ctrl.ToolTip = $ck }
            'days' {
                $p = New-Object System.Windows.Controls.StackPanel
                $p.Orientation = 'Horizontal'
                $names = ConvertTo-DayNames $val
                foreach ($day in @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')) {
                    $on = $names -contains $day
                    $t = New-Toggle -Label $day -On $on
                    $t.Width = 50
                    $t.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
                    $t.ToolTip = 'days|' + $ck + '|' + $day
                    [void]$p.Children.Add($t)
                }
                $ctrl = $p
            }
        }
        [void]$panel.Children.Add((New-SettingRow -Title ([string]$d.Title) -Control $ctrl))
    }
}

function Add-ActionBar {
    param($Container)
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Orientation = 'Vertical'
    $r1 = New-Object System.Windows.Controls.StackPanel
    $r1.Orientation = 'Horizontal'
    $r1.Margin = New-Object System.Windows.Thickness(0, 4, 0, 8)
    $mk = {
        param([string]$Text, [string]$Key, [switch]$Danger)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Text
        $b.Tag = $Key
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $b.Padding = New-Object System.Windows.Thickness(14, 7, 14, 7)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $style = $script:Win.TryFindResource($(if ($Danger) { 'BtnDanger' } else { 'Btn' }))
        if ($style) { $b.Style = $style }
        return $b
    }
    $b1 = & $mk 'Watchdog kur' 'install'
    $b2 = & $mk 'Watchdog kaldır' 'uninstall'
    $b3 = & $mk 'Zamanlanmis gorevi durdur' 'stoptask'
    $b4 = & $mk 'Gorevi hemen calistir' 'runtask'
    $b5 = & $mk 'Teşhis raporu üret' 'diag'
    $r1.Children.Add($b1); $r1.Children.Add($b2); $r1.Children.Add($b3); $r1.Children.Add($b4); $r1.Children.Add($b5)
    $p.Children.Add($r1)
    $r2 = New-Object System.Windows.Controls.StackPanel
    $r2.Orientation = 'Horizontal'
    $r2.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $b6 = & $mk 'Telegram test mesajı' 'testalert'
    $b7 = & $mk 'Sayaçları sıfırla' 'resetstate'
    $b8 = & $mk 'Logları temizle' 'clearlog'
    $b9 = & $mk 'config.json aç' 'openconfig'
    $b10 = & $mk 'Simdi zorla kapat + restart' 'forcereboot' -Danger
    $r2.Children.Add($b6); $r2.Children.Add($b7); $r2.Children.Add($b8); $r2.Children.Add($b9); $r2.Children.Add($b10)
    $p.Children.Add($r2)
    $script:ActionButtons = @($b1, $b2, $b3, $b4, $b5, $b6, $b7, $b8, $b9, $b10)
    foreach ($bb in $script:ActionButtons) {
        $bkey = [string]$bb.Tag
        $bb.add_Click({ Invoke-SettingsAction $bkey }.GetNewClosure())
    }
    $Container.Child = $p
}

function Invoke-SettingsAction {
    param([string]$Key)
    if (-not $script:ActionLog) { $script:ActionLog = @() }
    $script:ActionLog += $Key
    Write-Trace ('islem calistirildi: ' + $Key)
    switch ($Key) {
        'install' { Invoke-Script -Path $HostScript -Args @('-Install'); [System.Windows.MessageBox]::Show('Kurulum baslatildi (yonetici onayi gerekebilir).', 'RemoteWatchdog') | Out-Null }
        'uninstall' {
            if ([System.Windows.MessageBox]::Show('Watchdog zamanlanmis gorevi kaldirilsin mi?', 'RemoteWatchdog', 'YesNo', 'Question') -eq 'Yes') { Invoke-Script -Path $HostScript -Args @('-Uninstall') -Wait }
        }
        'stoptask' { Disable-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue | Out-Null; Write-Host 'gorev durduruldu' }
        'runtask' { Start-ScheduledTask -TaskName 'RemoteHostWatchdog' -ErrorAction SilentlyContinue; Start-Sleep 5; Update-Connections; Update-Overview }
        'diag' { Invoke-Script -Path $HostDiag -Wait; [System.Windows.MessageBox]::Show('Rapor Masaüstüne yazıldı.', 'RemoteWatchdog') | Out-Null }
        'testalert' {
            $cfg = Get-HostConfig
            $msg = 'RemoteWatchdog test bildirimi - ' + $env:COMPUTERNAME + ' - ' + (Get-Date).ToString('HH:mm:ss')
            if (-not $cfg.TelegramToken) { [System.Windows.MessageBox]::Show('Telegram token ayarli degil.', 'RemoteWatchdog') | Out-Null; break }
            try {
                Invoke-RestMethod -Method Post -Uri ('https://api.telegram.org/bot' + $cfg.TelegramToken + '/sendMessage') -Body @{ chat_id = $cfg.TelegramChatId; text = $msg } -TimeoutSec 15 -ErrorAction Stop | Out-Null
                [System.Windows.MessageBox]::Show('Test mesaji gonderildi.', 'RemoteWatchdog') | Out-Null
            } catch { [System.Windows.MessageBox]::Show('Gonderilemedi: ' + $_.Exception.Message, 'RemoteWatchdog') | Out-Null }
        }
        'resetstate' {
            Remove-Item -LiteralPath (Join-Path $HostData 'host-state.json') -Force -ErrorAction SilentlyContinue
            (El $script:Win 'TxtSaved').Text = 'Sayaçlar sıfırlandı: ' + (Get-Date).ToString('HH:mm:ss')
        }
        'clearlog' {
            if ([System.Windows.MessageBox]::Show('Log dosyalari silinsin mi?', 'RemoteWatchdog', 'YesNo', 'Question') -eq 'Yes') {
                foreach ($f in @($HostLog, (Join-Path $HostData 'tray.log'), (Join-Path $HostData 'panel.log'), $ClientLog)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
                Update-Log
            }
        }
        'openconfig' { if (Test-Path -LiteralPath $HostConfig) { Start-Process notepad.exe $HostConfig } }
        'forcereboot' {
            $r = [System.Windows.MessageBox]::Show('Daima zorla kapatma ACILIR ve makine yeniden baslatilir. Kaydedilmemis belge varsa once kaydedilir. Devam edilsin mi?', 'RemoteWatchdog', 'YesNo', 'Warning')
            if ($r -eq 'Yes') { Write-ConfigFile -Path $HostConfig -Values @{ ForceRestartAlways = $true }; Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait }
        }
        default { }
    }
}

function Save-Settings {
    param([switch]$Quiet)
    $hostVals = [ordered]@{}
    $clientVals = [ordered]@{}
    $daysVals = @{}
    $csvVals = @{}
    foreach ($ctrl in (Find-AllControls $script:Win)) {
        $key = $ctrl.ToolTip
        if ($key -isnot [string] -or $key -eq '') { continue }
        if ($key.StartsWith('enum|')) {
            $ek = $key.Substring(5)
            if ($script:EnumSelect -and $script:EnumSelect.ContainsKey($ek)) {
                if ($ek.EndsWith('|client')) { $clientVals[$ek.Substring(0, $ek.Length - 7)] = [string]$script:EnumSelect[$ek] }
                else { $hostVals[$ek] = [string]$script:EnumSelect[$ek] }
            }
            continue
        }
        if ($key.StartsWith('days|')) {
            $parts = $key.Split('|')
            if ($parts.Count -ge 3) {
                if (-not $daysVals.ContainsKey($parts[1])) { $daysVals[$parts[1]] = @() }
                if ([bool]$ctrl.Tag) { $daysVals[$parts[1]] = @($daysVals[$parts[1]] + $parts[2]) }
            }
            continue
        }
        $ck = $key
        $isClient = $ck.EndsWith('|client')
        if ($isClient) { $ck = $ck.Substring(0, $ck.Length - 7) }
        $def = $script:Defs | Where-Object { $_.Key -eq $ck -and $_.Type -ne 'section' -and $_.Type -ne 'actions' } | Select-Object -First 1
        if (-not $def) { continue }
        $val = $null
        switch ($def.Type) {
            'bool' { $val = [bool]$ctrl.Tag }
            'enum' { $val = [string]$ctrl.SelectedItem }
            'int' { $n = 0; if ([int]::TryParse(([string]$ctrl.Text).Trim(), [ref]$n)) { $val = $n } else { continue } }
            'text' { $val = ([string]$ctrl.Text).Trim() }
            'datetime' {
                $t = ([string]$ctrl.Text).Trim()
                if ($t -eq '') { $val = '' } else {
                    $d = [datetime]::MinValue
                    if (-not [datetime]::TryParse($t, [ref]$d)) { continue }
                    $val = $d.ToString('yyyy-MM-ddTHH:mm:ss')
                }
            }
            'lines' { $val = @((([string]$ctrl.Text) -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            'csv' { $csvVals[$ck] = @((([string]$ctrl.Text) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        }
        if ($null -eq $val) { continue }
        if ($isClient) { $clientVals[$ck] = $val } else { $hostVals[$ck] = $val }
    }
    foreach ($k in $daysVals.Keys) { $hostVals[$k] = @($daysVals[$k]) }
    foreach ($k in $csvVals.Keys) { $hostVals[$k] = $csvVals[$k] }
    Write-ConfigFile -Path $HostConfig -Values $hostVals
    if ($clientVals.Count -gt 0) { Write-ConfigFile -Path $ClientConfig -Values $clientVals }
    (El $script:Win 'TxtSaved').Text = 'Kaydedildi: ' + (Get-Date).ToString('HH:mm:ss') + '  (' + $hostVals.Count + ' host + ' + $clientVals.Count + ' istemci)'
    if (-not $Quiet) { [System.Windows.MessageBox]::Show('Ayarlar kaydedildi: ' + $hostVals.Count + ' host + ' + $clientVals.Count + ' istemci ayarı', 'RemoteWatchdog') | Out-Null }
}

function Find-AllControls {
    param($Root)
    $out = New-Object System.Collections.ArrayList
    $seen = New-Object System.Collections.ArrayList
    function Walk {
        param($c)
        if ($null -eq $c) { return }
        if ($seen.Contains($c)) { return }
        [void]$seen.Add($c)
        $kids = @()
        try {
            if ($c -is [System.Windows.Controls.Panel]) { $kids = @($c.Children) }
            elseif ($c -is [System.Windows.Controls.ContentControl]) { $kids = @($c.Content) }
            elseif ($c -is [System.Windows.Controls.Decorator]) { $kids = @($c.Child) }
            elseif ($c -is [System.Windows.Controls.ItemsControl]) { $kids = @($c.Items) }
        } catch { }
        foreach ($ch in $kids) {
            if ($null -eq $ch) { continue }
            if ($ch -is [System.Windows.UIElement] -or $ch -is [System.Windows.Media.Visual]) { [void]$out.Add($ch) }
            Walk $ch
        }
    }
    Walk $Root
    return $out
}

function Find-ByTag { param($Root, [string]$Tag) foreach ($c in (Find-AllControls $Root)) { if ($c.Tag -is [string] -and $c.Tag -eq $Tag) { return $c } } return $null }

function Refresh-Icon {
    $st = Get-StatusInfo
    $color = if ($null -eq $st.Host -and $null -eq $st.Client) { [System.Drawing.Color]::Gray } elseif ($st.Bad -gt 0) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::ForestGreen }
    if ($null -eq $script:LastColor -or $script:LastColor.ToArgb() -ne $color.ToArgb()) {
        if (-not ('IconNative' -as [type])) {
            Add-Type -Name IconNative -Namespace Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);'
        }
        $bmp = New-Object System.Drawing.Bitmap(16, 16)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $br = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($br, 1, 1, 14, 14)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)
        $g.DrawEllipse($pen, 1, 1, 14, 14)
        $g.Dispose(); $br.Dispose(); $pen.Dispose()
        $hIcon = $bmp.GetHicon()
        $bmp.Dispose()
        $ico = [System.Drawing.Icon]::FromHandle($hIcon)
        $oldIcon = $script:Icon.Icon
        $script:Icon.Icon = $ico
        if ($oldIcon) { try { $oldIcon.Dispose() } catch { } }
        if ($script:HIcon -ne [IntPtr]::Zero) { try { [void][Native.IconNative]::DestroyIcon($script:HIcon) } catch { } }
        $script:HIcon = $hIcon
        $script:LastColor = $color
    }
    $state = '' + $(if ($st.Host) { $st.Host.ok } else { 'yok' }) + '|' + $(if ($st.Client) { $st.Client.ok } else { 'yok' })
    if ($state -ne $script:LastState) {
        $wasHealthy = ($script:LastState -eq 'True|True' -or $script:LastState -eq 'True|yok' -or $script:LastState -eq 'yok|True')
        $script:LastState = $state
        if ($st.Host) {
            if ($st.Bad -gt 0) {
                $bad = @($st.Host.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join ', '
                Show-Balloon 'Uzak makine sorunlu' $bad 'Warning' -Critical:(-not $wasHealthy)
            } else {
                Show-Balloon 'Uzak makine ayakta' 'Tüm kontroller tamam.' 'Info'
            }
        }
    }
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon = 'Info', [switch]$Force, [switch]$Critical, [switch]$Always)
    $mode = $script:BalloonMode
    if ($NoBalloon) { return }
    if (-not $Always) {
        if ($mode -eq 'off') { return }
        if ($mode -eq 'critical' -and -not $Critical) { return }
        if ($script:Silent -and -not $Force) { return }
    }
    try {
        $script:Icon.BalloonTipTitle = $Title
        $script:Icon.BalloonTipText = $Text
        $script:Icon.BalloonTipIcon = $Icon
        $script:Icon.ShowBalloonTip(7000)
    } catch { Write-Trace ('balloon gosterilemedi: ' + $_.Exception.Message) }
}

function Get-BalloonMode {
    $v = (Get-ItemProperty -Path $RunKey -Name ($RunName + 'Balloon') -ErrorAction SilentlyContinue).($RunName + 'Balloon')
    if ($v -in @('off', 'critical', 'all')) { return [string]$v }
    return 'critical'
}

function Set-BalloonMode {
    param([string]$Mode)
    $script:BalloonMode = $Mode
    New-ItemProperty -Path $RunKey -Name ($RunName + 'Balloon') -Value $Mode -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Trace ('bildirim modu: ' + $Mode)
}

function Set-SilentMode {
    param([switch]$Toggle, [switch]$On, [switch]$Off, [switch]$NoPersist)
    if ($Toggle) { $script:Silent = -not $script:Silent }
    elseif ($On) { $script:Silent = $true }
    elseif ($Off) { $script:Silent = $false }
    $flag = $(if ($script:Silent) { '1' } else { '0' })
    if (-not $NoPersist) {
        try {
            New-ItemProperty -Path $RunKey -Name ($RunName + 'Silent') -Value $flag -PropertyType String -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Trace ('sessiz mod yazilamadi: ' + $_.Exception.Message)
            [System.Windows.MessageBox]::Show('Sessiz mod ayari kaydedilemedi: ' + $_.Exception.Message, 'RemoteWatchdog') | Out-Null
        }
    }
    if ($script:TrayItems) {
        $found = $false
        foreach ($it in $script:TrayItems) { if ($it.Text -eq 'Sessiz mod') { $it.Checked = $script:Silent; $found = $true } }
        if (-not $found) { Write-Trace 'sessiz mod menusu bulunamadi' }
    }
    Show-Balloon -Title 'Sessiz mod' -Text ('Bildirimler ' + $(if ($script:Silent) { 'KAPATILDI' } else { 'ACILDI' })) -Icon 'Info' -Force
    return $script:Silent
}

function Invoke-TrayAction {
    param([string]$Key)
    switch ($Key) {
        'panel' { $script:Win.Show(); $script:Win.Activate(); Show-Page 'conn'; Update-Connections }
        'panelstart' {
            Invoke-Script -Path $ScriptPath -WindowStyle Normal
            Start-Sleep 3
            Update-Connections
        }
        'toggle' { if ($script:Win.IsVisible) { $script:Win.Hide() } else { $script:Win.Show(); $script:Win.Activate() } }
        'check' { $script:Win.Show(); $script:Win.Activate(); Show-Page 'conn'; Start-ManualCheck }
        'silent' { Set-SilentMode -Toggle | Out-Null }
        'help' { Start-HelpTour -Restart | Out-Null; Show-Balloon -Title 'Ayar yardımı' -Text 'Ayarlar hakkında bilgiler sırayla gösterilecek (10 konu). Kapatmak için balonu tıklayıp geçebilirsiniz.' -Icon 'Info' -Always }
        'balloon' {
            $next = switch ($script:BalloonMode) { 'critical' { 'all' } 'all' { 'off' } default { 'critical' } }
            Set-BalloonMode -Mode $next
            $mi = @($script:TrayItems | Where-Object { $_.Tag -eq 'balloon' })[0]
            if ($mi) { $mi.Text = 'Bildirimler (' + $next + ')' }
            Show-Balloon -Title 'Bildirim modu' -Text ('Yeni mod: ' + $next + $(if ($next -eq 'critical') { ' (sadece kritik)' } elseif ($next -eq 'all') { ' (her durum değişimi)' } else { ' (hiçbiri)' })) -Icon 'Info' -Critical
        }
        'log' {
            $d = Split-Path -Parent $HostLog
            if (Test-Path $d) { Start-Process explorer.exe ('"' + $d + '"') } else { [System.Windows.MessageBox]::Show('Log klasoru yok: ' + $d, 'RemoteWatchdog') | Out-Null }
        }
        'web' { Start-Process 'https://remotedesktop.google.com' }
        'install' { Invoke-Script -Path $HostScript -Args @('-Install'); [System.Windows.MessageBox]::Show('Kurulum baslatildi (yonetici onayi gerekebilir).', 'RemoteWatchdog') | Out-Null }
        'diag' { Invoke-Script -Path $HostDiag -Wait; [System.Windows.MessageBox]::Show('Rapor Masaüstüne yazıldı.', 'RemoteWatchdog') | Out-Null }
        'quit' {
            $r = [System.Windows.MessageBox]::Show('Panel kapatilsin mi? Zamanlanmis watchdog gorevi calismaya devam eder.', 'RemoteWatchdog', 'YesNo', 'Question')
            if ($r -eq 'Yes') { $script:ExitRequested = $true; $script:Win.Close(); $script:Icon.Visible = $false; $script:Icon.Dispose() }
        }
        default { Write-Trace ('bilinmeyen tepsi islemi: ' + $Key) }
    }
}

function New-TrayIcon {
    $ctx = New-Object System.Windows.Forms.ContextMenuStrip
    $items = @(
        @{ t = 'Kontrol panelini aç'; k = 'panel' }
        @{ t = 'Şimdi denetle'; k = 'check' }
        @{ t = '-'; k = '' }
        @{ t = 'Sessiz mod'; k = 'silent' }
        @{ t = 'Bildirimler (kritik)'; k = 'balloon' }
        @{ t = 'Paneli aç / gizle'; k = 'toggle' }
        @{ t = 'Log klasörünü aç'; k = 'log' }
        @{ t = 'Ayarlar hakkında (bilgi balonları)'; k = 'help' }
        @{ t = 'Google Remote Desktop'; k = 'web' }
        @{ t = '-'; k = '' }
        @{ t = 'Watchdog kur'; k = 'install' }
        @{ t = 'Teşhis raporu üret'; k = 'diag' }
        @{ t = '-'; k = '' }
        @{ t = 'Çıkış'; k = 'quit' }
    )
    foreach ($spec in $items) {
        $mi = $ctx.Items.Add([string]$spec.t)
        $mi.Tag = [string]$spec.k
        if ($spec.k) {
            $key = [string]$spec.k
            $mi.add_Click({ Invoke-TrayAction $key }.GetNewClosure())
        }
    }
    $script:Icon = New-Object System.Windows.Forms.NotifyIcon
    $script:Icon.ContextMenuStrip = $ctx
    $script:Icon.Visible = $true
    Refresh-Icon
    $script:Icon.add_MouseDoubleClick({ Invoke-TrayAction 'panel' })
    $script:TrayItems = $ctx.Items
}

function Wire-UI {
    $w = $script:Win
    foreach ($n in @('NavConn', 'NavOverview', 'NavActions', 'NavSettings', 'NavLog')) {
        (El $w $n).Add_Click({ Show-Page ([string]$this.Tag) }.GetNewClosure())
    }
    (El $w 'ConnList').Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $btn = $e.OriginalSource
            while ($btn -and -not ($btn -is [System.Windows.Controls.Button])) { $btn = $btn.Parent }
            if (-not $btn) { return }
            Invoke-ConnAction ([string]$btn.Tag)
        })
    (El $w 'ActionList').Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $btn = $e.OriginalSource
            while ($btn -and -not ($btn -is [System.Windows.Controls.Button])) { $btn = $btn.Parent }
            if (-not $btn) { return }
            Invoke-ConnAction ([string]$btn.Tag)
        })
    (El $w 'BtnCheck').Add_Click({ Start-ManualCheck })
    (El $w 'BtnDiag').Add_Click({
            $r = [System.Windows.MessageBox]::Show('Collect-Diagnostics calisacak (okuma modunda, ~40 sn). Devam edilsin mi?', 'RemoteWatchdog', 'YesNo', 'Question')
            if ($r -eq 'Yes') { Invoke-Script -Path $HostDiag -Wait; [System.Windows.MessageBox]::Show('Rapor Masaüstüne yazıldı.', 'RemoteWatchdog') | Out-Null }
        })
    (El $w 'BtnInstall').Add_Click({ Invoke-Script -Path $HostScript -Args @('-Install'); [System.Windows.MessageBox]::Show('Kurulum baslatildi (yonetici onayi gerekebilir).', 'RemoteWatchdog') | Out-Null })
    (El $w 'BtnReboot').Add_Click({
            $r = [System.Windows.MessageBox]::Show('Makine yeniden baslatilsin mi? Kaydedilmemis belge varsa once kaydedilir.', 'RemoteWatchdog', 'YesNo', 'Question')
            if ($r -eq 'Yes') { Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait }
        })
    (El $w 'BtnForceNow').Add_Click({
            $r = [System.Windows.MessageBox]::Show('Daima zorla kapatma ACILIR ve makine yeniden baslatilir. Devam edilsin mi?', 'RemoteWatchdog', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            Save-HostConfig @{ ForceRestartAlways = $true }
            Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait
        })
    (El $w 'BtnSave').Add_Click({ Save-Settings })
    (El $w 'BtnReload').Add_Click({ Build-Settings; (El $w 'TxtSaved').Text = '' })
    (El $w 'BtnLogRefresh').Add_Click({ Update-Log })
    (El $w 'BtnLogCopy').Add_Click({ try { [System.Windows.Clipboard]::SetText((El $w 'TxtLog').Text) } catch { } })
    (El $w 'BtnLogOpen').Add_Click({ if (Test-Path $HostLog) { Start-Process notepad.exe $HostLog } })
    $w.add_Closing({
            param($s, $e)
            if ($script:ExitRequested) { return }
            $e.Cancel = $true
            $script:Win.Hide()
            Write-Trace 'pencere kapatma istegi yoksayildi (trayde kalindi)'
        })
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromSeconds(20)
    $script:Timer.Add_Tick({ Update-Connections; Update-Overview; Update-Actions; Refresh-Icon })
    $script:Timer.Start()

    # 1 sn'lik sayac: sonraki otomatik denetimin kalan suresini (sn) gosterir, elle denetleme bitisini yakalar
    $script:Tick = New-Object System.Windows.Threading.DispatcherTimer
    $script:Tick.Interval = [TimeSpan]::FromSeconds(1)
    $script:Tick.Add_Tick({
            try {
                if ($script:CheckBusy) {
                    if (Test-ManualCheckRunning) { Update-Countdown } else { Complete-ManualCheck }
                } else { Update-Countdown }
            } catch { Write-Trace ('sayac hatasi: ' + $_.Exception.Message) }
        })
    $script:Tick.Start()

    $script:ShowTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ShowTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:ShowTimer.Add_Tick({
            if (-not (Test-Path -LiteralPath $ShowRequest)) { return }
            if (((Get-Date) - $script:StartedAt).TotalSeconds -lt 10) { return }
            try { Remove-Item -LiteralPath $ShowRequest -Force -ErrorAction SilentlyContinue } catch { }
            $script:Win.Show()
            $script:Win.WindowState = 'Normal'
            $script:Win.Activate()
            Write-Trace 'goster istegi islendi (pencere one getirildi)'
        })
    $script:ShowTimer.Start()
    $script:HelpTimer = $null
    $script:HelpIndex = -1
    $script:HelpTopics = $null
    $helpSeen = (Get-ItemProperty -Path $RunKey -Name ($RunName + 'Help') -ErrorAction SilentlyContinue).($RunName + 'Help')
    if ($helpSeen -ne (Get-Date -Format 'yyyy-MM-dd')) {
        $script:FirstRunTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:FirstRunTimer.Interval = [TimeSpan]::FromSeconds(25)
        $script:FirstRunTimer.Add_Tick({
                $script:FirstRunTimer.Stop()
                Start-HelpTour | Out-Null
            })
        $script:FirstRunTimer.Start()
    }
}

if ($Install) {
    $cmd = 'powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    New-ItemProperty -Path $RunKey -Name $RunName -Value $cmd -PropertyType String -Force | Out-Null
    Write-Host 'Panel oturum acilinda otomatik baslayacak.'
    try {
        $vbs = Join-Path $UiDir 'Start-Panel.vbs'
        $pa = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
        $pp = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $ps = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
        $pt1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $pt2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName 'RemoteHostPanel' -Action $pa -Trigger @($pt1, $pt2) -Principal $pp -Settings $ps -Force -ErrorAction Stop | Out-Null
        Write-Host 'Gorev kuruldu: RemoteHostPanel (oturum acilinda + her 5 dk, pencere gostermeden)'
    } catch { Write-Host ('Panel gorevi kurulamadi: ' + $_.Exception.Message) -ForegroundColor Yellow }
    Write-Host ('Panelin restart sonrasi da acik gelmesi icin konsolda otomatik giris gerekir: host\Enable-ConsoleAutoLogon.ps1')
    exit 0
}
if ($Uninstall) {
    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName 'RemoteHostPanel' -ErrorAction SilentlyContinue) {
        try { Unregister-ScheduledTask -TaskName 'RemoteHostPanel' -Confirm:$false -ErrorAction Stop; Write-Host 'Gorev kaldirildi: RemoteHostPanel' } catch { }
    }
    Write-Host 'Oturum acilista baslatma kaldirildi.'
    exit 0
}

$script:Win = [Windows.Markup.XamlReader]::Parse($Xaml)
$script:StartedAt = Get-Date
try { Remove-Item -LiteralPath $ShowRequest -Force -ErrorAction SilentlyContinue } catch { }
$script:BalloonMode = Get-BalloonMode
Write-Trace ('bildirim modu: ' + $script:BalloonMode + ' | sessiz: ' + $script:Silent)
New-TrayIcon
Wire-UI
Show-Page 'conn'
Update-Connections
Update-Overview
Update-Actions
Update-Countdown
Build-Settings

if ($SelfTest) {
    if (-not $PreviewPath) { $PreviewPath = Join-Path $UiDir ('preview-' + $PreviewPage + '.png') }
    $w = $script:Win
    if ($ShowWindow) { $w.Show() } else { $w.Opacity = 0; $w.Show(); $w.Hide(); $w.Opacity = 1 }
    Start-Sleep -Milliseconds 900
    Show-Page $PreviewPage
    Start-Sleep -Milliseconds 400
    Update-Connections
    Update-Overview
    $w.UpdateLayout()
    Start-Sleep -Milliseconds 500
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(1080, 720, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $root = $w.Content
    $rtb.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($PreviewPath)
    $enc.Save($fs)
    $fs.Close()
    Write-Host ('Onizleme yazildi: ' + $PreviewPath)
    try {
        Update-Countdown
        $nx = Get-NextCheck
        $ntext = [string](El $w 'TxtNext').Text
        Write-Host ('Otomatik denetim sayaci: "' + $ntext + '" | aralik=' + ([math]::Round([double]$nx.IntervalMinutes, 1)) + ' dk (' + $nx.IntervalSource + ') | kaynak=' + $(if ($nx.Source) { $nx.Source } else { '-' }) + ' | son=' + $(if ($nx.Last) { $nx.Last.ToString('HH:mm:ss') } else { '-' }) + ' | sonraki=' + $(if ($nx.Next) { $nx.Next.ToString('HH:mm:ss') } else { '-' }) + ' | kalan=' + [int][math]::Ceiling($nx.RemainingSeconds) + ' sn')
        if (-not $nx.Known) {
            Write-Host 'Sayac: last-run.json yok - bekleme durumu gosteriliyor (beklenen)' -ForegroundColor DarkGray
        } elseif ($ntext -notmatch '\d') {
            Write-Host 'SELFTEST UYARI: sayac metninde saniye/kalan sure yok!' -ForegroundColor Red
        } else {
            Write-Host 'Sayac dogrulandi: kalan sure saniye cinsinden gosteriliyor' -ForegroundColor Green
        }
        if ([string](El $w 'TxtConnSub').Text -notmatch 'sonraki otomatik denetim|otomatik denetim zamani geldi|DENETLENIYOR') {
            Write-Host 'SELFTEST UYARI: baglanti sayfasi alt satirinda otomatik denetim bilgisi yok!' -ForegroundColor Red
        } else {
            Write-Host ('Baglanti alt satiri: ' + [string](El $w 'TxtConnSub').Text) -ForegroundColor Green
        }
        $bx = $script:CheckBusy
        $bs = $script:CheckBusySince
        $script:CheckBusy = $true
        $script:CheckBusySince = (Get-Date).AddSeconds(-7)
        Update-Countdown
        $busyText = [string](El $w 'TxtNext').Text
        $busyBtn = [string](El $w 'BtnCheck').Content
        $busySub = [string](El $w 'TxtConnSub').Text
        $script:CheckBusy = $bx
        $script:CheckBusySince = $bs
        Update-Countdown
        Write-Host ('Elle denetleme durumu (kuru test, surec baslatilmadi): sayac="' + $busyText + '" | dugme="' + $busyBtn + '" | alt satir="' + $busySub + '"')
        if ($busyText -match 'Denetleniyor' -and $busyBtn -match 'Denetleniyor' -and $busySub -match 'DENETLENIYOR') { Write-Host 'Elle denetleme durumu dogrulandi (sayac + dugme + alt satir)' -ForegroundColor Green }
        else { Write-Host 'SELFTEST UYARI: elle denetleme sirasinda sayac/dugme guncellenmiyor!' -ForegroundColor Red }
        # surec bitisini yakalama (1 sn'lik sayac): zararsiz kisa omurlu surec ile dogrulanir
        $noop = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'exit 0') -WindowStyle Hidden -PassThru
        $script:CheckBusy = $true
        $script:CheckBusySince = Get-Date
        $script:CheckProcs = @($noop)
        $waited = 0
        while ((Test-ManualCheckRunning) -and $waited -lt 20000) { Start-Sleep -Milliseconds 250; $waited += 250 }
        $detected = -not (Test-ManualCheckRunning)
        Write-Host ('Denetleme bitis yakalama testi: bitti=' + $detected + ' (' + $waited + ' ms, surec PID ' + $noop.Id + ')')
        if ($detected) { Complete-ManualCheck; Write-Host ('Elle denetleme bitisi dogrulandi: dugme="' + [string](El $w 'BtnCheck').Content + '" | sayac="' + [string](El $w 'TxtNext').Text + '"') -ForegroundColor Green }
        else { $script:CheckBusy = $false; $script:CheckProcs = @(); Write-Host 'SELFTEST UYARI: surec bitisi yakalanamadi (sayac islevi calismiyor olabilir)!' -ForegroundColor Red }
    } catch { Write-Host ('Sayac testi hata: ' + $_.Exception.Message) -ForegroundColor Red }
    Write-Host ('Baglanti satiri: ' + (El $w 'ConnList').Items.Count + ' | kart: ' + (El $w 'Cards').Items.Count + ' | bekleyen is: ' + (El $w 'ActionList').Items.Count + ' | ayar satiri: ' + (El $w 'SettingsPanel').Children.Count)
    try {
        $found = @(Find-AllControls $w)
        $keys = @($found | Where-Object { $_.ToolTip -is [string] -and ([string]$_.ToolTip) -ne '' })
        $enums = @($found | Where-Object { $_.ToolTip -is [string] -and ([string]$_.ToolTip).StartsWith('enum|') })
        $days = @($found | Where-Object { $_.ToolTip -is [string] -and ([string]$_.ToolTip).StartsWith('days|') })
        Write-Host ('Find-AllControls: toplam=' + $found.Count + ' | ayar anahtarli=' + $keys.Count + ' | enum=' + $enums.Count + ' | gun dugmeleri=' + $days.Count + ' (B2 olcumu: 0 olmamali)')
        if ($keys.Count -lt 10) { Write-Host 'SELFTEST UYARI: Save-Settings ayar alanlarini goremiyor!' -ForegroundColor Red } else { Write-Host 'Ayarlar sayfasi kontrolleri kaydedilebilir durumda' -ForegroundColor Green }
    } catch { Write-Host ('Find-AllControls testi hata: ' + $_.Exception.Message) -ForegroundColor Red }
    $menuCount = 0
    if ($script:TrayItems) { $menuCount = $script:TrayItems.Count }
    Write-Host ('Tepsi menusu ogeleri: ' + $menuCount)
    try {
        $ctrls = @(Find-AllControls $w)
        $buttons = @($ctrls | Where-Object { $_ -is [System.Windows.Controls.Button] })
        $toggles = @($buttons | Where-Object { $_.ToolTip -is [string] -and $_.ToolTip -ne '' -and ($_.ToolTip -notlike 'days|*') -and ($_.ToolTip -notlike 'enum|*') -and ($_.Content -eq 'AÇIK' -or $_.Content -eq 'KAPALI' -or $_.Content -eq 'ACIK' -or $_.Content -eq 'KAPALI') })
        $dayBtns = @($buttons | Where-Object { $_.ToolTip -is [string] -and $_.ToolTip -like 'days|*' })
        $enums = @($ctrls | Where-Object { $_.ToolTip -is [string] -and $_.ToolTip -like 'enum|*' })
        $xamlNamed = @($ctrls | Where-Object { $_.Name -match '^Btn' })
        $actionBtns = @($script:ActionButtons)
        Write-Host ('ARAYUZ DENETIMI: dugme=' + $buttons.Count + ' | islem dugmesi=' + $actionBtns.Count + ' | acik/kapali anahtar=' + $toggles.Count + ' | gun dugmesi=' + $dayBtns.Count + ' | secim grubu=' + $enums.Count + ' | adlandirilmis dugme=' + $xamlNamed.Count)
        $unwired = @()
        if ($actionBtns.Count -ne 10) { $unwired += 'islem dugmesi sayisi 10 degil (' + $actionBtns.Count + ')' }
        if ($toggles.Count -lt 10) { $unwired += 'acik/kapali anahtar sayisi dusuk (' + $toggles.Count + ')' }
        if ($dayBtns.Count -lt 7) { $unwired += 'gun dugmesi eksik (' + $dayBtns.Count + ')' }
        if ($enums.Count -lt 2) { $unwired += 'secim grubu eksik (' + $enums.Count + ')' }
        $xamlNamed | ForEach-Object { Write-Host ('   dugme: ' + $_.Name + ' = "' + $_.Content + '"') }
        if ($unwired.Count -eq 0) { Write-Host 'ARAYUZ: buton/toggle/menu eksigi yok' -ForegroundColor Green }
        else { $unwired | ForEach-Object { Write-Host ('SELFTEST UYARI: ' + $_) -ForegroundColor Red } }
        if ($ClickTest) {
        $probe = @($actionBtns | Where-Object { $_.Tag -eq 'resetstate' })[0]
        if ($probe) {
            $script:ActionLog = @()
            $probe.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Start-Sleep -Milliseconds 400
            $hit = (@($script:ActionLog) -contains 'resetstate')
            Write-Host ('Dugme tiklamasi testi (resetstate calisti mi): ' + $hit)
            if (-not $hit) { Write-Host 'SELFTEST UYARI: dugme tiklamasi isleyiciye ulasmadi!' -ForegroundColor Red } else { Write-Host 'Dugme baglantisi dogrulandi' -ForegroundColor Green }
        }
        $t0 = @($toggles)[0]
        if ($t0) {
            $before = [bool]$t0.Tag
            $t0.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Start-Sleep -Milliseconds 300
            $after = [bool]$t0.Tag
            Write-Host ('Anahtar (toggle) testi: ' + $before + ' -> ' + $after)
            if ($before -eq $after) { Write-Host 'SELFTEST UYARI: anahtar degismiyor!' -ForegroundColor Red } else { Write-Host 'Anahtar baglantisi dogrulandi' -ForegroundColor Green }
        }
        $nav = El $w 'NavSettings'
        $nav.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Start-Sleep -Milliseconds 400
        $vis = (El $w 'PageSettings').Visibility
        Write-Host ('Menu (nav) testi: Ayarlar sayfasi gorunur=' + $vis)
        if ($vis -ne 'Visible') { Write-Host 'SELFTEST UYARI: menu sayfayi acmadi!' -ForegroundColor Red } else { Write-Host 'Menu baglantisi dogrulandi' -ForegroundColor Green }

        $reload = El $w 'BtnReload'
        $settingsPanel = El $w 'SettingsPanel'
        $before = @($settingsPanel.Children).Count
        $reload.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Start-Sleep -Milliseconds 700
        $after = @($settingsPanel.Children).Count
        Write-Host ('Dugme (Formu yenile) testi: ayar satiri ' + $before + ' -> ' + $after)
        if ($after -lt 10) { Write-Host 'SELFTEST UYARI: Formu yenile butonu calismadi!' -ForegroundColor Red } else { Write-Host 'Formu yenile butonu dogrulandi' -ForegroundColor Green }

        $ctrls = @(Find-AllControls $w)
        $tbInterval = @($ctrls | Where-Object { $_.ToolTip -is [string] -and $_.ToolTip -eq 'IntervalMinutes' })[0]
        if ($tbInterval) {
            $orig = $tbInterval.Text
            $cfgPath = Join-Path $env:ProgramData 'RemoteWatchdog\config.json'
            $before2 = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).IntervalMinutes
            $tbInterval.Text = '7'
            Save-Settings -Quiet
            Start-Sleep -Milliseconds 300
            $after2 = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).IntervalMinutes
            Write-Host ('Input + kaydetme testi: IntervalMinutes ' + $before2 + ' -> ' + $after2 + ' (formda ' + $tbInterval.Text + ')')
            if ([string]$after2 -ne '7') {
                Write-Host 'SELFTEST UYARI: input degeri config.json dosyasina yazilmadi!' -ForegroundColor Red
            } else {
                Write-Host 'Input degeri aliniyor ve config.json dosyasina yaziliyor' -ForegroundColor Green
                $tbInterval.Text = [string]$before2
                Save-Settings -Quiet
                $back = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).IntervalMinutes
                Write-Host ('Eski deger geri yuklendi: ' + $back)
            }
        } else { Write-Host 'SELFTEST UYARI: IntervalMinutes input alani bulunamadi' -ForegroundColor Red }
        } else { Write-Host 'TIKLAMA TESTLERI ATLANDI (-ClickTest verilmedi; panelde hicbir butona basilmadi)' -ForegroundColor DarkGray }
    } catch { Write-Host ('Arayuz denetimi hata: ' + $_.Exception.Message) -ForegroundColor Red }
    $before = $script:Silent
    $silentItem = $null
    if ($script:TrayItems) { $silentItem = @($script:TrayItems | Where-Object { $_.Text -eq 'Sessiz mod' })[0] }
    if ($silentItem -and $ClickTest) {
        try {
            $silentItem.PerformClick()
            $after = $script:Silent
            Write-Host ('Sessiz mod testi: ' + $before + ' -> ' + $after + ' | isaretli=' + $silentItem.Checked + ' | registry=' + ((Get-ItemProperty -Path $RunKey -Name ($RunName + 'Silent') -ErrorAction SilentlyContinue).($RunName + 'Silent')))
            if ($after -eq $before) { Write-Host 'SELFTEST UYARI: sessiz mod degismedi!' -ForegroundColor Red } else { Write-Host 'Sessiz mod calisiyor' -ForegroundColor Green }
        } catch { Write-Host ('Sessiz mod testi hata: ' + $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Sessiz mod menusu bulunamadi!' -ForegroundColor Red }

    try {
        $w.Show()
        Start-Sleep -Milliseconds 400
        $w.Close()
        Start-Sleep -Milliseconds 400
        $stillHere = (-not $w.IsLoaded) -or ($w.IsVisible -eq $false)
        Write-Host ('X ile kapatma testi: pencere gorunur=' + $w.IsVisible + ' | iptal edildi=' + $stillHere + ' | tray simgesi=' + $(if ($script:Icon.Visible) { 'VAR' } else { 'YOK' }))
        if ($w.IsVisible) { Write-Host 'SELFTEST UYARI: pencere kapanmadi!' -ForegroundColor Red } else { Write-Host 'X kapatma davranisi dogru ( pencere gizlendi, tray ayakta)' -ForegroundColor Green }
        $w.Show()
      } catch { Write-Host ('Kapatma testi hata: ' + $_.Exception.Message + ' | iz: ' + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) -ForegroundColor Red }
    $script:ExitRequested = $true
    $script:Icon.Visible = $false
    $script:Icon.Dispose()
    $w.Hide()
    $w.Close()
    exit 0
}

if ($TrayOnly -or $script:Background) { $script:Win.Hide() } else { $script:Win.Show() }
try { [System.Windows.Threading.Dispatcher]::Run() } finally { try { $script:Mutex.ReleaseMutex() } catch { } }