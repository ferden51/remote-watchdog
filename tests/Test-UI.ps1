#Requires -Version 5.1
<#
    Test-UI - Arayuz birim testleri (gosterilmez, tek butona basar)
    Yalnizca WPF bilesenlerini kullanir; panel acmaz, ekrana pencere gostermez.

    Yakalanan hatalar:
      - New-Segmented bos sozluk falsy oldugu icin secimleri her kurulumda sifirliyordu
      - segment dugmesi tiklaninca EnumSelect guncellenmiyordu
      - New-Toggle (acik/kapali anahtar) degisimi
#>
[CmdletBinding()]
param([switch]$ClickTest)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$LibDir = Join-Path $Root 'lib'
foreach ($l in @('Common.ps1', 'Contract.ps1', 'Settings.ps1')) { . (Join-Path $LibDir $l) }
$PanelPath = Join-Path $Root 'ui\RemoteWatchdogPanel.ps1'
$script:Pass = 0
$script:Fail = 0
$script:Log = @()

function Ok {
    param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) { $script:Pass++; Write-Host ('  [GECTI] ' + $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('  [KALDI] ' + $Name + '  ' + $Info) -ForegroundColor Red }
    $script:Log += [pscustomobject]@{ Name = $Name; Pass = $Cond; Info = $Info }
}

function Get-FnCode {
    param([string]$Path, [string[]]$Names)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $out = New-Object System.Collections.ArrayList
    foreach ($n in $Names) {
        $f = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $n }, $true)
        if ($f.Count -eq 0) { Write-Host ('  [HATA] fonksiyon yok: ' + $n) -ForegroundColor Red; $script:Fail++; continue }
        [void]$out.Add($f[0].Extent.Text)
    }
    return $out
}

Write-Host '== Arayuz birim testleri =='
$script:Win = New-Object System.Windows.Window
$script:Win.Width = 400
$script:Win.Height = 300
$script:C = @{
    Bg = '#0F1114'; Side = '#14161A'; Card = '#1A1D22'; Card2 = '#21252B'; Line = '#2A2F36'
    Text = '#E8EAED'; Muted = '#98A0AA'; Accent = '#4C8DFF'; Ok = '#3FB950'; Warn = '#E3B341'; Bad = '#F85149'; Info = '#58A6FF'
}
$script:EnumSelect = @{}
$script:ActionButtons = @()
$script:HostData = Join-Path $env:TEMP 'rw-uitest'
$script:BalloonMode = 'off'
$script:NoBalloon = $true
$script:Silent = $true

foreach ($code in (Get-FnCode $PanelPath @('Bx', 'Write-Trace', 'New-Toggle', 'New-Segmented', 'Get-Json'))) { Invoke-Expression $code }

# Bu paketin cagirdigi panel/lib fonksiyonlari gercekten tanimli mi? (Bir fonksiyon yuklenmezse
# PowerShell Ok(...) satirini hic calistirmaz ve test sessizce kaybolur - o yuzden acikca dogrulanir.)
$required = @('Get-Json', 'New-Toggle', 'New-Segmented', 'Get-StatusTaskState', 'Read-Status', 'Write-Status')
$missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
Ok ('test icin gereken fonksiyonlar yuklendi (eksik: ' + $(if ($missing.Count) { $missing -join ', ' } else { 'yok' }) + ')') ($missing.Count -eq 0)

Write-Host '-- Seçim grubu (RestartPolicy / HolidayMode) --'
$p1 = New-Segmented -Options @('blackout', 'always', 'never') -Selected 'blackout' -Key 'RestartPolicy'
$p2 = New-Segmented -Options @('full', 'default', 'none') -Selected 'full' -Key 'HolidayMode'
Ok ('grup çocuk sayısı 3+3 = ' + $p1.Children.Count + '+' + $p2.Children.Count) (($p1.Children.Count -eq 3) -and ($p2.Children.Count -eq 3))
Ok ('ilk grup seçimi kaydedildi: ' + [string]$script:EnumSelect['RestartPolicy']) ([string]$script:EnumSelect['RestartPolicy'] -eq 'blackout')
Ok ('ikinci grup seçimi kaydedildi: ' + [string]$script:EnumSelect['HolidayMode']) ([string]$script:EnumSelect['HolidayMode'] -eq 'full')
Ok 'iki grup da aynı sözlükte tutuluyor (önceki hata: ikinci grup ilkini siliyordu)' ($script:EnumSelect.Count -eq 2)

if ($ClickTest) {
    $target = @($p1.Children | Where-Object { [string]$_.Content -eq 'always' })[0]
    $global:probeFired = $false
    $target.add_Click({ $global:probeFired = $true })
    $global:probeParam = $false
    $target.add_Click({ param($snd, $e2) $global:probeParam = ($null -ne $snd) }.GetNewClosure())
    $target.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Start-Sleep -Milliseconds 200
    Ok ('olay gerçekten düğmeye ulaşıyor (test işleyicisi tetiklendi: ' + $global:probeFired + ')') ($global:probeFired -eq $true)
    Ok ('param($s,$e) + GetNewClosure ile de tetikleniyor: ' + $global:probeParam) ($global:probeParam -eq $true)
    Ok ('tıklama sonrası RestartPolicy: ' + [string]$script:EnumSelect['RestartPolicy']) ([string]$script:EnumSelect['RestartPolicy'] -eq 'always')
    $t2 = @($p2.Children | Where-Object { [string]$_.Content -eq 'none' })[0]
    $t2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Start-Sleep -Milliseconds 200
    Ok ('tıklama sonrası HolidayMode: ' + [string]$script:EnumSelect['HolidayMode']) ([string]$script:EnumSelect['HolidayMode'] -eq 'none')
    $still = @($p1.Children | Where-Object { [string]$_.Content -eq 'always' })[0]
    Ok ('tıklanan düğme vurgulandı (Accent): ' + $still.Background) (([string]$still.Background) -match '4C8DFF')
    $other = @($p1.Children | Where-Object { [string]$_.Content -eq 'blackout' })[0]
    Ok ('diğer düğme normal renkte: ' + $other.Background) (([string]$other.Background) -notmatch '4C8DFF')
} else {
    Write-Host '  (tıklama testleri için -ClickTest verin)'
}

Write-Host '-- Açık / kapalı anahtar --'
$t = New-Toggle -On $true
Ok ('toggle başlangıç etiketi: ' + [string]$t.Tag) ([bool]$t.Tag -eq $true)
$labelCodes = (@($t.Content.ToCharArray() | ForEach-Object { [int]$_ }) -join ',')
$hasCedilla = (@($t.Content.ToCharArray() | Where-Object { [int]$_ -eq 0x00C7 }).Count -ge 1)
Ok ('toggle yazısı Türkçe "AÇIK" içinde ç (U+00C7) var: ' + $t.Content) $hasCedilla
if ($ClickTest) {
    $t.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Start-Sleep -Milliseconds 200
    Ok ('toggle tıklama sonrası: ' + [string]$t.Tag + ' / ' + [string]$t.Content) (([bool]$t.Tag -eq $false) -and ([string]$t.Content -eq 'KAPALI'))
    $d = New-Toggle -Label 'Pzt' -On $false
    $d.ToolTip = 'days|BlackoutFullDays|Pzt'
    $d.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Start-Sleep -Milliseconds 200
    Ok ('gün düğmesi etiketi korunuyor: ' + [string]$d.Content) ([string]$d.Content -eq 'Pzt')
    Ok ('gün düğmesi durumu: ' + [string]$d.Tag) ([bool]$d.Tag -eq $true)
}

Write-Host ''
Write-Host '-- Watchdog görev durumu (yanlış "kurulu değil" uyarısı) --'
$script:TaskCache = $null
$script:TaskCacheUntil = (Get-Date).AddMinutes(5)
$tmpJson = Join-Path $env:TEMP 'rw-uitest-state.json'
$script:HostJson = $tmpJson
$script:TaskCache = $null
$script:TaskCacheUntil = (Get-Date).AddMinutes(5)
function Set-StateJson { param($Obj) [System.IO.File]::WriteAllText($tmpJson, ($Obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false))) }
Set-StateJson ([ordered]@{ generated = (Get-Date).ToString('o'); taskInstalled = 'unknown'; checks = @() })
Ok ('gecici JSON okundu: taskInstalled=' + [string](Get-Json $tmpJson).taskInstalled) ([string](Get-Json $tmpJson).taskInstalled -eq 'unknown')
$s1 = Get-StatusTaskState -Status (Read-Status -Path $tmpJson) -VisibleTask $null
Ok ('taze veri + görünmeyen görev -> kurulu sayıldı: ' + $s1.Installed + ' | renk=' + $s1.Color) ($s1.Installed -eq $true)
Ok ('metin SYSTEM bilgisini içeriyor: ' + $s1.Text) ($s1.Text -match 'SYSTEM')
Ok ('JSON taskState=Running olsa bile "çalışıyor" denmiyor (host JSON kontrol bitince yazıyor): ' + $s1.Short) ($s1.Running -eq $false -and $s1.Short -match 'hazır')
$staleObj = [ordered]@{ generated = (Get-Date).AddHours(-6).ToString('o'); taskInstalled = 'unknown'; checks = @() }
$staleObj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmpJson -Encoding UTF8
$s2 = Get-StatusTaskState -Status (Read-Status -Path $tmpJson) -VisibleTask $null
Ok ('eski veri + görünmeyen görev -> kurulu değil denmeli: ' + $s2.Installed) ($s2.Installed -eq $false)
$falseObj = [ordered]@{ generated = (Get-Date).ToString('o'); taskInstalled = $false; checks = @() }
$falseObj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmpJson -Encoding UTF8
$s3 = Get-StatusTaskState -Status (Read-Status -Path $tmpJson) -VisibleTask $null
Ok ('JSON açıkça false -> kurulu değil: ' + $s3.Installed) ($s3.Installed -eq $false)
$trueObj = [ordered]@{ generated = (Get-Date).ToString('o'); taskInstalled = $true; checks = @() }
$trueObj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmpJson -Encoding UTF8
$s4 = Get-StatusTaskState -Status (Read-Status -Path $tmpJson) -VisibleTask $null
Ok ('JSON true -> kurulu ve çalışmıyor: ' + $s4.Installed) ($s4.Installed -eq $true -and $s4.Running -eq $false)
$visibleTask = [pscustomobject]@{ State = 'Ready' }
$s5 = Get-StatusTaskState -Status (Read-Status -Path $tmpJson) -VisibleTask $visibleTask
Ok ('görünen görev Ready -> kısa metin "Görev: hazır": ' + $s5.Short) ($s5.Short -match 'hazır' -and $s5.Running -eq $false)
Remove-Item -LiteralPath $tmpJson -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '-- Build-Settings (formu yenile) --'
$panelText = Get-Content -LiteralPath $PanelPath -Raw -Encoding UTF8
$mx = [regex]::Match($panelText, "(?s)\`$Xaml = @'\r?\n(.*?)\r?\n'@")
if (-not $mx.Success) { Ok 'panel XAML bulundu' $false } else {
    Ok 'panel XAML bulundu' $true
    try { $script:Win = [Windows.Markup.XamlReader]::Parse($mx.Groups[1].Value) } catch { Ok 'XAML ayrıştırıldı' $false $_.Exception.Message }
    $need = @('Bx', 'El', 'Write-Trace', 'Get-Json', 'Read-ConfigFile', 'Get-HostConfig', 'Get-ClientDefaults', 'Get-CurrentValues', 'ConvertTo-DayNames', 'New-Toggle', 'New-TextBox', 'New-Segmented', 'New-SettingRow', 'Add-ActionBar', 'Get-WatchdogTaskState', 'Update-ActionBarColors', 'Resolve-CheckInterval', 'Build-Settings', 'Invoke-SettingsAction', 'Invoke-TrayAction', 'Get-Actions', 'Update-Connections', 'Update-Overview', 'Update-Actions', 'Update-Log', 'Refresh-Icon', 'Get-StatusInfo', 'Show-Balloon', 'Get-BalloonMode', 'Set-BalloonMode', 'Invoke-Script', 'Update-Countdown', 'Get-NextCheck', 'Show-RepairWindow', 'Close-RepairWindow')
    $script:TaskCache = $null
    $script:TaskCacheUntil = [datetime]::MinValue
    foreach ($code in (Get-FnCode $PanelPath $need)) { Invoke-Expression $code }
    $script:TaskStatusText = $null
    $md = [regex]::Match($panelText, "(?s)\`$script:Defs = @\(.*?\r?\n\)")
    if ($md.Success) { Invoke-Expression $md.Value }
    Ok ('ayar tanimlari yuklendi: ' + @($script:Defs).Count + ' satir') (@($script:Defs).Count -ge 30)
    $script:ConnSummary = @{ Ok = 0; Bad = 0; Info = 0; LastRun = $null }
    $script:HostData = Join-Path $env:TEMP 'rw-uitest'
    New-Item -ItemType Directory -Force -Path $script:HostData | Out-Null
    $script:HostJson = Join-Path $env:ProgramData 'RemoteWatchdog\last-run.json'
    $script:HostConfig = Join-Path $env:ProgramData 'RemoteWatchdog\config.json'
    $script:ClientData = Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog'
    $script:ClientJson = Join-Path $script:ClientData 'last-run.json'
    $script:ClientConfig = Join-Path $script:ClientData 'config.json'
    $script:HolidaysFile = ''
    $script:Root = $Root
    $script:UiDir = Join-Path $Root 'ui'
    $script:HostScript = Join-Path $Root 'host\RemoteHostWatchdog.ps1'
    $script:ClientScript = Join-Path $Root 'client\RemoteClientWatchdog.ps1'
    $script:HostDiag = Join-Path $Root 'host\Collect-Diagnostics.ps1'
    $script:HostDocs = Join-Path $Root 'host\Protect-OpenDocuments.ps1'
    $script:HostLog = Join-Path $script:HostData 'host-watchdog.log'
    $script:ClientLog = Join-Path $script:ClientData 'client-watchdog.log'
    $script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $script:RunName = 'RemoteWatchdogTrayTest'
    $script:ShowRequest = Join-Path $env:TEMP 'RemoteWatchdog-show-test.flag'
    $script:IntervalCacheMin = 5; $script:IntervalCacheUntil = (Get-Date).AddSeconds(90)
    $script:IntervalCacheSrc = 'test'
    $script:CheckBusy = $false
    $script:Page = 'settings'
    $script:LastState = 'x'
    $script:LastColor = $null
    $err1 = $null
    try { Build-Settings } catch { $err1 = $_ }
    Ok ('ilk Build-Settings hatasız (' + $(if ($err1) { 'HATA: ' + $err1.Exception.Message } else { 'tamam' }) + ')') ($null -eq $err1)
    $rows1 = @((El $script:Win 'SettingsPanel').Children).Count
    Ok ('form satır sayısı: ' + $rows1) ($rows1 -ge 20)
    $err2 = $null
    try { Build-Settings } catch { $err2 = $_ }
    if ($err2) {
        Ok 'Formu yenile (ikinci Build-Settings) hatasız' $false ($err2.Exception.Message + ' | ' + (($err2.ScriptStackTrace -split "`r?`n" | Select-Object -First 2) -join ' <- '))
    } else { Ok 'Formu yenile (ikinci Build-Settings) hatasız' $true }
    $rows2 = @((El $script:Win 'SettingsPanel').Children).Count
    Ok ('yenilemeden sonra form satır sayısı korundu: ' + $rows2) ($rows2 -ge 20)

    Write-Host ''
    Write-Host '-- Onarım penceresi (X ile kapandıktan sonra yeniden açılmalı) --'
    $script:RepairWin = $null
    $script:RepairLiveBox = $null
    $script:RepairStatusBox = $null
    $script:RepairElapsedBox = $null
    $script:RepairStart = Get-Date
    $script:RepairStatusText = 'test'
    $script:RepairLiveText = 'ornek satir'
    $err3 = $null
    try { $null = Show-RepairWindow } catch { $err3 = $_ }
    Ok ('onarım penceresi açıldı' + $(if ($err3) { ': ' + $err3.Exception.Message } else { '' })) ((-not $err3) -and [bool]$script:RepairWin -and [bool]$script:RepairLiveBox)
    $first = $script:RepairWin
    Close-RepairWindow
    Ok 'pencere kapatıldı, referans temizlendi (Kapat düğmesi)' (($null -eq $script:RepairWin) -and ($null -eq $script:RepairLiveBox))
    $err4 = $null
    try { $null = Show-RepairWindow } catch { $err4 = $_ }
    Ok ('X ile kapandıktan sonra ikinci pencere açıldı' + $(if ($err4) { ': ' + $err4.Exception.Message } else { '' })) ((-not $err4) -and [bool]$script:RepairWin -and [bool]$script:RepairLiveBox -and ($script:RepairWin -ne $first))
    Close-RepairWindow

    Write-Host ''
    Write-Host '-- Günlük: iki dosya zaman sıralı birleşmeli --'
    $logDir = Join-Path $script:HostData 'logtest'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $HostLog = Join-Path $logDir 'host-watchdog.log'
    $ClientLog = Join-Path $logDir 'client-watchdog.log'
    @(
        '2026-09-28 08:00:00 [INFO] host-1',
        '2026-09-28 08:00:03 [INFO] host-2'
    ) | Set-Content -LiteralPath $HostLog -Encoding UTF8
    @(
        '2026-09-28 08:00:01 [INFO] client-1',
        '2026-09-28 08:00:02 [INFO] client-2',
        '2026-09-28 08:00:04 [INFO] client-3'
    ) | Set-Content -LiteralPath $ClientLog -Encoding UTF8
    $err5 = $null
    try { Update-Log } catch { $err5 = $_ }
    $logTxt = [string](El $script:Win 'TxtLog').Text
    $body = @($logTxt -split "`n" | Where-Object { $_ -match '^\[(host|istemci)\]' })
    $order = @($body | ForEach-Object { [regex]::Match($_, '\[(host|istemci)\] \d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2})').Groups[2].Value } | Where-Object { $_ })
    $sortedOk = $true
    for ($i = 1; $i -lt $order.Count; $i++) { if ($order[$i] -lt $order[$i - 1]) { $sortedOk = $false } }
    Ok ('günlük birleşik ve zaman sıralı (' + $order.Count + ' satır: ' + ($order -join ' < ') + ')' + $(if ($err5) { ': ' + $err5.Exception.Message } else { '' })) ((-not $err5) -and ($order.Count -eq 5) -and $sortedOk)
    Ok ('her satır kaynağı etiketli (host/istemci)') (@($body | Where-Object { $_ -match '\[host\]' }).Count -eq 2 -and @($body | Where-Object { $_ -match '\[istemci\]' }).Count -eq 3)
    Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
# Guvenlik agi: bir fonksiyon yuklenmemisse PowerShell Ok(...) satirini sessizce atlayabilir.
# Bu yuzden "tanimsiz komut" hatasi varsa test kirmiziya doner.
$unknownCmds = @($Error | Where-Object { [string]$_.FullyQualifiedErrorId -like 'CommandNotFoundException*' } | ForEach-Object { [string]$_.TargetObject } | Sort-Object -Unique)
if ($unknownCmds.Count) {
    Ok ('suite boyunca tanimsiz komut cagrisi var: ' + ($unknownCmds -join ', ')) $false
} else { Ok 'suite boyunca tanimsiz komut cagrisi yok' $true }

Write-Host ''
$traceFile = Join-Path $script:HostData 'panel.log'
if (Test-Path -LiteralPath $traceFile) {
    Write-Host '-- panel.log (işleyici hataları) --'
    Get-Content -LiteralPath $traceFile -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkYellow }
}
Write-Host ('  Gecti: ' + $script:Pass + ' | Kaldi: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Remove-Item -LiteralPath $script:HostData -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
