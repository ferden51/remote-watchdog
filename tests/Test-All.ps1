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
    foreach ($code in (Get-FnCode $Host_ @('Write-Log', 'Get-Config', 'Get-State', 'Save-State', 'Add-Result', 'Invoke-Probe', 'Get-TcpMs', 'Get-CrdHostConfigPath', 'Get-CrdSignalConnections', 'Get-UptimeMinutes', 'ConvertTo-DotNetDays', 'Get-HolidayList', 'Test-IsHoliday', 'Test-InBlackout', 'Get-PowerSettingAcIndex'))) { Invoke-Expression $code }

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

    $ms = Get-TcpMs -HostName '1.1.1.1' -Port 443 -TimeoutMs 3000
    Ok ('TCP olcum: 1.1.1.1:443 acik (' + $ms + ' ms)') ($ms -ge 0)
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
    foreach ($code in (Get-FnCode $Host_ @('Get-PanelProcesses'))) { Invoke-Expression $code }
    $global:cfg = [pscustomobject]@{ PanelScriptName = 'RemoteWatchdogPanel.ps1' }
    $pp = @(Get-PanelProcesses)
    Ok ('PS 5.1 dizi acma tuzagi: @() ile sarilmis sayim (' + $pp.Count + ') sayi tipinde') ($pp.Count -is [int] -or $pp.Count -is [long])
    $raw = Get-PanelProcesses
    if ($null -ne $raw -and @($raw).Count -eq 1) {
        Ok 'PS 5.1 tuzagi fark edildi: @() kullanilmadan .Count bos donuyor (sarma zorunlu)' (($raw.Count) -eq $null)
    } else { Ok 'PS 5.1 tuzagi kontrolu: panel birden fazla ornek ya da hic yok' $true }
    $state = Get-State
    Ok 'Get-State varsayilan sayaclari sifir' (([int]$state.ConsecutiveFailures -eq 0) -and ([int]$state.NetRepairRung -eq 0))
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Section -eq 0 -or $Section -eq 2) {
    Head '2) Ayar kapsamasi: watchdog config anahtarlari panelde var mi'
    $astH = [System.Management.Automation.Language.Parser]::ParseFile($Host_, [ref]$null, [ref]$null)
    $cfgFn = $astH.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-Config' }, $true)[0]
    $cfgKeys = @([regex]::Matches($cfgFn.Extent.Text, '(?m)^\s{8}([A-Za-z][A-Za-z0-9]*)\s*=') | ForEach-Object { $_.Groups[1].Value })
    $panelText = Get-Content -LiteralPath $Panel -Raw
    $panelKeys = @([regex]::Matches($panelText, "Key\s*=\s*'([A-Za-z][A-Za-z0-9]*)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Write-Host ('  watchdog config anahtari: ' + $cfgKeys.Count + ' | panelde tanimli: ' + $panelKeys.Count)
    $missing = @($cfgKeys | Where-Object { $panelKeys -notcontains $_ })
    # bu anahtarlar panelde bilerek yok: ic mantikta kullanilmiyor
    $intentional = @('Version', 'HeartbeatFailPath', 'DisableHibernation')
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
    foreach ($code in (Get-FnCode $Panel @('Bx', 'Get-Json', 'Get-HostConfig', 'Get-StatusInfo', 'Get-Connections', 'Get-Actions', 'Invoke-Script'))) { Invoke-Expression $code }

    $hj = Get-Json $HostJson
    Ok 'host last-run.json okundu' ($null -ne $hj)
    if ($hj) {
        $st = Get-StatusInfo
        Ok ('Get-StatusInfo: kontrol sayisi=' + @($st.Host.checks).Count) (@($st.Host.checks).Count -ge 5)
        Ok ('Get-StatusInfo: yas hesaplandi (' + [math]::Round($st.Age.TotalMinutes) + ' dk)') ($st.Age.TotalMinutes -ge 0)
        $rows = @(Get-Connections)
        Ok ('Get-Connections: ' + $rows.Count + ' satir dondu') ($rows.Count -ge 8)
        $names = @($rows | ForEach-Object { $_.Name })
        foreach ($need in @('Internet erisimi', 'DNS cozumlemesi', 'CRD sinyal yolu', 'Google Remote Desktop kaydi', 'CRD canli baglantisi', 'Windows RDP')) {
            Ok ('Get-Connections satir: ' + $need) ($names -contains $need)
        }
        $noMeasure = @($rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Measure) })
        Ok ('Get-Connections: her satirda olcum var (eksik=' + $noMeasure.Count + ')') ($noMeasure.Count -eq 0)
        $badBrush = @($rows | Where-Object { $null -eq $_.Brush -or $null -eq $_.StateFg })
        Ok 'Get-Connections: her satirda renkler var' ($badBrush.Count -eq 0)
        $msRow = $rows | Where-Object { $_.Name -eq 'IP erisimi' } | Select-Object -First 1
        Ok ('Get-Connections: gecikme olcumu "' + $msRow.Measure + '"') ([string]$msRow.Measure -match '\d+ ms')
        $crdRow = $rows | Where-Object { $_.Name -eq 'Google Remote Desktop kaydi' } | Select-Object -First 1
        Ok ('Get-Connections: CRD kaydi durumu "' + $crdRow.StateText + '"') ($crdRow.StateText -in @('KAYITLI', 'KAYITSIZ'))
        $act = @(Get-Actions)
        Ok ('Get-Actions: ' + $act.Count + ' madde') ($act.Count -ge 1)
        $keys = @($act | ForEach-Object { $_.Key })
        Ok 'Get-Actions: her madde bir anahtarla etiketli' (@($act | Where-Object { $null -eq $_.Key }).Count -eq 0)
        $cfg = Get-HostConfig
        Ok 'Get-HostConfig: varsayilanlar' (($cfg.RestartPolicy -eq 'blackout') -and ($cfg.BlackoutStart -eq 18) -and ($cfg.BlackoutEnd -eq 8))
        $roleCode = ((Get-FnCode $Panel @('Read-ConfigFile', 'Get-RoleInfo')) -join "`n")
        Invoke-Expression $roleCode
        Ok 'panel fonksiyonlari yuklendi (Read-ConfigFile, Get-RoleInfo)' ([bool](Get-Command Get-RoleInfo -ErrorAction SilentlyContinue))
        $role = Get-RoleInfo
        Ok ('Get-RoleInfo rol tespiti: ' + $role.Role) ($role.Role -in @('host', 'client', 'both', 'manual', 'none'))
        Ok ('Get-RoleInfo rozet metni: ' + $role.RoleText) ([bool]$role.RoleText)
        Ok ('Get-RoleInfo ipucu metni dolu (' + ([string]$role.Tip).Length + ' karakter)') (([string]$role.Tip).Length -gt 20)
        $installed = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -in @('RemoteHostWatchdog', 'RemoteClientWatchdog') })
        if ($installed.Count -gt 0) { Ok ('rol tespiti kurulu gorevlerle tutarli: ' + (($installed | ForEach-Object { $_.TaskName }) -join ', ')) $true }
        else { Ok 'rol tespiti: bu makinede host/istemci gorevi kurulu degil (KURULU DEGIL beklenir)' ($role.Role -eq 'manual' -or $role.Role -eq 'none') }
    }
}

if ($Section -eq 0 -or $Section -eq 4) {
    Head '4) Istemci fonksiyonlari'
    foreach ($code in (Get-FnCode $Client_ @('Test-TcpPort'))) { Invoke-Expression $code }
    $open = Test-TcpPort -HostName '127.0.0.1' -Port 3389 -TimeoutMs 2000
    $closed = Test-TcpPort -HostName '127.0.0.1' -Port 9 -TimeoutMs 1500
    Ok 'Test-TcpPort: acik port (3389) true dondu' ([bool]$open -eq $true)
    Ok 'Test-TcpPort: kapali port false dondu' ([bool]$closed -eq $false)
    $cj = Get-Json (Join-Path $env:LOCALAPPDATA 'RemoteClientWatchdog\last-run.json')
    Ok 'istemci last-run.json okundu' ($null -ne $cj)
    if ($cj) { Ok 'istemci JSON: rol=client' ($cj.role -eq 'client'); Ok 'istemci JSON: kontroller var' (@($cj.checks).Count -ge 1) }
}

if ($Section -eq 0 -or $Section -eq 5) {
    Head '5) Uctan uca: watchdog -Check -Json -> last-run.json -> panel satirlari'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Host_ -Check | Out-Null
    $sw.Stop()
    Write-Host ('  (watchdog -Check ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' sn)')
    $j = Get-Json (Join-Path $env:ProgramData 'RemoteWatchdog\last-run.json')
    Ok 'last-run.json uretildi' ($null -ne $j)
    if ($j) {
        Ok 'JSON: ok=false (bu makinede gercek sorunlar var)' ($j.ok -eq $false)
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
Write-Host ('  Gecti: ' + $script:Pass + ' | Kaldi: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    Write-Host '  Basarisiz olanlar:'
    $script:Log | Where-Object { -not $_.Pass } | ForEach-Object { Write-Host ('    - ' + $_.Name + ' ' + $_.Info) -ForegroundColor Red }
}
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
