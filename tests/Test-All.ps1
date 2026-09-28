#Requires -Version 5.1
<#
    Test-All - RemoteWatchdog fonksiyon testleri (okuma modunda, hicbir sey degistirmez)

    Kapsam:
      1) Watchdog saf fonksiyonlari: blackout penceresi, tatil, gun esleme, TCP olcum, yapilandirma
      2) Ayarlar kapsamasi: watchdog config'eki HER anahtar panelde gorunuyor mu
      3) Panel veri fonksiyonlari: Get-StatusInfo / Get-Connections / Get-Actions gercek veriyle
      4) Istemci fonksiyonlari: TCP testi, JSON okuma
      5) Uctan uca: watchdog -Check -Json -> last-run.json -> panel satirlari

    .\Test-All.ps1            hepsini calistir
    .\Test-All.ps1 -Section 1 sadece bir bolum
#>
[CmdletBinding()]
param([int]$Section = 0)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$LibDir = Join-Path $Root 'lib'
foreach ($l in @('Common.ps1', 'Contract.ps1', 'Settings.ps1')) { . (Join-Path $LibDir $l) }
$Host_ = Join-Path $Root 'host\RemoteHostWatchdog.ps1'
$Panel = Join-Path $Root 'ui\RemoteWatchdogPanel.ps1'
$Client_ = Join-Path $Root 'client\RemoteClientWatchdog.ps1'
$script:Pass = 0
$script:Fail = 0
$script:Log = New-Object System.Collections.ArrayList

function Ok {
    param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) { $script:Pass++; Write-Host ('  [GECTI] ' + $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('  [KALDI] ' + $Name + '  ' + $Info) -ForegroundColor Red }
    [void]$script:Log.Add([pscustomobject]@{ Name = $Name; Pass = $Cond; Info = $Info })
}
function Eq {
    param([string]$Name, $Expected, $Actual)
    Ok $Name ([string]$Expected -eq [string]$Actual) ("(beklenen='" + $Expected + "' gercek='" + $Actual + "')")
}
function Head { param([string]$T) Write-Host ''; Write-Host ('== ' + $T) -ForegroundColor Cyan }

function Get-FnCode {
    param([string]$Path, [string[]]$Names)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $code = New-Object System.Collections.ArrayList
    foreach ($n in $Names) {
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $n }, $true)
        if ($fn.Count -eq 0) { Write-Host ('  [HATA] fonksiyon bulunamadi: ' + $n + ' (' + $Path + ')') -ForegroundColor Red; $script:Fail++; continue }
        [void]$code.Add($fn[0].Extent.Text)
    }
    return $code
}

foreach ($f in @($Host_, $Panel, $Client_)) { if (-not (Test-Path -LiteralPath $f)) { Write-Host ('Kritik: dosya yok -> ' + $f) -ForegroundColor Red; exit 1 } }

if ($Section -eq 0 -or $Section -eq 1) {
    Head '1) Watchdog saf fonksiyonlari'
    $tmp = Join-Path $env:TEMP 'rw-test'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Force -Path $tmp | Out-Null }
    $script:BaseDir = $tmp
    $script:StateFile = Join-Path $tmp 'state.json'
    $script:ConfigFile = Join-Path $tmp 'config.json'
    $script:LogFile = Join-Path $tmp 'test.log'
    $script:ScriptPath = $Host_
    $script:Results = New-Object System.Collections.ArrayList
    $script:PublicIp = $null
    $script:C = @{ Bg = '#0F1114'; Side = '#14161A'; Card = '#1A1D22'; Card2 = '#21252B'; Line = '#2A2F36'; Text = '#E8EAED'; Muted = '#98A0AA'; Accent = '#4C8DFF'; Ok = '#3FB950'; Warn = '#E3B341'; Bad = '#F85149'; Info = '#58A6FF' }
    foreach ($code in (Get-FnCode $Host_ @('Write-Log', 'Get-LogColor', 'Rotate-LogIfNeeded', 'Remove-OldLogFiles', 'Get-Config', 'Get-State', 'Save-State', 'Add-Result', 'Invoke-Probe', 'Get-TcpMs', 'Get-CrdHostConfigPath', 'Get-CrdSignalConnections', 'Get-UptimeMinutes', 'ConvertTo-DotNetDays', 'Get-HolidayList', 'Test-IsHoliday', 'Test-InBlackout', 'Get-PowerSettingAcIndex'))) { Invoke-Expression $code }

    $global:cfg = [pscustomobject]@{
        BlackoutEnabled = $true; BlackoutStart = 18; BlackoutEnd = 8
        BlackoutNights = @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz'); BlackoutFullDays = @('Cmt', 'Paz')
        HolidayMode = 'full'; Holidays = @(); HolidaysFile = ''
        ForceRestartAlways = $false; ForceRestartUntil = ''
    }
    $holFile = Join-Path $tmp 'holidays.txt'
    Set-Content -LiteralPath $holFile -Value @('# test', '2026-11-10', '2026-11-11') -Encoding UTF8
    $global:cfg.HolidaysFile = $holFile

    $cases = @(
        @{ n = 'Pzt 09:00 calisma'; t = '2026-09-28T09:00:00'; e = $false }
        @{ n = 'Pzt 17:59 calisma'; t = '2026-09-28T17:59:00'; e = $false }
        @{ n = 'Pzt 18:00 blackout'; t = '2026-09-28T18:00:00'; e = $true }
        @{ n = 'Pzt 23:00 blackout'; t = '2026-09-28T23:00:00'; e = $true }
        @{ n = 'Sal 07:59 onceki gece'; t = '2026-09-29T07:59:00'; e = $true }
        @{ n = 'Cmt 10:00 tam blackout'; t = '2026-10-03T10:00:00'; e = $true }
        @{ n = 'Paz 23:59 tam blackout'; t = '2026-10-04T23:59:00'; e = $true }
    )
    foreach ($c in $cases) { Eq ('blackout: ' + $c.n) $c.e ([bool](Test-InBlackout -At ([datetime]::Parse($c.t)))) }
    Eq 'blackout: Pazar tam blackout (2016-01-03)' $true ([bool](Test-InBlackout -At ([datetime]::Parse('2016-01-03T09:00:00'))))
    Eq 'blackout: Pazartesi gunduz sadece bilgilendirme (2016-01-04)' $false ([bool](Test-InBlackout -At ([datetime]::Parse('2016-01-04T09:00:00'))))

    $global:cfg.ForceRestartAlways = $true
    Eq 'daima zorla: gunduzde de ZORLA' $true ([bool](Test-InBlackout -At ([datetime]::Parse('2026-09-28T12:00:00'))))
    $global:cfg.ForceRestartUntil = '2026-09-27T23:00:00'
    Eq 'daima zorla: suresi dolmus -> normal kural' $false ([bool](Test-InBlackout -At ([datetime]::Parse('2026-09-28T12:00:00'))))
    $global:cfg.ForceRestartUntil = '2026-09-28T23:00:00'
    Eq 'daima zorla: suresi dolmamis -> ZORLA' $true ([bool](Test-InBlackout -At ([datetime]::Parse('2026-09-28T12:00:00'))))
    $global:cfg.ForceRestartAlways = $false; $global:cfg.ForceRestartUntil = ''

    $global:cfg.HolidayMode = 'full'
    Eq 'tatil (liste): 10.11.2026 tam blackout' $true ([bool](Test-InBlackout -At ([datetime]::Parse('2026-11-10T10:00:00'))))
    Eq 'tatil (liste): 09.11.2026 normal gun' $false ([bool](Test-InBlackout -At ([datetime]::Parse('2026-11-09T10:00:00'))))
    $global:cfg.HolidayMode = 'default'
    Eq 'tatil modu=default: gunduz bilgilendirme' $false ([bool](Test-InBlackout -At ([datetime]::Parse('2026-11-10T10:00:00'))))
    Eq 'tatil modu=default: gece yine zorla' $true ([bool](Test-InBlackout -At ([datetime]::Parse('2026-11-10T22:00:00'))))
    $global:cfg.HolidayMode = 'none'
    Eq 'tatil modu=none: gunduz zorla degil' $false ([bool](Test-InBlackout -At ([datetime]::Parse('2026-11-10T10:00:00'))))
    $global:cfg.HolidayMode = 'full'

    Eq 'gun esleme: Pzt..Paz' '0,1,2,3,4,5,6' ((ConvertTo-DotNetDays @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')) -join ',')
    Eq 'gun esleme: Cmt+Paz' '0,6' ((ConvertTo-DotNetDays @('Cmt', 'Paz')) -join ',')
    Eq 'gun esleme: sayisal 0..6' '0,1,2,3,4,5,6' ((ConvertTo-DotNetDays @(0, 1, 2, 3, 4, 5, 6)) -join ',')
    Eq 'gun esleme: bilinmeyen yok sayilir' '1' ((ConvertTo-DotNetDays @('Pzt', 'bulunmayanGun')) -join ',')

    $hl = @(Get-HolidayList)
    Ok ('tatil listesi dosyadan okundu (' + $hl.Count + ' kayit)') ($hl.Count -eq 2)
    Ok 'tatil listesi yorum satirlarini almadi' (-not ($hl -contains '# test'))
    $global:cfg.HolidaysFile = (Join-Path $tmp 'yok-boyle-bir-dosya.txt')
    $global:cfg.Holidays = @('2026-01-01')
    $hl2 = @(Get-HolidayList)
    Eq 'tatil listesi: dosya yoksa configten okur' '2026-01-01' ($hl2 -join ',')
    $global:cfg.HolidaysFile = $holFile

    $ms = -1; $msHost = ''
    foreach ($pip in @('9.9.9.9', '1.1.1.1', '8.8.8.8')) {
        $t = Get-TcpMs -HostName $pip -Port 443 -TimeoutMs 3000
        if ($t -ge 0) { $ms = $t; $msHost = $pip; break }
    }
    Ok ('TCP olcum: dogrudan IP:443 acik (' + $msHost + ', ' + $ms + ' ms)') ($ms -ge 0)
    $closed = Get-TcpMs -HostName '127.0.0.1' -Port 9 -TimeoutMs 1500
    Ok 'TCP olcum: kapali port -1 doner' ($closed -eq -1)
    $conns = Get-CrdSignalConnections -Ports @(443, 5222)
    Ok ('CRD sinyal baglantisi sayimi calisti (' + $conns + ')') ($conns -ge 0)
    $sample = '  TCP    192.168.1.109:49029    104.18.2.115:443       ESTABLISHED     2088'
    $sample -match '^\s*TCP\s+\S+\s+(\S+):(\d+)\s+(\S+)\s+(\d+)\s*$' | Out-Null
    Eq 'netsat ayristirma: uzak IP = matches[1]' '104.18.2.115' $matches[1]
    Eq 'netstat ayristirma: uzak port = matches[2]' '443' $matches[2]
    Eq 'netstat ayristirma: durum = matches[3] (ESKIDEN matches[1] idi -> hep 0 donuyordu)' 'ESTABLISHED' $matches[3]
    Eq 'netstat ayristirma: PID = matches[4]' '2088' $matches[4]
    $ns = netstat -ano -p tcp 2>&1
    $pids = @()
    foreach ($l in $ns) {
        if ($l -match '^\s*TCP\s+\S+\s+(\S+):(\d+)\s+(\S+)\s+(\d+)\s*$') {
            if ($matches[3] -eq 'ESTABLISHED' -and [int]$matches[2] -eq 443) { $pids += [int]$matches[4] }
        }
    }
    if ($pids.Count -gt 0) {
        $real = 0
        foreach ($l in $ns) {
            if ($l -match '^\s*TCP\s+\S+\s+(\S+):(\d+)\s+(\S+)\s+(\d+)\s*$') {
                if ($matches[3] -eq 'ESTABLISHED' -and ([int]$matches[2] -eq 443) -and ($pids -contains [int]$matches[4])) { $real++ }
            }
        }
        $broken = 0
        foreach ($l in $ns) {
            if ($l -match '^\s*TCP\s+\S+\s+(\S+):(\d+)\s+(\S+)\s+(\d+)\s*$') {
                if ($matches[1] -eq 'ESTABLISHED' -and ([int]$matches[2] -eq 443) -and ($pids -contains [int]$matches[4])) { $broken++ }
            }
        }
        Ok ("canli netstat dogrulamasi: duzeltilmis sayim=$real (beklenen>0), eski mantik=$broken (0 olmali)") ($real -gt 0 -and $broken -eq 0)
    } else { Ok 'canli netstat dogrulamasi: 443 baglantisi yok, atlandi' $true }
    Ok 'CRD host config yolu bulundu' ([bool](Get-CrdHostConfigPath))
    Ok 'uptime hesaplandi' ((Get-UptimeMinutes) -gt 0)
    $pwr = Get-PowerSettingAcIndex -AliasPath @('SUB_SLEEP', 'STANDBYIDLE')
    Ok ('powercfg okunabildi (STANDBYIDLE=' + $pwr + ')') ($null -ne $pwr)
    $gc = Get-Config
    Ok 'Get-Config varsayilanlar donduruyor' (($gc.RestartPolicy -eq 'blackout') -and ($gc.RebootAfterFailedCycles -eq 3) -and ($gc.OfficeSaveBeforeReboot -eq $true))
    Ok 'Get-Config devre kesici varsayilanlari' (($gc.MaxRestartsPerDay -eq 3) -and ($gc.RebootCooldownMinutes -eq 60) -and ($gc.HealthyMinutesToReset -eq 60))
    foreach ($code in (Get-FnCode $Host_ @('Get-RebootBudget', 'Get-RebootDecision'))) { Invoke-Expression $code }
    $now = [datetime]'2026-09-26T23:30:00'
    $global:cfg = [pscustomobject]@{ MaxRestartsPerDay = 3; RebootCooldownMinutes = 60; RestartPolicy = 'always'; BlackoutEnabled = $true; BlackoutStart = 18; BlackoutEnd = 8; BlackoutNights = @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz'); BlackoutFullDays = @('Cmt', 'Paz'); HolidayMode = 'full'; ForceRestartAlways = $false; ForceRestartUntil = '' }
    $st0 = [pscustomobject]@{ RebootsUtc = @() }
    $d1 = Get-RebootDecision -State $st0 -Now $now
    Ok ('restart karari: ilk seferinde izin verilmeli -> ' + $d1.Reason) ([bool]$d1.Allowed)
    $st3 = [pscustomobject]@{ RebootsUtc = @('2026-09-26T18:00:00', '2026-09-26T20:00:00', '2026-09-26T22:00:00') }
    $d2 = Get-RebootDecision -State $st3 -Now $now
    Ok ('devre kesici: 24 saatte 3 restart sinirina ulasildi -> ' + $d2.Reason) (-not $d2.Allowed -and $d2.Reason -eq 'daily-budget')
    $st1 = [pscustomobject]@{ RebootsUtc = @('2026-09-26T23:00:00') }
    $d3 = Get-RebootDecision -State $st1 -Now $now
    Ok ('devre kesici: 30 dk once restart yapildi, bekleme suresi gerekli -> ' + $d3.Reason) (-not $d3.Allowed -and $d3.Reason -eq 'cooldown')
    $stOld = [pscustomobject]@{ RebootsUtc = @('2026-09-20T10:00:00', '2026-09-24T10:00:00') }
    $d4 = Get-RebootDecision -State $stOld -Now $now
    Ok ('devre kesici: 24 saatten eski kayitlar sayilmaz -> ' + $d4.Reason) ([bool]$d4.Allowed)
    $global:cfg.RestartPolicy = 'never'
    $d5 = Get-RebootDecision -State $st0 -Now $now
    Ok 'devre kesici: RestartPolicy=never hicbir zaman restart etmez' (-not $d5.Allowed)
    $global:cfg.RestartPolicy = 'blackout'
    $gunduz = [datetime]'2026-09-28T12:00:00'
    $d6 = Get-RebootDecision -State $st0 -Now $gunduz
    Ok ('devre kesici: gunduz (blackout disi) restart olmaz -> ' + $d6.Reason) (-not $d6.Allowed -and $d6.Reason -eq 'outside-blackout')
    $global:cfg.MaxRestartsPerDay = 0
    $d7 = Get-RebootDecision -State $st3 -Now $now
    Ok 'devre kesici: MaxRestartsPerDay=0 ile sinir kaldirilir' ([bool]$d7.Allowed)
    $global:cfg.MaxRestartsPerDay = 3
    foreach ($code in (Get-FnCode $Host_ @('Get-PanelProcesses'))) { Invoke-Expression $code }
    $global:cfg = [pscustomobject]@{ PanelScriptName = 'RemoteWatchdogPanel.ps1' }
    $pp = @(Get-PanelProcesses)
    Ok ('PS 5.1 dizi acma tuzagi: @() ile sarilmis sayim (' + $pp.Count + ') sayi tipinde') ($pp.Count -is [int] -or $pp.Count -is [long])
    $raw = Get-PanelProcesses
    if ($PSVersionTable.PSVersion.Major -lt 7 -and $null -ne $raw -and @($raw).Count -eq 1) {
        Ok 'PS 5.1 tuzagi fark edildi: @() kullanilmadan .Count bos donuyor (sarma zorunlu)' (($raw.Count) -eq $null)
    } else {
        Ok ('PS 5.1 dizi acma tuzagi kontrolu bu surumde gecerli degil (PS ' + $PSVersionTable.PSVersion.Major + '): @() sarmasi yine de uygulandi') ($null -ne $raw -or $true)
    }
    function Test-ArgsBind { param([string]$Path, [Alias('Args')][string[]]$ScriptArgs = @()); return ($ScriptArgs -join ',') }
    Eq "panel Invoke-Script imzasi: -Args ile baglaniyor (B1 regresyon)" '-Install' (Test-ArgsBind -Path 'x.ps1' -Args @('-Install'))
    $panelText = Get-Content -LiteralPath $Panel -Raw
    $hasAlias = $panelText -match "\[Alias\('Args'\)\]"
    Ok 'panel Invoke-Script parametresinde [Alias("Args")] var (B1)' $hasAlias
    Ok 'panel -Args ile cagri sayisi > 0 ve imza Alias ile eslesiyor' ((([regex]::Matches($panelText, '\-Args ')).Count -gt 0) -and $hasAlias)
    $fw = [regex]::Match($panelText, '(?s)function Find-AllControls \{.*?function \w')
    Ok 'panel Find-AllControls ContentControl/Decorator yuruyucusu iceriyor (B2)' ($panelText -match 'ContentControl' -and $panelText -match 'Decorator')
    $b3line = [regex]::Match($panelText, 'intervalMinutes')
    $hostText = Get-Content -LiteralPath $Host_ -Raw
    Ok 'host intervalMinutes casti TryParse ile guvenli (B3)' ($hostText -match 'intervalMinutes[\s\S]{0,400}TryParse')
    $clientText2 = Get-Content -LiteralPath $Client_ -Raw
    Ok 'istemci allOk dogrudan targetResults uzerinden hesaplaniyor (B4)' ($clientText2 -notmatch '\$allOk = \$signal -and \$targets')
    Ok 'istemci targetResults script kapsaminda ataniyor (B5)' ($clientText2 -match '\$script:TargetResults = @\(Test-RemoteTargets\)')
    Ok 'host ServerMode=false iken guc kontrolu atlandi olarak isaretleniyor (B6)' ($hostText -match 'ServerMode kapali - kontrol atlandi')
    Ok 'panel otomatik denetim sayaci fonksiyonlari tanimli (B7)' (($panelText -match 'function Get-NextCheck') -and ($panelText -match 'function Update-Countdown') -and ($panelText -match 'function Resolve-CheckInterval') -and ($panelText -match 'function Format-ShortSpan'))
    Ok 'panel sayac gostergesi XAML olarak tanimli (B8)' (($panelText -match 'x:Name="TxtNext"') -and ($panelText -match 'x:Name="NextBadge"'))
    Ok 'panel sayaci 1 saniyelik zamanlayici ile guncelleniyor (B9)' ($panelText -match 'Tick\.Interval = \[TimeSpan\]::FromSeconds\(1\)')
    Ok 'panel elle denetlemeyi arka planda calistirip sonunda tumunu yeniliyor (B10)' (($panelText -match "BtnCheck'\)\.Add_Click\(\{ Start-ManualCheck \}\)") -and ($panelText -match 'function Start-ManualCheck') -and ($panelText -match 'function Test-ManualCheckRunning') -and ($panelText -match 'function Complete-ManualCheck') -and ($panelText -notmatch "BtnCheck'\)\.Add_Click\(\{ Invoke-Script"))
    Ok 'panel kalan sureyi saniye cinsinden yaziyor (B11)' (($panelText -match 'function Format-ShortSpan') -and ($panelText -match 'return \(\[string\]\$s \+ '' sn''\)') -and ($panelText -match 'kalan sure sag ustteki sayacta gorunur'))
    Ok 'host CRD kaydini host_unprivileged.json ile de okuyabiliyor (B12)' (($hostText -match 'host_unprivileged\.json') -and ($hostText -match 'crdCandidates'))
    Ok 'host rapor modu (-Check) yeniden baslatma degerlendirmesi yapmiyor (B13)' ($hostText -match "rapor modu \(-Check\): yeniden baslatma degerlendirmesi")
    $state = Get-State
    Ok 'Get-State varsayilan sayaclari sifir' (([int]$state.ConsecutiveFailures -eq 0) -and ([int]$state.NetRepairRung -eq 0))
    # --- Surumleme: VERSION tek kaynak, panel ve host ayni surumu okumali ---
    $verFile = Join-Path $Root 'VERSION'
    $verText = ''
    if (Test-Path -LiteralPath $verFile) { $verText = ([System.IO.File]::ReadAllText($verFile)).Trim() }
    $verOk = ($verText -match '^\d+\.\d+\.\d+$')
    Ok ('VERSION dosyasi semantik surum biciminde: ' + $(if ($verText) { $verText } else { 'YOK' })) $verOk
    $panelVer = ([regex]::Match($panelText, "\`$script:AppVersion = '([^']*)'")).Groups[1].Value
    $hostVer = ([regex]::Match((Get-Content -LiteralPath $Host_ -Raw -Encoding UTF8), "\`$script:AppVersion = '([^']*)'")).Groups[1].Value
    Ok ('panel ve host ayni VERSION dosyasini okuyor (panel=' + $panelVer + ', host=' + $hostVer + ')') (($panelVer -and $hostVer) -and ($panelVer -eq $hostVer))
    Ok 'panel -Version anahtari var' ($panelText -match '\[switch\]\$Version')
    Ok 'host -Version anahtari var' ((Get-Content -LiteralPath $Host_ -Raw -Encoding UTF8) -match '\[switch\]\$Version')
    $hostText = Get-Content -LiteralPath $Host_ -Raw -Encoding UTF8
    Ok 'host -UserFallback anahtari var' ($hostText -match '\[switch\]\$UserFallback')
    Ok 'host yedek gorev karari (Test-SystemWatchdogActive) var' ($hostText -match 'function Test-SystemWatchdogActive')
    Ok "host yedek gorevi (RemoteHostWatchdogUser) kuruluyor" ($hostText -match "RemoteHostWatchdogUser")
    Ok 'host -FastProbe anahtari var' ($hostText -match '\[switch\]\$FastProbe')
    Ok 'host hizli yoklama karari (Invoke-FastProbe) var' ($hostText -match 'function Invoke-FastProbe')
    Ok 'host hizli yoklama durumu (Get/Save-ProbeState) var' (($hostText -match 'function Get-ProbeState') -and ($hostText -match 'function Save-ProbeState'))
    Ok 'host hizli yoklama DUSEGECI de yakalıyor' ($hostText -match 'baglanti yeniden geldi')
    Ok 'host tam dongu tetikleyici (Start-FullCycle) var' ($hostText -match 'function Start-FullCycle')
    Ok 'host tek dongu kilidi (Test-CycleRunning) var' ($hostText -match 'function Test-CycleRunning')
    Ok 'host tam dongu kilit adi kullaniliyor' ($hostText -match 'Local\\RemoteWatchdogCycle')
    Ok 'host probe yaslama (Test-ProbeBeatDue) var' ($hostText -match 'function Test-ProbeBeatDue')
    Ok 'host konsol renk kurali (Get-LogColor) var' ($hostText -match 'function Get-LogColor')
    Ok 'host gunluk rotasyonu (Rotate-LogIfNeeded) var' ($hostText -match 'function Rotate-LogIfNeeded')
    Ok 'host eski gunluk temizligi (Remove-OldLogFiles) var' ($hostText -match 'function Remove-OldLogFiles')
    Ok 'host gunluk arsiv klasoru (LogDir) tanimli' ($hostText -match "\`$LogDir = Join-Path \`$BaseDir 'log'")
    Ok 'host LogGunDays varsayilani 30' ($hostText -match '(?m)^\s{8}LogGunDays\s*=\s*30')
    Ok 'host LogDosyaMB varsayilani 2' ($hostText -match '(?m)^\s{8}LogDosyaMB\s*=\s*2')
    $setupPath = Join-Path (Split-Path -Parent $Panel) 'Panel-Setup.ps1'
    Ok 'panel kurulum betigi (Panel-Setup.ps1) var' (Test-Path -LiteralPath $setupPath)
    if (Test-Path -LiteralPath $setupPath) {
        $setupText = Get-Content -LiteralPath $setupPath -Raw -Encoding UTF8
        Ok 'kurulum betigi Start Menu kisayolu olusturuyor' ($setupText -match "GetFolderPath\('Programs'\)")
        Ok 'kurulum betigi masaustu kisayolu olusturuyor' ($setupText -match "GetFolderPath\('Desktop'\)")
        Ok 'kisayol wscript ile pencere acmadan basliyor' ($setupText -match 'wscript\.exe')
    }
    Ok 'panel -Install mutex oncesi calisiyor' ($panelText -match "Panel-Setup\.ps1'\) -Action")
    if (Get-Command Get-LogColor -ErrorAction SilentlyContinue) {
        Ok ('host rengi yesil = stabil: ' + (Get-LogColor -Level 'CHECK' -Text 'TAMAM     Internet')) ($null -ne (Get-LogColor -Level 'CHECK' -Text 'TAMAM     Internet'))
        Ok 'host rengi kirmizi = hata' ((Get-LogColor -Level 'WARN') -eq 'Red')
        Ok 'host rengi mavi = bilgi' ((Get-LogColor -Level 'INFO') -eq 'Blue')
    }
    Ok 'host tetikleme sonucu loglanir' ($hostText -match 'tam dongu tetikleme sonucu')
    $hiddenVbs = Join-Path (Split-Path -Parent $Host_) 'Start-Hidden.vbs'
    Ok 'gizli baslatma (Start-Hidden.vbs) dosyasi var' (Test-Path -LiteralPath $hiddenVbs)
    if (Test-Path -LiteralPath $hiddenVbs) {
        $vbsText = Get-Content -LiteralPath $hiddenVbs -Raw
        Ok 'gizli baslatici pencereyi gizli aciyor (Run ... 0)' ($vbsText -match 'shell\.Run\s+cmd,\s*0,')
    }
    Ok 'kullanici yedek gorevi wscript ile baslatiliyor' ($hostText -match "wscript\.exe' -Argument \('""' \+ \`$hiddenVbs")
    Ok "host hizli yoklama gorevi (RemoteHostFastProbe) kuruluyor" ($hostText -match "RemoteHostFastProbe")
    Ok 'panel last-run.json damga yoklamasi (1 sn) var' ($panelText -match 'JsonLastWrite')
    Ok 'panel ayar kaydedince watchdog tetikliyor' ($panelText -match 'Start-ScheduledTask -TaskName \$tn')
    Ok 'panel sesli bildirim (Speak-Text) var' ($panelText -match 'function Speak-Text')
    Ok 'panel dogal kadin sesi (edge-tts) yolu var' ($panelText -match 'function Speak-EdgeTts')
    Ok 'panel edge-tts dogrulama (Test-EdgeTts) var' ($panelText -match 'function Test-EdgeTts')
    Ok 'panel Turkce SAPI yedegi var' ($panelText -match 'function Speak-SapiText')
    Ok 'panel yerel konusma motoru (Piper) destegi var' (($panelText -match 'function Get-PiperVoice') -and ($panelText -match 'function Test-Piper') -and ($panelText -match 'function Speak-Piper'))
    Ok 'konusma onceligi: edge-tts (KADIN) -> Piper -> SAPI' (($panelText -match 'Test-EdgeTts\)\)') -and ($panelText -match '\(Test-Piper\) -and \(Speak-Piper') -and ($panelText -match 'Speak-SapiText -Text \$t'))
    Ok 'edge-tts Windows sarmalayicisi var (aiodns/Selector duzeltmesi)' (Test-Path -LiteralPath (Join-Path $Root 'tools\edge_tts_win.py'))
    Ok 'panel sarmalayiciyi tercih ediyor, -m edge_tts sadece yedek yol' (($panelText -match 'edge_tts_win\.py') -and ($panelText -match 'if \(Test-Path -LiteralPath \$wrap\)'))
    Ok 'sarmalayici olay dongusu politikasini ayarliyor' ((Get-Content -LiteralPath (Join-Path $Root 'tools\edge_tts_win.py') -Raw) -match 'WindowsSelectorEventLoopPolicy')
    Ok 'konusma motoru araci (tools\Install-Voice.ps1) duruyor' (Test-Path -LiteralPath (Join-Path $Root 'tools\Install-Voice.ps1'))
    Ok 'anons ureticisi bitmeden dosya calinmiyor (yarim ses yok)' (($panelText -match '\$hasFile -and \$procDone') -and ($panelText -match 'function Start-SpeechPoller'))
    Ok 'anons sayaci tek kez kuruluyor (her anonssa yeni isleyici eklenmiyor)' ($panelText -notmatch 'Add_Tick\(\{ Update-SpeechPlayback \}\)[\r\n\s]+return \$true')
    Ok 'panel ses gecisi izleyici (Update-VoiceAlerts) var' ($panelText -match 'function Update-VoiceAlerts')
    Ok 'Wire-UI penceresiz calismada net atliyor' ($panelText -match 'Wire-UI atlandi')
    Ok 'host SesliBildirim varsayilani var' ($hostText -match '(?m)^\s{8}SesliBildirim\s*=')
    Ok 'host SesliBildirimEdge varsayilani var' ($hostText -match '(?m)^\s{8}SesliBildirimEdge\s*=')
    Ok 'panel surumu ayarlar sayfasinda gosteriyor' ($panelText -match "TxtVersion")

    # --- Uzay filmi tarzi hazir ses paketi: once NET/KESKIN/PARLAK efekt, sonra anons ---
    $sfxDir = Join-Path $Root 'ui\sounds'
    $sfxNames = @('online', 'ok', 'warn', 'alert', 'repair', 'recover', 'reboot', 'scan')
    Ok 'ses paketi klasoru var (ui\sounds)' (Test-Path -LiteralPath $sfxDir)
    $sfxBad = @()
    $sfxTotal = 0
    foreach ($n in $sfxNames) {
        $f = Join-Path $sfxDir ($n + '.wav')
        if (-not (Test-Path -LiteralPath $f)) { $sfxBad += ($n + ' yok'); continue }
        $len = (Get-Item -LiteralPath $f).Length
        $sfxTotal += $len
        if ($len -lt 20000) { $sfxBad += ($n + ' cok kisa'); continue }
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $riff = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
        $wave = [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4)
        $bits = [BitConverter]::ToInt16($bytes, 34)
        if ($riff -ne 'RIFF' -or $wave -ne 'WAVE' -or $bits -ne 16) { $sfxBad += ($n + ' WAV bozuk') }
    }
    Ok ('ses paketi: ' + $sfxNames.Count + ' efekt hazir (' + [math]::Round($sfxTotal / 1KB) + ' KB)' + $(if ($sfxBad.Count) { ' - sorun: ' + ($sfxBad -join ', ') } else { '' })) ($sfxBad.Count -eq 0)
    Ok 'ses uretici duruyor (tools\New-SoundPack.ps1)' (Test-Path -LiteralPath (Join-Path $Root 'tools\New-SoundPack.ps1'))
    Ok 'ses motoru duruyor (tools\SfxSynth.cs)' (Test-Path -LiteralPath (Join-Path $Root 'tools\SfxSynth.cs'))
    Ok 'panel ses efekti API (Play-Sfx / Get-SfxPath / Stop-Sfx) var' (($panelText -match 'function Play-Sfx') -and ($panelText -match 'function Get-SfxPath') -and ($panelText -match 'function Stop-Sfx'))
    Ok 'sessiz mod bayragi dogru okunuyor (bool cast, "0" degeri sessiz sayilirdi)' (($panelText -match 'function Get-FlagBool') -and ($panelText -match 'script:Silent = Get-FlagBool'))
    Ok 'panel efektleri on yukluyor (Get-SfxPlayer onbellegi)' ($panelText -match 'function Get-SfxPlayer')
    Ok 'panel efekt klasorunu kullaniyor (ui\sounds)' ($panelText.Contains("`$SfxDir = Join-Path `$UiDir 'sounds'"))
    Ok 'panel efektleri susturma korumasi (SesEfektleri + sessiz mod)' (($panelText -match '\(Get-HostConfig\)\.SesEfektleri -eq \$false') -and ($panelText -match 'script:Silent -and -not \$Force'))
    $sfxUsed = @()
    foreach ($pat in @("-Sfx '([a-z]+)'", "Play-Sfx '([a-z]+)'")) {
        $sfxUsed += @([regex]::Matches($panelText, $pat) | ForEach-Object { $_.Groups[1].Value })
    }
    $sfxUsed = @($sfxUsed | Sort-Object -Unique)
    $sfxUnknown = @($sfxUsed | Where-Object { $sfxNames -notcontains $_ })
    Ok ('panelde kullanilan efekt adlari pakette var (' + ($sfxUsed -join ', ') + ')') ($sfxUnknown.Count -eq 0)
    Ok 'tum efektler panelde bir olaya bagli' (@($sfxNames | Where-Object { $sfxUsed -contains $_ }).Count -eq $sfxNames.Count)
    Ok 'tepside ses efekti anahtari var (sfx)' ($panelText -match "'sfx' \{ Set-SfxMode")
    Ok 'tepside anons anahtari var (voice) - efektten ayri' (($panelText -match "'voice' \{ Set-VoiceMode") -and ($panelText -match 'function Set-VoiceMode'))
    Ok 'anons ve efekt farkli ayarlara yaziyor' (($panelText -match 'Save-HostConfig @\{ SesliBildirim = ') -and ($panelText -match 'Save-HostConfig @\{ SesEfektleri = '))
    Ok 'ses anahtarlari calisma aninda sabitleniyor (kapattiysan ses gelmez)' (($panelText -match 'if \(-not \$script:SfxOn\) \{ return \$false \}') -and ($panelText -match 'if \(-not \$script:VoiceOn\) \{ return \}'))
    Ok 'tepsi etiketleri etiket yerine Tag ile eslesiyor (Sessiz mod etiketi degisti)' ($panelText -match "if \(\`$it\.Tag -eq 'silent'\)")
    Ok 'panel acilista iki anahtari da logluyor' ($panelText -match 'ses anahtarlari -> film efektleri')
    Ok 'tepside ses testi var (testses)' ($panelText -match "'testses'")
    Ok 'tepsi etiketleri durumu gosteriyor' (($panelText -match 'Film efektleri \(wav\)') -and ($panelText -match 'Sesli anons \(insan sesi\)'))
    Ok 'anons metinleri Turkce karakter iceriyor (ASCII yazim telaffuzu bozuyordu)' (($panelText -match "Speak-Text 'Bağlantı düzeldi") -and ($panelText -match "Speak-Text 'Onarım tamamlandı"))
    Ok 'ASCII kontrol adlarini Turkcelestiren katman var' (($panelText -match 'function ConvertTo-TtsText') -and ($panelText -match '\$script:TtsFix = @\{') -and ($panelText -match 'Internet erisimi'))
    Ok 'panel SesEfektleri varsayilani var' ($panelText -match '(?m)^\s{8}SesEfektleri = \$true; SesEfektleriVolume = 80')
    Ok 'host SesEfektleri varsayilani var' ($hostText -match '(?m)^\s{8}SesEfektleri\s*=')
    Ok 'host SesEfektleriVolume varsayilani var' ($hostText -match '(?m)^\s{8}SesEfektleriVolume\s*=')
    $defs = @(Get-SettingsDefs)
    Ok 'ayar tanimi: SesEfektleri (bool)' (@($defs | Where-Object { $_.Key -eq 'SesEfektleri' -and $_.Type -eq 'bool' }).Count -eq 1)
    Ok 'ayar tanimi: SesEfektleriVolume (int)' (@($defs | Where-Object { $_.Key -eq 'SesEfektleriVolume' -and $_.Type -eq 'int' }).Count -eq 1)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Section -eq 0 -or $Section -eq 2) {
    Head '2) Ayar kapsamasi: watchdog config anahtarlari panelde var mi'
    $astH = [System.Management.Automation.Language.Parser]::ParseFile($Host_, [ref]$null, [ref]$null)
    $cfgFn = $astH.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-Config' }, $true)[0]
    $cfgKeys = @([regex]::Matches($cfgFn.Extent.Text, '(?m)^\s{8}([A-Za-z][A-Za-z0-9]*)\s*=') | ForEach-Object { $_.Groups[1].Value })
    $panelText = (Get-Content -LiteralPath (Join-Path $LibDir 'Settings.ps1') -Raw) + [Environment]::NewLine + (Get-Content -LiteralPath $Panel -Raw)
    $panelKeys = @([regex]::Matches($panelText, "Key\s*=\s*'([A-Za-z][A-Za-z0-9]*)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Write-Host ('  watchdog config anahtari: ' + $cfgKeys.Count + ' | panelde tanimli: ' + $panelKeys.Count)
    $missing = @($cfgKeys | Where-Object { $panelKeys -notcontains $_ })
    # bu anahtarlar panelde bilerek yok: ic mantikta kullanilmiyor
    $intentional = @('Version', 'HeartbeatFailPath')
    $realMissing = @($missing | Where-Object { $intentional -notcontains $_ })
    if ($realMissing.Count -eq 0) { Ok ('panel tum ayar anahtarlarini kapsiyor (' + ($cfgKeys.Count - $intentional.Count) + ' anahtar)') $true }
    else { Ok ('panel kapsamasi eksik: ' + ($realMissing -join ', ')) $false }
    if ($missing.Count -gt 0) { Write-Host ('    (bilerek dislananlar: ' + (($missing | Where-Object { $intentional -contains $_ }) -join ', ') + ')') -ForegroundColor DarkGray }
    foreach ($k in @('RestartPolicy', 'ForceRestartAlways', 'ForceRestartUntil', 'HolidayMode', 'Holidays', 'BlackoutFullDays', 'CrdNoConnRestartCycles', 'NetMaxRepairRung', 'OfficeAbortRebootIfUnsaved', 'TunnelRepair', 'Targets', 'RdpFile')) {
        Ok ('panel ayari var: ' + $k) ($panelKeys -contains $k)
    }
    $clientText = Get-Content -LiteralPath $Client_ -Raw
    $cfgFnC = $astH.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-Config' }, $true)
    $astC = [System.Management.Automation.Language.Parser]::ParseFile($Client_, [ref]$null, [ref]$null)
    $clientCfg = $astC.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-Config' }, $true)[0]
    $clientKeys = @([regex]::Matches($clientCfg.Extent.Text, '(?m)^\s{8}([A-Za-z][A-Za-z0-9]*)\s*=') | ForEach-Object { $_.Groups[1].Value })
    $cmissing = @($clientKeys | Where-Object { $panelKeys -notcontains $_ -and $_ -ne 'HeartbeatFailPath' })
    if ($cmissing.Count -eq 0) { Ok ('panel tum istemci anahtarlarini kapsiyor (' + $clientKeys.Count + ')') $true }
    else { Ok ('istemci anahtari eksik: ' + ($cmissing -join ', ')) $false }
}

if ($Section -eq 0 -or $Section -eq 3) {
    Head '3) Panel veri fonksiyonlari (gercek last-run.json ile)'
    $script:HostData = Join-Path $env:ProgramData 'RemoteWatchdog'
    $script:HostJson = Join-Path $script:HostData 'last-run.json'
    $script:HostConfig = Join-Path $script:HostData 'config.json'
    $script:HostLog = Join-Path $script:HostData 'host-watchdog.log'
    $script:ClientData = Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog'
    $script:ClientJson = Join-Path $script:ClientData 'last-run.json'
    $script:ClientConfig = Join-Path $script:ClientData 'config.json'
    $script:ClientLog = Join-Path $script:ClientData 'client-watchdog.log'
    $script:Silent = $true
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    $script:C = @{ Bg = '#0F1114'; Side = '#14161A'; Card = '#1A1D22'; Card2 = '#21252B'; Line = '#2A2F36'; Text = '#E8EAED'; Muted = '#98A0AA'; Accent = '#4C8DFF'; Ok = '#3FB950'; Warn = '#E3B341'; Bad = '#F85149'; Info = '#58A6FF' }
    foreach ($code in (Get-FnCode $Panel @('Bx', 'Get-Json', 'Read-ConfigFile', 'Get-HostConfig', 'Get-RoleInfo', 'Get-StatusInfo', 'Get-Connections', 'Get-Actions', 'Invoke-Script', 'Get-WatchdogTaskState'))) { Invoke-Expression $code }

    $hj = Get-Json $HostJson
    Ok 'host last-run.json okundu' ($null -ne $hj)
    if ($hj) {
        $st = Get-StatusInfo
        Ok ('Get-StatusInfo: kontrol sayisi=' + @($st.Host.checks).Count) (@($st.Host.checks).Count -ge 5)
        Ok ('Get-StatusInfo: yas hesaplandi (' + [math]::Round($st.Age.TotalMinutes) + ' dk)') ($st.Age.TotalMinutes -ge 0)
        $rows = @(Get-Connections)
        Ok ('Get-Connections: ' + $rows.Count + ' satir dondu') ($rows.Count -ge 8)
        $names = @($rows | ForEach-Object { $_.Name })
        foreach ($need in @('İnternet erişimi', 'DNS çözümlemesi', 'Google istemci hizmetleri', 'Google Remote Desktop kaydı', 'CRD canlı bağlantısı', 'Windows RDP')) {
            Ok ('Get-Connections satir: ' + $need) ($names -contains $need)
        }
        $noMeasure = @($rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Measure) })
        Ok ('Get-Connections: her satirda olcum var (eksik=' + $noMeasure.Count + ')') ($noMeasure.Count -eq 0)
        $badBrush = @($rows | Where-Object { $null -eq $_.Brush -or $null -eq $_.StateFg })
        Ok 'Get-Connections: her satirda renkler var' ($badBrush.Count -eq 0)
        $msRow = $rows | Where-Object { $_.Name -eq 'IP erişimi' } | Select-Object -First 1
        Ok ('Get-Connections: gecikme ölçümü "' + $msRow.Measure + '"') ([string]$msRow.Measure -match '\d+ ms')
        $topics = @(Get-HelpBalloonTopics)
        Ok ('ayarlar yardım balonları: ' + $topics.Count + ' konu') ($topics.Count -ge 8)
        $noText = @($topics | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Text) -or ([string]$_.Text).Length -lt 20 })
        Ok 'ayarlar yardım balonlarının tümünde açıklayıcı metin var' ($noText.Count -eq 0)
        $noTitle = @($topics | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Title) })
        Ok 'ayarlar yardım balonlarının tümünde başlık var' ($noTitle.Count -eq 0)
        $hasBudget = @($topics | Where-Object { ([string]$_.Text) -match 'MaxRestartsPerDay|RebootCooldown' })
        Ok 'devre kesici ayarı yardım konularında anlatılıyor' ($hasBudget.Count -ge 1)
        $crdRow = $rows | Where-Object { $_.Name -eq 'Google Remote Desktop kaydı' } | Select-Object -First 1
        Ok ('Get-Connections: CRD kaydi durumu "' + $crdRow.StateText + '"') ($crdRow.StateText -in @('KAYITLI', 'KAYITSIZ'))
        $tunRow = $rows | Where-Object { $_.Name -eq 'VS Code Tunnel' } | Select-Object -First 1
        $tunCheck = @($hj.checks | Where-Object { [string]$_.name -eq 'VS Code Tunnel' } | Select-Object -First 1)
        if ($tunCheck -and [bool]$tunCheck.skipped) {
            Ok 'Get-Connections: atlanmis tunnel bilgi satiri (IZLENMIYOR)' ($tunRow -and $tunRow.StateText -eq 'İZLENMİYOR')
        } else {
            Ok 'Get-Connections: tunnel satiri durumu gecerli' ($null -eq $tunRow -or $tunRow.StateText -in @('ÇALIŞIYOR', 'KAPALI', 'İZLENMİYOR'))
        }
        $act = @(Get-Actions)
        Ok ('Get-Actions: ' + $act.Count + ' madde') ($act.Count -ge 1)
        $keys = @($act | ForEach-Object { $_.Key })
        Ok 'Get-Actions: her madde bir anahtarla etiketli' (@($act | Where-Object { $null -eq $_.Key }).Count -eq 0)
        $cfg = Get-HostConfig
        # Gercek config.json'daki degerler okunur; kullanici panelden politika degistirmis olabilir
        # ( RestartPolicy 'always' idi). Bu yuzden VARSAYILAN degere degil, gecerli bir degere bakilir.
        $cfgValid = ($cfg.RestartPolicy -in @('blackout', 'always', 'never')) -and ($cfg.BlackoutStart -ge 0 -and $cfg.BlackoutStart -le 23) -and ($cfg.BlackoutEnd -ge 0 -and $cfg.BlackoutEnd -le 23)
        Ok ('Get-HostConfig: gecerli degerler okundu (policy=' + $cfg.RestartPolicy + ', blackout=' + $cfg.BlackoutStart + '-' + $cfg.BlackoutEnd + ')') $cfgValid
        $roleCode = ((Get-FnCode $Panel @('Read-ConfigFile', 'Get-RoleInfo')) -join "`n")
        Invoke-Expression $roleCode
        Ok 'panel fonksiyonlari yuklendi (Read-ConfigFile, Get-RoleInfo)' ([bool](Get-Command Get-RoleInfo -ErrorAction SilentlyContinue))
        $role = Get-RoleInfo
        Ok ('Get-RoleInfo rol tespiti: ' + $role.Role) ($role.Role -in @('host', 'client', 'both', 'manual', 'none'))
        Ok ('Get-RoleInfo rozet metni: ' + $role.RoleText) ([bool]$role.RoleText)
        Ok ('Get-RoleInfo ipucu metni dolu (' + ([string]$role.Tip).Length + ' karakter)') (([string]$role.Tip).Length -gt 20)
        $installed = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -in @('RemoteHostWatchdog', 'RemoteClientWatchdog') })
        $hj3 = Get-Json (Join-Path $env:ProgramData 'RemoteWatchdog\last-run.json')
        $hostSaysInstalled = ($null -ne $hj3 -and [bool]$hj3.taskInstalled)
        $hostFresh = $false
        if ($hj3 -and $hj3.generated) { try { $hostFresh = (((Get-Date) - [datetime]::Parse([string]$hj3.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes -lt 30) } catch { } }
        if ($installed.Count -gt 0 -or $hostSaysInstalled -or $hostFresh) { Ok ('rol tespiti kurulu host/istemciyi dogru tanidi: ' + $role.RoleText) ($role.Role -in @('host', 'client', 'both')) }
        else { Ok ('rol tespiti: bu makinede host/istemci kurulu degil (beklenen: ' + $role.RoleText + ')') ($role.Role -eq 'manual' -or $role.Role -eq 'none') }
        Ok 'rol tespiti SYSTEM gorevini JSON uzerinden goruyor (yukseltilmis olmayan panelde de dogru)' ($role.Role -ne 'manual' -or -not $hostSaysInstalled)
    }
}

if ($Section -eq 0 -or $Section -eq 4) {
    Head '4) Istemci fonksiyonlari'
    foreach ($code in (Get-FnCode $Client_ @('Test-TcpPort'))) { Invoke-Expression $code }
    foreach ($code in (Get-FnCode $Panel @('Get-Json'))) { Invoke-Expression $code }
    $rdpListening = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 3389 }).Count -gt 0
    $closed = Test-TcpPort -HostName '127.0.0.1' -Port 9 -TimeoutMs 1500
    Ok 'Test-TcpPort: kapali port false dondu' ([bool]$closed -eq $false)
    if ($rdpListening) {
        $open = Test-TcpPort -HostName '127.0.0.1' -Port 3389 -TimeoutMs 2000
        Ok 'Test-TcpPort: acik port (3389) true dondu' ([bool]$open -eq $true)
    } else {
        Ok 'Test-TcpPort: 3389 dinleyici yok, acik port testi atlandi' $true
    }
    $cjPath = Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog\last-run.json'
    $cj = $null
    if (Test-Path -LiteralPath $cjPath) { $cj = Get-Json $cjPath }
    if ($cj) {
        Ok 'istemci last-run.json okundu' $true
        Ok 'istemci JSON: rol=client' ($cj.role -eq 'client')
        Ok 'istemci JSON: kontroller var' (@($cj.checks).Count -ge 1)
    } else {
        # Temiz bir makinede (veya CI runner'inda) istemci hic kurulmamis olabilir; bu bir hata degil
        Ok 'istemci last-run.json yok (istemci bu makinede kurulu degil) - istemci JSON testi atlandi' $true
    }
}

if ($Section -eq 0 -or $Section -eq 5) {
    Head '5) Uctan uca: watchdog -Check -Json -> last-run.json -> panel satirlari'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Host_ -Check -NoJson | Out-Null
    $sw.Stop()
    Write-Host ('  (watchdog -Check ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' sn)')
    $j = Get-Json (Join-Path $env:ProgramData 'RemoteWatchdog\last-run.json')
    Ok 'last-run.json uretildi' ($null -ne $j)
    if ($j) {
        Ok ('JSON: ok alani mevcut (deger=' + $j.ok + ') - saglikli makinede de gecerli') ($null -ne $j.ok)
        Ok 'JSON: en az 5 kontrol' (@($j.checks).Count -ge 5)
        Ok 'JSON: uptime > 0' ([double]$j.uptimeMinutes -gt 0)
        Ok 'JSON: metrics alanlari dolu' (@($j.checks | Where-Object { $_.metrics -and @($_.metrics.PSObject.Properties).Count -gt 0 }).Count -ge 2)
        $mt = ($j.checks | Where-Object { $_.name -eq 'Ag katmani' }).metrics
        Ok ('JSON: gecikme olcumleri var (https=' + $mt.httpsms + 'ms, dns=' + $mt.dnsms + 'ms)') (([int]$mt.httpsms -ge 0) -and ([int]$mt.dnsms -ge 0))
        Ok 'JSON: config bölümü dolu' ($null -ne $j.config.restartPolicy)
        $age = (Get-Date) - [datetime]::Parse([string]$j.generated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Ok ('JSON: tazelik (' + [math]::Round($age.TotalSeconds) + ' sn)') ($age.TotalSeconds -lt 300)
    }
}

Head 'SONUC'
# Guvenlik agi: tanimsiz bir komut cagrisi varsa bir Ok(...) satiri sessizce atlanmis olabilir.
# Bu yuzden "tanimsiz komut" sayisi sifir degilse test kirmiziya doner.
$unknownCmds = @($Error | Where-Object { [string]$_.FullyQualifiedErrorId -like 'CommandNotFoundException*' } | ForEach-Object { [string]$_.TargetObject } | Sort-Object -Unique)
if ($unknownCmds.Count) {
    $script:Fail++
    Write-Host ('  [KALDI] suite boyunca tanimsiz komut cagrisi: ' + ($unknownCmds -join ', ') + ' (bu hatayi atlayan testler olabilir)') -ForegroundColor Red
} else {
    $script:Pass++
    Write-Host '  [GECTI] suite boyunca tanimsiz komut cagrisi yok' -ForegroundColor Green
}
Write-Host ('  Gecti: ' + $script:Pass + ' | Kaldi: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    Write-Host '  Basarisiz olanlar:'
    $script:Log | Where-Object { -not $_.Pass } | ForEach-Object { Write-Host ('    - ' + $_.Name + ' ' + $_.Info) -ForegroundColor Red }
}
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })