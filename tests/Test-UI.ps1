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

foreach ($code in (Get-FnCode $PanelPath @('Bx', 'Write-Trace', 'New-Toggle', 'New-Segmented'))) { Invoke-Expression $code }

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
Write-Host '-- Build-Settings (formu yenile) --'
$panelText = Get-Content -LiteralPath $PanelPath -Raw -Encoding UTF8
$mx = [regex]::Match($panelText, "(?s)\`$Xaml = @'\r?\n(.*?)\r?\n'@")
if (-not $mx.Success) { Ok 'panel XAML bulundu' $false } else {
    Ok 'panel XAML bulundu' $true
    try { $script:Win = [Windows.Markup.XamlReader]::Parse($mx.Groups[1].Value) } catch { Ok 'XAML ayrıştırıldı' $false $_.Exception.Message }
    $need = @('Bx', 'El', 'Write-Trace', 'Get-Json', 'Read-ConfigFile', 'Get-HostConfig', 'Get-ClientDefaults', 'Get-CurrentValues', 'ConvertTo-DayNames', 'New-Toggle', 'New-TextBox', 'New-Segmented', 'New-SettingRow', 'Add-ActionBar', 'Update-ActionBarColors', 'Resolve-CheckInterval', 'Build-Settings', 'Invoke-SettingsAction', 'Invoke-TrayAction', 'Get-Actions', 'Update-Connections', 'Update-Overview', 'Update-Actions', 'Update-Log', 'Refresh-Icon', 'Get-StatusInfo', 'Show-Balloon', 'Get-BalloonMode', 'Set-BalloonMode', 'Invoke-Script', 'Update-Countdown', 'Get-NextCheck', 'Update-TaskStatusText')
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
}

Write-Host ''
$traceFile = Join-Path $script:HostData 'panel.log'
if (Test-Path -LiteralPath $traceFile) {
    Write-Host '-- panel.log (işleyici hataları) --'
    Get-Content -LiteralPath $traceFile -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkYellow }
}
Write-Host ('  Gecti: ' + $script:Pass + ' | Kaldi: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Remove-Item -LiteralPath $script:HostData -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
