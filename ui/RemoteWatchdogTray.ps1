#Requires -Version 5.1
<#
    RemoteWatchdogTray - Sistem tepsisinde (notification area) calisan kontrol paneli.

    Yapar:
      - Uzak makine (host) ve bu makine (istemci) durumunu tek panelde gosterir
      - Sistemin "ayakta" olup olmadigini, son denetim zamanini ve sorun listesini surekli izler
      - Bekleyen isleri (yeniden kayit gereken CRD, onarilamayan ag, kaydedilmemis belge) tek tikla cozer
      - Tum ayarlari panelden duzenler; "daima zorla kapatma" anahtari sureli
      - Durum degisince balloon bildirimi gosterir, sessiz modda sessiz kalir
      - Loglari, tehis raporunu ve klasorleri acar

    Calistirma:
      .\RemoteWatchdogTray.ps1                 tray'de baslar
      .\RemoteWatchdogTray.ps1 -Install        oturum acilinda otomatik baslatma
      .\RemoteWatchdogTray.ps1 -Uninstall
      .\RemoteWatchdogTray.ps1 -SelfTest       arayuz olusturulabiliyor mu diye dener (cikis yapar)
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SelfTest,
    [switch]$NoBalloon
)

$ErrorActionPreference = 'Continue'
$ScriptPath = $PSCommandPath
$UiDir = Split-Path -Parent $ScriptPath
$HostDir = Join-Path (Split-Path -Parent $UiDir) 'host'
$ClientDir = Join-Path (Split-Path -Parent $UiDir) 'client'
$HostScript = Join-Path $HostDir 'RemoteHostWatchdog.ps1'
$HostDiag = Join-Path $HostDir 'Collect-Diagnostics.ps1'
$ClientScript = Join-Path $ClientDir 'RemoteClientWatchdog.ps1'
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
$script:Timer = $null
$script:Icon = $null
$script:Panel = $null
$script:Ctrl = @{}
$script:LastColor = $null
$script:ExitRequested = $false
$script:Silent = [bool]((Get-ItemProperty -Path $RunKey -Name ($RunName + 'Silent') -ErrorAction SilentlyContinue).($RunName + 'Silent'))
$script:LastState = ''
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\RemoteWatchdogTraySingleInstance')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:FontBig = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

function Write-Trace {
    param([string]$Text)
    try { Add-Content -LiteralPath (Join-Path $HostData 'tray.log') -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Text) -Encoding UTF8 } catch { }
}

function Get-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-HostConfig {
    $cfg = [ordered]@{
        IntervalMinutes = 5
        RestartPolicy = 'blackout'
        BlackoutEnabled = $true
        BlackoutStart = 18
        BlackoutEnd = 8
        BlackoutFullDays = @('Cmt', 'Paz')
        HolidayMode = 'full'
        RebootAfterFailedCycles = 3
        RebootDelaySeconds = 60
        MinUptimeMinutes = 30
        ServerMode = $true
        DisableFastStartup = $true
        OfficeSaveBeforeReboot = $true
        OfficeAbortRebootIfUnsaved = $true
        ForceRestartAlways = $false
        ForceRestartUntil = ''
        TelegramToken = ''
        TelegramChatId = ''
        HeartbeatUrl = ''
        AlertRepeatHours = 12
        NetMaxRepairRung = 4
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
    param($Cfg, [string[]]$ExtraKeys = @())
    if (-not (Test-Path -LiteralPath $HostData)) { New-Item -ItemType Directory -Force -Path $HostData | Out-Null }
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $HostConfig) {
        try {
            $raw = Get-Content -LiteralPath $HostConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        } catch { }
    }
    foreach ($k in $Cfg.Keys) { $obj[$k] = $Cfg[$k] }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $HostConfig -Encoding UTF8
}

function Save-ClientConfig {
    param($Values)
    if (-not (Test-Path -LiteralPath $ClientData)) { New-Item -ItemType Directory -Force -Path $ClientData | Out-Null }
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $ClientConfig) {
        try {
            $raw = Get-Content -LiteralPath $ClientConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        } catch { }
    }
    foreach ($k in $Values.Keys) { $obj[$k] = $Values[$k] }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ClientConfig -Encoding UTF8
}

function Get-StatusColor {
    param($HostJson, $ClientJson)
    if ($null -eq $HostJson -and $null -eq $ClientJson) { return [System.Drawing.Color]::Gray }
    $bad = $false
    if ($HostJson) { if (-not $HostJson.ok) { $bad = $true } }
    if ($ClientJson) { if (-not $ClientJson.ok) { $bad = $true } }
    if ($bad) { return [System.Drawing.Color]::Firebrick }
    return [System.Drawing.Color]::ForestGreen
}

function Register-Ctrl {
    param($Control)
    if ($null -eq $Control) { return }
    if (-not [string]::IsNullOrEmpty([string]$Control.Name)) { $script:Ctrl[[string]$Control.Name] = $Control }
    if ($Control.Controls.Count -gt 0) {
        foreach ($child in $Control.Controls) {
            if ($child -is [System.Windows.Forms.Control]) { Register-Ctrl $child }
        }
    }
}

function Get-TrayIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)
    $g.DrawEllipse($pen, 1, 1, 14, 14)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}

function Get-Actions {
    param($HostJson)
    $a = New-Object System.Collections.ArrayList
    if ($null -eq $HostJson) {
        [void]$a.Add([pscustomobject]@{ Level = 'info'; Title = 'Uzak makine verisi yok'; Detail = 'Watchdog hicbir zaman calismadi veya bu makinede kurulu degil.'; Action = 'Kur'; Target = 'host' })
        return $a
    }
    $cfg = Get-HostConfig
    if (-not $HostJson.taskInstalled) {
        [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = 'Zamanlanmis gorev kurulu degil'; Detail = 'Watchdog ancak elle calistikca kontrol ediyor.'; Action = 'Kur'; Target = 'host' })
    }
    if ($HostJson.generated) {
        try {
            $age = (Get-Date) - [datetime]::Parse([string]$HostJson.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $limit = [double]($cfg.IntervalMinutes) * 3
            if ($age.TotalMinutes -gt $limit) {
                [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = 'Watchdog donmuyor (' + [math]::Round($age.TotalMinutes) + ' dk once)'; Detail = 'Gorev durmus veya makine uyuyor olabilir.'; Action = 'Simdi denetle'; Target = 'run' })
            }
        } catch { }
    }
    foreach ($c in @($HostJson.checks)) {
        if ($c.ok) { continue }
        $level = 'warn'
        if ($c.name -eq 'CRD servisi' -and [string]$c.detail -match 'host_id=YOK') { $level = 'crit' }
        $act = 'Loglari ac'
        if ($c.name -eq 'CRD servisi' -and [string]$c.detail -match 'host_id=YOK') { $act = 'CRD sayfasi' }
        if ($c.name -match 'Ag katmani') { $act = 'Ag onar' }
        [void]$a.Add([pscustomobject]@{ Level = $level; Title = $c.name; Detail = $c.detail; Action = $act; Target = $c.name })
    }
    $docsState = Join-Path $env:windir 'Temp\RemoteWatchdog-docs.json'
    if (Test-Path -LiteralPath $docsState) {
        try {
            $ds = Get-Content -LiteralPath $docsState -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$ds.unsaved -gt 0) {
                [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = $ds.unsaved + ' kaydedilmemis belge'; Detail = (@($ds.names) -join ', '); Action = 'Belgeleri kaydet'; Target = 'docs' })
            }
        } catch { }
    }
    if ($HostJson.state -and [int]$HostJson.state.netResetPendingReboot -eq 1) {
        [void]$a.Add([pscustomobject]@{ Level = 'crit'; Title = 'winsock/IP reset uygulandi'; Detail = 'Etkisi icin makine yeniden baslatilmali.'; Action = 'Yeniden baslat'; Target = 'reboot' })
    }
    if ($HostJson.state -and [int]$HostJson.state.consecutiveFailures -gt 0) {
        [void]$a.Add([pscustomobject]@{ Level = 'warn'; Title = 'Ardisik basarisiz deneme: ' + $HostJson.state.consecutiveFailures; Detail = [string]$HostJson.summary; Action = 'Yeniden baslat'; Target = 'reboot' })
    }
    if ($a.Count -eq 0) {
        [void]$a.Add([pscustomobject]@{ Level = 'ok'; Title = 'Bekleyen is yok'; Detail = 'Her sey yolunda.'; Action = ''; Target = '' })
    }
    return $a
}

function Invoke-Script {
    param([string]$Path, [string[]]$Args = @(), [switch]$Wait)
    if (-not (Test-Path -LiteralPath $Path)) { [System.Windows.Forms.MessageBox]::Show('Dosya bulunamadi: ' + $Path, 'RemoteWatchdog') | Out-Null; return }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Path + '"')) + $Args
    if ($Wait) {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
        return $p.ExitCode
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon = 'Info')
    if ($script:Silent -or $NoBalloon) { return }
    try {
        $script:Icon.BalloonTipTitle = $Title
        $script:Icon.BalloonTipText = $Text
        $script:Icon.BalloonTipIcon = $Icon
        $script:Icon.ShowBalloonTip(8000)
    } catch { }
}

function Update-Tray {
    $hj = Get-Json $HostJson
    $cj = Get-Json $ClientJson
    $color = Get-StatusColor $hj $cj
    if ($null -eq $script:LastColor -or $script:LastColor.ToArgb() -ne $color.ToArgb()) {
        $old = $script:Icon.Icon
        $script:Icon.Icon = Get-TrayIcon $color
        if ($old) { try { $old.Dispose() } catch { } }
        $script:LastColor = $color
    }
    $tips = New-Object System.Collections.ArrayList
    [void]$tips.Add('RemoteWatchdog')
    if ($hj) {
        $st = if ($hj.ok) { 'AYAKTA' } else { 'SORUNLU' }
        [void]$tips.Add('Uzak: ' + $st + ' | ' + $(if ($hj.generated) { ([datetime]::Parse([string]$hj.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToString('HH:mm') } else { '-' }) + ' kontrol')
    } else { [void]$tips.Add('Uzak: veri yok') }
    if ($cj) { [void]$tips.Add('Bu makine (istemci): ' + $(if ($cj.ok) { 'TAMAM' } else { 'SORUNLU' })) }
    if ($hj -and $hj.inBlackout) { [void]$tips.Add('Blackout aktif (zorla kapatma izinli)') }
    $script:Icon.Text = $t
    if ($script:Icon.Text.Length -gt 63) { $script:Icon.Text = $t.Substring(0, 63) }
    $state = $(if ($hj) { [string]$hj.ok } else { 'yok' }) + '|' + $(if ($cj) { [string]$cj.ok } else { 'yok' })
    if ($state -ne $script:LastState) {
        $script:LastState = $state
        if ($hj) {
            if ($hj.ok) { Show-Balloon 'Uzak makine ayakta' 'Tum kontroller tamam.' 'Info' }
            else {
                $bad = @($hj.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join ', '
                Show-Balloon 'Uzak makine sorunlu' $bad 'Warning'
            }
        }
    }
    if ($script:Panel -and $script:Panel.Visible) { Fill-Panel }
}

function Fill-Panel {
    $p = $script:Panel
    if (-not $p) { return }
    $hj = Get-Json $HostJson
    $cj = Get-Json $ClientJson

    $script:Ctrl['lblHeadline'].Text = $(if ($hj -and $hj.ok) { 'Sistem ayakta - tum kontroller tamam' } elseif ($hj) { 'Sorun var - ayrintilar icin asagida Bekleyen Isler sekmesine bakin' } else { 'Uzak makine verisi yok - watchdog kurulu degil veya hic calismadi' })
    $script:Ctrl['lblHeadline'].ForeColor = (Get-StatusColor $hj $cj)

    $lv = $script:Ctrl['lvHost']
    $lv.Items.Clear()
    if ($hj) {
        foreach ($c in @($hj.checks)) {
            $tag = if ($c.skipped) { 'ATLANDI' } elseif ($c.ok) { 'TAMAM' } else { 'SORUN' }
            $txt = '[' + $tag + '] ' + $c.name + ' - ' + $c.detail + $(if ($c.repair) { ' | onarim: ' + $c.repair } else { '' })
            $it = New-Object System.Windows.Forms.ListViewItem($txt)
            $it.ForeColor = if ($c.ok) { [System.Drawing.Color]::ForestGreen } elseif ($c.skipped) { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::Firebrick }
            [void]$lv.Items.Add($it)
        }
    } else { [void]$lv.Items.Add('(veri yok)') }

    $lv2 = $script:Ctrl['lvClient']
    $lv2.Items.Clear()
    if ($cj) {
        foreach ($c in @($cj.checks)) {
            $txt = '[' + $(if ($c.ok) { 'TAMAM' } else { 'SORUN' }) + '] ' + $c.name + ' - ' + $c.detail
            $it = New-Object System.Windows.Forms.ListViewItem($txt)
            $it.ForeColor = if ($c.ok) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::Firebrick }
            [void]$lv2.Items.Add($it)
        }
    } else { [void]$lv2.Items.Add('(istemci watchdog calismadi)') }

    $info = New-Object System.Collections.ArrayList
    if ($hj) {
        [void]$info.Add('Son kontrol : ' + $hj.generated)
        [void]$info.Add('Ozet       : ' + $hj.summary)
        [void]$info.Add('Uptime     : ' + [math]::Round([double]$hj.uptimeMinutes / 60, 1) + ' saat')
        [void]$info.Add('Kamu IP    : ' + $(if ($hj.publicIp) { $hj.publicIp } else { '?' }))
        [void]$info.Add('Gorev      : ' + $hj.taskState)
        [void]$info.Add('Blackout   : ' + $(if ($hj.inBlackout) { 'AKTIF (zorla kapatma izinli)' } else { 'kapali (sadece bilgilendirme)' }))
        [void]$info.Add('Tatil      : ' + $(if ($hj.isHoliday) { 'evet' } else { 'hayir' }) + ' | mod: ' + $hj.config.holidayMode)
        [void]$info.Add('Restart    : ' + $hj.config.restartPolicy + ' | blackout ' + $hj.config.blackoutStart + '-' + $hj.config.blackoutEnd + ' | tam gun: ' + (@($hj.config.blackoutFullDays) -join ','))
        [void]$info.Add('Daima zorla: ' + $(if ($hj.config.forceRestartAlways) { 'ACIK' } else { 'kapali' }) + $(if ($hj.config.forceRestartUntil) { ' (' + $hj.config.forceRestartUntil + ')' } else { '' }))
        [void]$info.Add('Ardisik hata: ' + $hj.state.consecutiveFailures + ' | ag onarim kademesi: ' + $hj.state.netRepairRung)
    } else { [void]$info.Add('Uzak makine icin last-run.json bulunamadi.') }
    $script:Ctrl['txtInfo'].Lines = @($info)

    $lv3 = $script:Ctrl['lvActions']
    $lv3.Items.Clear()
    foreach ($a in @(Get-Actions -HostJson $hj)) {
        $color = switch ($a.Level) { 'crit' { [System.Drawing.Color]::Firebrick } 'warn' { [System.Drawing.Color]::DarkOrange } 'ok' { [System.Drawing.Color]::ForestGreen } default { [System.Drawing.Color]::Gray } }
        $it = New-Object System.Windows.Forms.ListViewItem($a.Title)
        [void]$it.SubItems.Add($a.Detail)
        [void]$it.SubItems.Add($a.Action)
        $it.ForeColor = $color
        $it.Tag = $a
        [void]$lv3.Items.Add($it)
    }

    $lines = New-Object System.Collections.ArrayList
    foreach ($lf in @($HostLog, $ClientLog)) {
        if (Test-Path -LiteralPath $lf) {
            [void]$lines.Add(('===== ' + $lf + ' ====='))
            foreach ($l in @(Get-Content -LiteralPath $lf -Tail 120 -ErrorAction SilentlyContinue)) { [void]$lines.Add([string]$l) }
        }
    }
    $script:Ctrl['txtLog'].Lines = @($lines)
    $script:Ctrl['txtLog'].SelectionStart = 0
    $script:Ctrl['txtLog'].SelectionLength = 0
}

function Load-SettingsToUi {
    $p = $script:Panel
    $cfg = Get-HostConfig
    $script:Ctrl['numInterval'].Value = [math]::Max(1, [math]::Min(240, [int]$cfg.IntervalMinutes))
    $script:Ctrl['cmbPolicy'].SelectedItem = $(if ($cfg.RestartPolicy -and $script:Ctrl['cmbPolicy'].Items.Contains([string]$cfg.RestartPolicy)) { [string]$cfg.RestartPolicy } else { $script:Ctrl['cmbPolicy'].SelectedItem })
    $script:Ctrl['chkBlackout'].Checked = [bool]$cfg.BlackoutEnabled
    $script:Ctrl['numBlackStart'].Value = [math]::Max(0, [math]::Min(23, [int]$cfg.BlackoutStart))
    $script:Ctrl['numBlackEnd'].Value = [math]::Max(0, [math]::Min(23, [int]$cfg.BlackoutEnd))
    $days = @($cfg.BlackoutFullDays)
    foreach ($d in @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')) { $script:Ctrl['chkDay_' + $d].Checked = ($days -contains $d) }
    $script:Ctrl['cmbHolidayMode'].SelectedItem = $(if ($cfg.HolidayMode -and $script:Ctrl['cmbHolidayMode'].Items.Contains([string]$cfg.HolidayMode)) { [string]$cfg.HolidayMode } else { $script:Ctrl['cmbHolidayMode'].SelectedItem })
    $script:Ctrl['chkForceAlways'].Checked = [bool]$cfg.ForceRestartAlways
    $script:Ctrl['dtpForceUntil'].Value = $(try { [datetime]::Parse([string]$cfg.ForceRestartUntil) } catch { (Get-Date).AddHours(8) })
    $script:Ctrl['chkForceUntil'].Checked = [bool]($cfg.ForceRestartUntil)
    $script:Ctrl['numFailCycles'].Value = [math]::Max(1, [math]::Min(20, [int]$cfg.RebootAfterFailedCycles))
    $script:Ctrl['numRebootDelay'].Value = [math]::Max(10, [math]::Min(600, [int]$cfg.RebootDelaySeconds))
    $script:Ctrl['numUptime'].Value = [math]::Max(0, [math]::Min(1440, [int]$cfg.MinUptimeMinutes))
    $script:Ctrl['chkServerMode'].Checked = [bool]$cfg.ServerMode
    $script:Ctrl['chkFastStartup'].Checked = [bool]$cfg.DisableFastStartup
    $script:Ctrl['chkOffice'].Checked = [bool]$cfg.OfficeSaveBeforeReboot
    $script:Ctrl['chkOfficeAbort'].Checked = [bool]$cfg.OfficeAbortRebootIfUnsaved
    $script:Ctrl['txtTelegram'].Text = [string]$cfg.TelegramToken
    $script:Ctrl['txtChatId'].Text = [string]$cfg.TelegramChatId
    $script:Ctrl['txtHeartbeat'].Text = [string]$cfg.HeartbeatUrl
    $script:Ctrl['numAlertRepeat'].Value = [math]::Max(1, [math]::Min(168, [int]$cfg.AlertRepeatHours))
    $script:Ctrl['numNetRung'].Value = [math]::Max(1, [math]::Min(5, [int]$cfg.NetMaxRepairRung))
    $script:Ctrl['txtHolidays'].Text = ((Get-Json $HostJson).config.holidays -join "`r`n")
    $script:Ctrl['txtClientTarget'].Text = ''
    if (Test-Path -LiteralPath $ClientConfig) {
        try { $cc = Get-Content -LiteralPath $ClientConfig -Raw -Encoding UTF8 | ConvertFrom-Json; $script:Ctrl['txtClientTarget'].Text = ((@($cc.Targets)) -join "`r`n") } catch { }
    }
}

function Save-SettingsFromUi {
    $p = $script:Panel
    $cfg = Get-HostConfig
    $cfg.IntervalMinutes = [int]$script:Ctrl['numInterval'].Value
    $cfg.RestartPolicy = [string]$script:Ctrl['cmbPolicy'].SelectedItem
    $cfg.BlackoutEnabled = [bool]$script:Ctrl['chkBlackout'].Checked
    $cfg.BlackoutStart = [int]$script:Ctrl['numBlackStart'].Value
    $cfg.BlackoutEnd = [int]$script:Ctrl['numBlackEnd'].Value
    $d = @()
    foreach ($day in @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')) { if ($script:Ctrl['chkDay_' + $day].Checked) { $d += $day } }
    $cfg.BlackoutFullDays = $d
    $cfg.HolidayMode = [string]$script:Ctrl['cmbHolidayMode'].SelectedItem
    $cfg.RebootAfterFailedCycles = [int]$script:Ctrl['numFailCycles'].Value
    $cfg.RebootDelaySeconds = [int]$script:Ctrl['numRebootDelay'].Value
    $cfg.MinUptimeMinutes = [int]$script:Ctrl['numUptime'].Value
    $cfg.ServerMode = [bool]$script:Ctrl['chkServerMode'].Checked
    $cfg.DisableFastStartup = [bool]$script:Ctrl['chkFastStartup'].Checked
    $cfg.OfficeSaveBeforeReboot = [bool]$script:Ctrl['chkOffice'].Checked
    $cfg.OfficeAbortRebootIfUnsaved = [bool]$script:Ctrl['chkOfficeAbort'].Checked
    $cfg.ForceRestartAlways = [bool]$script:Ctrl['chkForceAlways'].Checked
    $cfg.ForceRestartUntil = $(if ($script:Ctrl['chkForceUntil'].Checked) { $script:Ctrl['dtpForceUntil'].Value.ToString('yyyy-MM-ddTHH:mm:ss') } else { '' })
    $cfg.TelegramToken = $script:Ctrl['txtTelegram'].Text.Trim()
    $cfg.TelegramChatId = $script:Ctrl['txtChatId'].Text.Trim()
    $cfg.HeartbeatUrl = $script:Ctrl['txtHeartbeat'].Text.Trim()
    $cfg.AlertRepeatHours = [int]$script:Ctrl['numAlertRepeat'].Value
    $cfg.NetMaxRepairRung = [int]$script:Ctrl['numNetRung'].Value
    Save-HostConfig -Cfg $cfg
    $targets = @($script:Ctrl['txtClientTarget'].Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Save-ClientConfig @{ Targets = $targets }
    $hol = @($script:Ctrl['txtHolidays'].Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' })
    Save-HostConfig -Cfg @{ Holidays = $hol }
    [System.Windows.Forms.MessageBox]::Show('Ayarlar kaydedildi. Yeni ayarlar bir sonraki denetimde gecerli olur.', 'RemoteWatchdog') | Out-Null
}

function New-Panel {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'RemoteWatchdog Kontrol Paneli'
    $f.Size = New-Object System.Drawing.Size(1000, 700)
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = [System.Drawing.Color]::White
    $f.Font = $script:Font

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Name = 'lblHeadline'
    $lbl.Dock = 'Top'
    $lbl.Height = 46
    $lbl.Font = $script:FontBig
    $lbl.TextAlign = 'MiddleLeft'
    $lbl.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
    $f.Controls.Add($lbl)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Name = 'tabs'
    $tabs.Dock = 'Fill'
    $f.Controls.Add($tabs)

    $t1 = New-Object System.Windows.Forms.TabPage('Durum')
    $t1.Dock = 'Fill'
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.Orientation = 'Vertical'
    $split.SplitterDistance = 500
    $t1.Controls.Add($split)
    $lvHost = New-Object System.Windows.Forms.ListView
    $lvHost.Name = 'lvHost'
    $lvHost.Dock = 'Fill'
    $lvHost.View = 'Details'
    $lvHost.FullRowSelect = $true
    $lvHost.HeaderStyle = 'None'
    $split.Panel1.Controls.Add($lvHost)
    $lblHostTitle = New-Object System.Windows.Forms.Label
    $lblHostTitle.Text = 'Bu makine (istemci) kontrolleri'
    $lblHostTitle.Dock = 'Top'
    $lblHostTitle.Height = 24
    $lblHostTitle.Font = $script:FontBold
    $split.Panel2.Controls.Add($lblHostTitle)
    $txtInfo = New-Object System.Windows.Forms.TextBox
    $txtInfo.Name = 'txtInfo'
    $txtInfo.Dock = 'Top'
    $txtInfo.Height = 190
    $txtInfo.Multiline = $true
    $txtInfo.ReadOnly = $true
    $txtInfo.ScrollBars = 'Vertical'
    $txtInfo.BackColor = [System.Drawing.Color]::White
    $split.Panel2.Controls.Add($txtInfo)
    $lvClient = New-Object System.Windows.Forms.ListView
    $lvClient.Name = 'lvClient'
    $lvClient.Dock = 'Fill'
    $lvClient.View = 'Details'
    $lvClient.FullRowSelect = $true
    $lvClient.HeaderStyle = 'None'
    $split.Panel2.Controls.Add($lvClient)
    $tabs.TabPages.Add($t1)

    $t2 = New-Object System.Windows.Forms.TabPage('Bekleyen isler')
    $t2.Dock = 'Fill'
    $lvAct = New-Object System.Windows.Forms.ListView
    $lvAct.Name = 'lvActions'
    $lvAct.Dock = 'Fill'
    $lvAct.View = 'Details'
    $lvAct.FullRowSelect = $true
    $lvAct.Columns.Add('Is', 240) | Out-Null
    $lvAct.Columns.Add('Ayrinti', 480) | Out-Null
    $lvAct.Columns.Add('Islem', 160) | Out-Null
    $t2.Controls.Add($lvAct)
    $btnRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnRow.Dock = 'Bottom'
    $btnRow.Height = 44
    $btnAct = New-Object System.Windows.Forms.Button
    $btnAct.Text = 'Secili isi uygula'
    $btnAct.Width = 160
    $btnAct.Add_Click({
        $p = $script:Panel
        if ($script:Ctrl['lvActions'].SelectedItems.Count -eq 0) { return }
        $a = $script:Ctrl['lvActions'].SelectedItems[0].Tag
        switch ($a.Target) {
            'host' { Invoke-Script -Path $HostScript -Args @('-Install') }
            'run' { Invoke-Script -Path $HostScript }
            'reboot' { $r = [System.Windows.Forms.MessageBox]::Show('Makine yeniden baslatilsin mi? Kaydedilmemis belge varsa once kaydedilir.', 'RemoteWatchdog', 'YesNo', 'Question'); if ($r -eq 'Yes') { Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait } }
            'docs' { Invoke-Script -Path (Join-Path $HostDir 'Protect-OpenDocuments.ps1') -Args @('-Force') -Wait }
            'CRD servisi' { Start-Process 'https://remotedesktop.google.com/headless' }
            'Ag katmani' { Invoke-Script -Path $HostScript }
            default { Invoke-Script -Path $HostScript }
        }
        Start-Sleep -Seconds 2
        Update-Tray
    })
    $btnForce = New-Object System.Windows.Forms.Button
    $btnForce.Text = 'Simdi zorla kapat ve yeniden baslat'
    $btnForce.Width = 260
    $btnForce.Height = 32
    $btnForce.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show('Daima zorla kapatma ACILIP makine ' + $script:Ctrl['numRebootDelay'].Value + ' sn sonra yeniden baslatilacak. Kaydedilmemis belge varsa once kaydedilir. Devam edilsin mi?', 'RemoteWatchdog', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            $cfg = Get-HostConfig
            $cfg.ForceRestartAlways = $true
            if ($script:Ctrl['chkForceUntil'].Checked) { $cfg.ForceRestartUntil = $script:Ctrl['dtpForceUntil'].Value.ToString('yyyy-MM-ddTHH:mm:ss') } else { $cfg.ForceRestartUntil = '' }
            Save-HostConfig -Cfg $cfg
            Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait
            $script:Ctrl['chkForceAlways'].Checked = $true
        })
    $btnRow.Controls.Add($btnAct)
    $btnRow.Controls.Add($btnForce)
    $t2.Controls.Add($btnRow)
    $tabs.TabPages.Add($t2)

    $t3 = New-Object System.Windows.Forms.TabPage('Ayarlar')
    $t3.Dock = 'Fill'
    $t3.AutoScroll = $true
    $fl = New-Object System.Windows.Forms.FlowLayoutPanel
    $fl.Dock = 'Fill'
    $fl.FlowDirection = 'TopDown'
    $fl.WrapContents = $false
    $fl.AutoScroll = $true
    $fl.Width = 960
    $t3.Controls.Add($fl)

    function Add-Row {
        param([string]$Label, $Control, [int]$Indent = 0)
        $row = New-Object System.Windows.Forms.FlowLayoutPanel
        $row.Width = 930
        $row.Height = 30
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Label
        $l.Width = 330
        $l.TextAlign = 'MiddleLeft'
        $l.Margin = New-Object System.Windows.Forms.Padding($Indent, 4, 0, 0)
        $row.Controls.Add($l)
        $Control.Width = 480
        $row.Controls.Add($Control)
        $fl.Controls.Add($row)
    }

    function New-Num { param([int]$Min = 0, [int]$Max = 240, [int]$Val = 5) $n = New-Object System.Windows.Forms.NumericUpDown; $n.Minimum = $Min; $n.Maximum = $Max; $n.Value = $Val; return $n }
    function New-Chk { param([string]$Text) $c = New-Object System.Windows.Forms.CheckBox; $c.Text = $Text; $c.AutoSize = $true; return $c }
    function New-Txt { param([switch]$Multi, [int]$H = 70) $t = New-Object System.Windows.Forms.TextBox; $t.Multiline = $Multi; if ($Multi) { $t.Height = $H; $t.ScrollBars = 'Vertical' } else { $t.Width = 300 }; return $t }

    $grp = New-Object System.Windows.Forms.Label
    $grp.Text = 'ZAMANLAMA VE RESTART POLITIKASI'
    $grp.Font = $script:FontBold
    $grp.Width = 900
    $fl.Controls.Add($grp)

    $numInterval = New-Num 1 240 5; $numInterval.Name = 'numInterval'; Add-Row 'Kontrol araligi (dakika)' $numInterval
    $cmbPolicy = New-Object System.Windows.Forms.ComboBox; $cmbPolicy.Name = 'cmbPolicy'; [void]$cmbPolicy.Items.AddRange(@('blackout', 'always', 'never')); $cmbPolicy.SelectedIndex = 0; Add-Row 'Restart politikasi' $cmbPolicy
    $chkBlackout = New-Chk 'Blackout penceresini kullan'; $chkBlackout.Name = 'chkBlackout'; Add-Row '' $chkBlackout
    $numBlackStart = New-Num 0 23 18; $numBlackStart.Name = 'numBlackStart'; Add-Row 'Blackout baslangic (saat)' $numBlackStart
    $numBlackEnd = New-Num 0 23 8; $numBlackEnd.Name = 'numBlackEnd'; Add-Row 'Blackout bitis (saat, geceye sarar)' $numBlackEnd
    $lblDays = New-Object System.Windows.Forms.Label; $lblDays.Text = 'Tam gun blackout:'; $lblDays.Width = 330; $lblDays.Height = 30; $lblDays.TextAlign = 'MiddleLeft'
    $rowDays = New-Object System.Windows.Forms.FlowLayoutPanel; $rowDays.Width = 930; $rowDays.Height = 32; $rowDays.Controls.Add($lblDays)
    foreach ($d in @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')) { $c = New-Chk $d; $c.Name = 'chkDay_' + $d; $c.Width = 46; $rowDays.Controls.Add($c) }
    $fl.Controls.Add($rowDays)
    $cmbHolidayMode = New-Object System.Windows.Forms.ComboBox; $cmbHolidayMode.Name = 'cmbHolidayMode'; [void]$cmbHolidayMode.Items.AddRange(@('full', 'default', 'none')); $cmbHolidayMode.SelectedIndex = 0; Add-Row 'Tatil modu' $cmbHolidayMode
    $txtHolidays = New-Txt -Multi; $txtHolidays.Name = 'txtHolidays'; Add-Row 'Tatiller (her satir YYYY-AA-GG)' $txtHolidays

    $grp2 = New-Object System.Windows.Forms.Label
    $grp2.Text = 'DAIMA ZORLA KAPATMA'
    $grp2.Font = $script:FontBold
    $grp2.Width = 900
    $fl.Controls.Add($grp2)
    $chkForceAlways = New-Chk 'Saat fark etmeksizin zorla kapat ve yeniden baslat'; $chkForceAlways.Name = 'chkForceAlways'; Add-Row '' $chkForceAlways
    $chkForceUntil = New-Chk 'Bitis zamani belirle'; $chkForceUntil.Name = 'chkForceUntil'; Add-Row '' $chkForceUntil
    $dtpForceUntil = New-Object System.Windows.Forms.DateTimePicker; $dtpForceUntil.Name = 'dtpForceUntil'; $dtpForceUntil.Format = 'Custom'; $dtpForceUntil.CustomFormat = 'yyyy-MM-dd HH:mm'; $dtpForceUntil.Width = 200; Add-Row 'Bitis zamani' $dtpForceUntil

    $grp3 = New-Object System.Windows.Forms.Label
    $grp3.Text = 'RESTART KOSULLARI'
    $grp3.Font = $script:FontBold
    $grp3.Width = 900
    $fl.Controls.Add($grp3)
    $numFailCycles = New-Num 1 20 3; $numFailCycles.Name = 'numFailCycles'; Add-Row 'Kac basarisiz denemeden sonra' $numFailCycles
    $numRebootDelay = New-Num 10 600 60; $numRebootDelay.Name = 'numRebootDelay'; Add-Row 'Reboot gecikmesi (sn)' $numRebootDelay
    $numUptime = New-Num 0 1440 30; $numUptime.Name = 'numUptime'; Add-Row 'Minimum uptime (dk, yeni acilan makine icin)' $numUptime
    $numNetRung = New-Num 1 5 4; $numNetRung.Name = 'numNetRung'; Add-Row 'Ag onarim kademesi (1-5)' $numNetRung

    $grp4 = New-Object System.Windows.Forms.Label
    $grp4.Text = 'SISTEM VE BELGE KORUMA'
    $grp4.Font = $script:FontBold
    $grp4.Width = 900
    $fl.Controls.Add($grp4)
    $chkServerMode = New-Chk 'Sunucu modu (uyku/hibernasyon/Fast Startup kapat)'; $chkServerMode.Name = 'chkServerMode'; Add-Row '' $chkServerMode
    $chkFastStartup = New-Chk 'Fast Startup kapansin'; $chkFastStartup.Name = 'chkFastStartup'; Add-Row '' $chkFastStartup
    $chkOffice = New-Chk 'Reboot oncesi Word/Excel kaydedilsin ve kapansin'; $chkOffice.Name = 'chkOffice'; Add-Row '' $chkOffice
    $chkOfficeAbort = New-Chk 'Kaydedilmemis belge varsa reboot yapilmasin'; $chkOfficeAbort.Name = 'chkOfficeAbort'; Add-Row '' $chkOfficeAbort

    $grp5 = New-Object System.Windows.Forms.Label
    $grp5.Text = 'BILDIRIM'
    $grp5.Font = $script:FontBold
    $grp5.Width = 900
    $fl.Controls.Add($grp5)
    $txtTelegram = New-Txt; $txtTelegram.Name = 'txtTelegram'; Add-Row 'Telegram bot token' $txtTelegram
    $txtChatId = New-Txt; $txtChatId.Name = 'txtChatId'; Add-Row 'Telegram chat id' $txtChatId
    $numAlertRepeat = New-Num 1 168 12; $numAlertRepeat.Name = 'numAlertRepeat'; Add-Row 'Ayni sorun icin tekrar araligi (saat)' $numAlertRepeat
    $txtHeartbeat = New-Txt; $txtHeartbeat.Name = 'txtHeartbeat'; Add-Row 'Healthchecks ping adresi' $txtHeartbeat
    $txtClientTarget = New-Txt -Multi; $txtClientTarget.Name = 'txtClientTarget'; Add-Row 'Istemci hedefleri (her satir ip:port)' $txtClientTarget

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Ayarlari kaydet'
    $btnSave.Width = 160
    $btnSave.Height = 32
    $btnSave.Add_Click({ Save-SettingsFromUi })
    $rowBtn = New-Object System.Windows.Forms.FlowLayoutPanel
    $rowBtn.Width = 930
    $rowBtn.Height = 40
    $rowBtn.Controls.Add($btnSave)
    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = 'Formu yenile'
    $btnReset.Width = 140
    $btnReset.Height = 32
    $btnReset.Add_Click({ Load-SettingsToUi })
    $rowBtn.Controls.Add($btnReset)
    $fl.Controls.Add($rowBtn)
    $tabs.TabPages.Add($t3)

    $t4 = New-Object System.Windows.Forms.TabPage('Gunluk')
    $t4.Dock = 'Fill'
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Name = 'txtLog'
    $txtLog.Dock = 'Fill'
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = 'Both'
    $txtLog.WordWrap = $false
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $t4.Controls.Add($txtLog)
    $rowLog = New-Object System.Windows.Forms.FlowLayoutPanel
    $rowLog.Dock = 'Bottom'
    $rowLog.Height = 44
    $b1 = New-Object System.Windows.Forms.Button; $b1.Text = 'Yenile'; $b1.Width = 100; $b1.Add_Click({ Fill-Panel })
    $b2 = New-Object System.Windows.Forms.Button; $b2.Text = 'Log dosyasini ac'; $b2.Width = 130; $b2.Add_Click({ if (Test-Path $HostLog) { Start-Process notepad.exe $HostLog } })
    $b3 = New-Object System.Windows.Forms.Button; $b3.Text = 'Tumunu kopyala'; $b3.Width = 130; $b3.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:Ctrl['txtLog'].Text) } catch { } })
    $b4 = New-Object System.Windows.Forms.Button; $b4.Text = 'Tehis raporu uret'; $b4.Width = 150; $b4.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show('Collect-Diagnostics calisacak (okuma modunda, ~30 sn). Devam edilsin mi?', 'RemoteWatchdog', 'YesNo', 'Question')
            if ($r -eq 'Yes') { Invoke-Script -Path $HostDiag -Wait; [System.Windows.Forms.MessageBox]::Show('Rapor Masaustune yazildi.', 'RemoteWatchdog') | Out-Null }
        })
    $rowLog.Controls.AddRange(@($b1, $b2, $b3, $b4))
    $t4.Controls.Add($rowLog)
    $tabs.TabPages.Add($t4)

    $btnForce = New-Object System.Windows.Forms.Button
    $btnForce.Text = 'Simdi zorla kapat ve yeniden baslat'
    $btnForce.Width = 260
    $btnForce.Height = 32
    $btnForce.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show('Daima zorla kapatma ACILIP makine ' + $script:Ctrl['numRebootDelay'].Value + ' sn sonra yeniden baslatilacak. Kaydedilmemis belge varsa once kaydedilir. Devam edilsin mi?', 'RemoteWatchdog', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            $cfg = Get-HostConfig
            $cfg.ForceRestartAlways = $true
            if ($script:Ctrl['chkForceUntil'].Checked) { $cfg.ForceRestartUntil = $script:Ctrl['dtpForceUntil'].Value.ToString('yyyy-MM-ddTHH:mm:ss') } else { $cfg.ForceRestartUntil = '' }
            Save-HostConfig -Cfg $cfg
            Invoke-Script -Path $HostScript -Args @('-ForceReboot') -Wait
            $script:Ctrl['chkForceAlways'].Checked = $true
        })
    $rowForce = New-Object System.Windows.Forms.FlowLayoutPanel
    $rowForce.Dock = 'Top'
    $rowForce.Height = 44
    $rowForce.Controls.Add($btnForce)
    $t2.Controls.Add($rowForce)

    $script:Panel = $f
    $f.Add_FormClosing({
            param($s, $e)
            if ($script:ExitRequested) { return }
            $e.Cancel = $true
            $script:Panel.Hide()
        })
    $f.Add_Shown({ Load-SettingsToUi; Fill-Panel })
    $script:Ctrl = @{}
    Register-Ctrl $f
    return $f
}

function New-Tray {
    $ctx = New-Object System.Windows.Forms.ContextMenuStrip
    $iCheck = $ctx.Items.Add('Simdi denetle'); $iCheck.Add_Click({ Invoke-Script -Path $HostScript; Invoke-Script -Path $ClientScript })
    $iPanel = $ctx.Items.Add('Kontrol panelini ac'); $iPanel.Add_Click({ $script:Panel.Show(); $script:Panel.WindowState = 'Normal'; $script:Panel.Activate(); Fill-Panel })
    [void]$ctx.Items.Add('-')
    $iSilent = $ctx.Items.Add('Sessiz mod'); $iSilent.Add_Click({
            $script:Silent = -not $script:Silent
            New-ItemProperty -Path $RunKey -Name ($RunName + 'Silent') -Value ([int]$script:Silent) -PropertyType String -Force | Out-Null
            $iSilent.Checked = $script:Silent
        })
    $iSilent.Checked = $script:Silent
    $iOpenLog = $ctx.Items.Add('Log klasorunu ac'); $iOpenLog.Add_Click({ $d = Split-Path -Parent $HostLog; if (Test-Path $d) { Start-Process explorer.exe ('"' + $d + '"') } })
    $iOpenWeb = $ctx.Items.Add('Google Remote Desktop'); $iOpenWeb.Add_Click({ Start-Process 'https://remotedesktop.google.com' })
    [void]$ctx.Items.Add('-')
    $iInstall = $ctx.Items.Add('Watchdog kur'); $iInstall.Add_Click({ Invoke-Script -Path $HostScript -Args @('-Install'); [System.Windows.Forms.MessageBox]::Show('Kurulum baslatildi (yonetici onayi gerekebilir).', 'RemoteWatchdog') | Out-Null })
    $iDiag = $ctx.Items.Add('Tehis raporu uret'); $iDiag.Add_Click({ Invoke-Script -Path $HostDiag -Wait; [System.Windows.Forms.MessageBox]::Show('Rapor Masaustune yazildi.', 'RemoteWatchdog') | Out-Null })
    [void]$ctx.Items.Add('-')
    $iExit = $ctx.Items.Add('Trayden kapat'); $iExit.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show('Tray uygulamasi kapatilsin mi? (Watchdog zamanlanmis gorevi calismaya devam eder)', 'RemoteWatchdog', 'YesNo', 'Question')
            if ($r -eq 'Yes') { $script:ExitRequested = $true; $script:Icon.Visible = $false; $script:Icon.Dispose(); $script:Mutex.ReleaseMutex(); [System.Windows.Forms.Application]::Exit() }
        })

    $script:Icon = New-Object System.Windows.Forms.NotifyIcon
    $script:Icon.ContextMenuStrip = $ctx
    $script:Icon.Visible = $true
    $script:Icon.Icon = Get-TrayIcon ([System.Drawing.Color]::Gray)
    $script:Icon.DoubleClick.Add({ $script:Panel.Show(); $script:Panel.Activate(); Fill-Panel })

    $script:Panel = New-Panel
    $script:Panel.Hide()

    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 20000
    $script:Timer.Add_Tick({ Update-Tray })
    $script:Timer.Start()
    Update-Tray
}

function Install-Tray {
    $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    New-ItemProperty -Path $RunKey -Name $RunName -Value $cmd -PropertyType String -Force | Out-Null
    Write-Host 'Tray, oturum acilinda otomatik baslatilacak.'
    Write-Host ('Kaldirmak icin: .\RemoteWatchdogTray.ps1 -Uninstall')
    Invoke-Script -Path $ScriptPath
}

function Uninstall-Tray {
    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    Write-Host 'Oturum acilista baslatma kaldirildi.'
}

if ($Install) { Install-Tray; exit 0 }
if ($Uninstall) { Uninstall-Tray; exit 0 }

if ($SelfTest) {
    Write-Host 'WinForms/NotifyIcon testi...'
    $ctx = New-Object System.Windows.Forms.ContextMenuStrip
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.ContextMenuStrip = $ctx
    $ni.Icon = Get-TrayIcon ([System.Drawing.Color]::ForestGreen)
    $ni.Visible = $true
    $p = New-Panel
    $script:Panel = $p
    try {
        $null = Load-SettingsToUi
        $null = Fill-Panel
        Write-Host ('Panel dolduruldu: host kontrolleri=' + $script:Ctrl['lvHost'].Items.Count + ', istemci=' + $script:Ctrl['lvClient'].Items.Count + ', bekleyen is=' + $script:Ctrl['lvActions'].Items.Count + ', log satiri=' + $script:Ctrl['txtLog'].Lines.Count)
        Write-Host ('Ayarlar: aralik=' + $script:Ctrl['numInterval'].Value + ', politika=' + $script:Ctrl['cmbPolicy'].SelectedItem + ', blackout=' + $script:Ctrl['chkBlackout'].Checked + ' ' + $script:Ctrl['numBlackStart'].Value + '-' + $script:Ctrl['numBlackEnd'].Value + ', tatilModu=' + $script:Ctrl['cmbHolidayMode'].SelectedItem + ', daimaZorla=' + $script:Ctrl['chkForceAlways'].Checked)
        Write-Host ('Baslik: ' + $script:Ctrl['lblHeadline'].Text)
        $crit = 0
        foreach ($it in $script:Ctrl['lvActions'].Items) { if ($it.ForeColor -eq [System.Drawing.Color]::Firebrick) { $crit++ } }
        Write-Host ('Kritik bekleyen is sayisi: ' + $crit)
    } catch { Write-Host ('PANEL DOLDURMA HATASI: ' + $_.Exception.Message) -ForegroundColor Red }
    $p.Show()
    Start-Sleep -Milliseconds 900
    $p.Close()
    $ni.Visible = $false
    $ni.Dispose()
    $ctx.Dispose()
    $p.Dispose()
    Write-Host ('Panel ve tray simgesi olusturuldu. Sekme sayisi: ' + $script:Ctrl['tabs'].TabPages.Count + ', kayitli kontrol: ' + $script:Ctrl.Count)
    Write-Host ('last-run.json (host): ' + $(if (Test-Path $HostJson) { 'var' } else { 'yok' }))
    Write-Host ('last-run.json (istemci): ' + $(if (Test-Path $ClientJson) { 'var' } else { 'yok' }))
    Write-Host 'SELFTEST BASARILI'
    exit 0
}

$created = $false
try { $created = $script:Mutex.WaitOne(0) } catch { $created = $true }
if (-not $created) { exit 0 }

New-Tray
try { [System.Windows.Forms.Application]::Run() } finally { $script:Mutex.ReleaseMutex() }
