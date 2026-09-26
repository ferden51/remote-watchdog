#Requires -Version 5.1
<#
    Collect-Diagnostics - "uzak masaustu neden koptu" tehis paketi
    Hicbir ayari degistirmez; yalnizca okur ve tek bir rapor dosyasi yazar.
    Guncellenmis cikti ile watchdog revizyonu yapilir.

    .\Collect-Diagnostics.ps1
    .\Collect-Diagnostics.ps1 -OutFile 'C:\temp\rd-diag.md' -Days 14
#>
[CmdletBinding()]
param(
    [string]$OutFile = '',
    [int]$Days = 14
)

$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$L = New-Object System.Collections.ArrayList
$Suspects = New-Object System.Collections.ArrayList

function Add-Line { param([string]$Text = '') [void]$L.Add($Text) }
function Add-Section { param([string]$Title) Add-Line ''; Add-Line ('## ' + $Title); Add-Line '' }
function Add-Suspect { param([string]$Text, [string]$Weight = 'orta') [void]$Suspects.Add([pscustomobject]@{ Weight = $Weight; Text = $Text }) }
function Mask {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '(bos)' }
    if ($Value.Length -le 8) { return $Value }
    return $Value.Substring(0, 4) + '...' + $Value.Substring($Value.Length - 4) + ' (' + $Value.Length + ' karakter)'
}
function Fmt { param($Value) if ($null -eq $Value) { return 'null' } return ($Value | Out-String).Trim() }
function Get-AcIndexSeconds {
    param([string[]]$AliasPath)
    $out = (powercfg /query SCHEME_CURRENT @AliasPath 2>&1 | Out-String)
    $m = [regex]::Match($out, '(?i)0x([0-9a-f]{8})')
    if ($m.Success) { return [convert]::ToInt32($m.Groups[1].Value, 16) }
    return $null
}

function Get-Events {
    param([string]$Log, [int[]]$Ids = @(), [string]$Match = '', [int]$Max = 60)
    $start = (Get-Date).AddDays(-$Days)
    $h = @{ LogName = $Log; StartTime = $start }
    if ($Ids.Count -gt 0) { $h['Id'] = $Ids }
    $ev = @()
    try { $ev = Get-WinEvent -FilterHashtable $h -MaxEvents 2000 -ErrorAction Stop } catch { return @() }
    $out = @($ev | Where-Object { -not $Match -or $_.Message -match $Match } | Sort-Object TimeCreated -Descending | Select-Object -First $Max)
    return $out
}

function Event-Lines {
    param($Events)
    if (-not $Events -or @($Events).Count -eq 0) { Add-Line '- (kayit yok)'; return }
    foreach ($e in $Events) {
        $first = ''
        try { $first = (($e.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) } catch { }
        Add-Line ('- {0} | ID={1} | {2} | {3}' -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.Id, $e.LevelDisplayName, ($first -replace '\s+', ' '))
    }
}

$since = (Get-Date).AddDays(-$Days)

Add-Line ('# Uzak masaustu tehis raporu - ' + $env:COMPUTERNAME)
Add-Line ''
Add-Line ('- Rapor zamani: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Line ('- Kullanici/session: ' + $env:USERNAME + ' / ' + $env:SESSIONNAME)
$os = Get-CimInstance -ClassName Win32_OperatingSystem
Add-Line ('- Isletim sistemi: ' + $os.Caption + ' ' + $os.Version + ' (build ' + $os.BuildNumber + ')')
Add-Line ('- Son acilis: ' + $os.LastBootUpTime + ' | uptime ' + [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) + ' gun')
Add-Line ('- Inceleme araligi: son ' + $Days + ' gun')

Add-Section '1. Guclendirilmis sonuc (supheli kaliplar)'
Add-Line 'Raporun sonundaki "Oneriler" bolumune bak; burada sadece puanli supheliler listelenir.'

Add-Section '2. Google Remote Desktop (CRD) durumu'
$crdSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='chromoting'" -ErrorAction SilentlyContinue
if ($crdSvc) {
    Add-Line ('- Servis: ' + $crdSvc.Name + ' | durum=' + $crdSvc.State + ' | start=' + $crdSvc.StartMode + ' | hesap=' + $crdSvc.StartName)
    Add-Line ('- Binary: ' + $crdSvc.PathName)
    $sc = sc.exe qfailure chromoting 2>&1 | Out-String
    if ($sc.Trim()) { Add-Line ('- Servis hata aksiyonu: ' + (($sc -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join ' / ')) }
    $scInfo = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7035; StartTime = $since } -MaxEvents 200 | Where-Object { $_.Message -match 'chromoting' }
    if ($scInfo) { Add-Suspect ('chromoting servisi ' + @($scInfo).Count + ' kez yeniden kurulmus') 'yuksek' }
} else {
    Add-Line '- chromoting servisi YOK'
    Add-Suspect 'CRD host servisi kayit degil' 'yuksek'
}
$crdDir = 'C:\Program Files (x86)\Google\Chrome Remote Desktop'
if (-not (Test-Path $crdDir)) { $crdDir = 'C:\Program Files\Google\Chrome Remote Desktop' }
if (Test-Path $crdDir) {
    Add-Line ('- Kurulum dizini: ' + $crdDir)
    Get-ChildItem -LiteralPath $crdDir -Force -ErrorAction SilentlyContinue | ForEach-Object { Add-Line ('  - ' + $_.Name + ' | degisiklik: ' + $_.LastWriteTime) }
    $vers = @(Get-ChildItem -LiteralPath $crdDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d' } | Sort-Object LastWriteTime)
    if ($vers.Count -gt 0) {
        Add-Line ('- Son guncelleme: ' + $vers[-1].Name + ' (' + $vers[-1].LastWriteTime + ')')
        if ($vers[-1].LastWriteTime -gt (Get-Date).AddDays(-30)) { Add-Suspect ('CRD host ' + $vers[-1].Name + ' versiyonuna son 30 gunde guncellenmis; yeni surum kaydi sifirlamis olabilir') 'orta' }
    }
} else { Add-Line '- CRD host dizini bulunamadi'; Add-Suspect 'CRD host kurulu degil' 'yuksek' }

$cfgPath = 'C:\ProgramData\Google\Chrome Remote Desktop\host.json'
$svcPath = $crdSvc.PathName
if ($svcPath -and $svcPath -match '--host-config="?([^";]+)"?') { $cfgPath = $matches[1].Trim() }
Add-Line ('- Host config yolu: ' + $cfgPath + ' | var=' + (Test-Path -LiteralPath $cfgPath))
if (Test-Path -LiteralPath $cfgPath) {
    $fi = Get-Item -LiteralPath $cfgPath
    Add-Line ('  - degisiklik: ' + $fi.LastWriteTime + ' | boyut: ' + $fi.Length)
    try {
        $j = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            $v = [string]$p.Value
            if ($p.Name -match '(?i)token|secret|password|key|credential') { Add-Line ('  - ' + $p.Name + ' = ' + (Mask $v) + ' [gizli: maskelendi]') }
            else { Add-Line ('  - ' + $p.Name + ' = ' + (Mask $v)) }
        }
        if (-not $j.PSObject.Properties['host_id']) { Add-Suspect 'host.json var ama host_id alani yok' 'yuksek' }
    } catch { Add-Line '  - host.json okunamadi (bozuk JSON?)'; Add-Suspect 'host.json bozuk' 'yuksek' }
} else { Add-Suspect 'host.json YOK -> cihaz Google hesabinda listelenmiyor, yeniden kayit gerekir' 'kritik' }
$pd = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Google\Chrome Remote Desktop\paired-clients' -ErrorAction SilentlyContinue
if ($pd) { Add-Line ('- Pairs/linked clients anahtarlari: ' + (@($pd.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }).Count)) }
$logKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Google\Chrome Remote Desktop\logging' -ErrorAction SilentlyContinue
if ($logKey) { Add-Line ('- Logging ayari: ' + (($logKey.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $_.Name + '=' + $_.Value }) -join ', ')) } else { Add-Line '- CRD logging ayari yok (log dosyasi tutulmuyor -> gecmise donuk kanit yok)' }
$crdProcs = Get-Process -Name 'remoting_host', 'remoting_start_host', 'remoting_desktop' -ErrorAction SilentlyContinue
if ($crdProcs) { $crdProcs | ForEach-Object { Add-Line ('- Surec: ' + $_.ProcessName + ' PID=' + $_.Id + ' baslangic=' + $_.StartTime) } } else { Add-Line '- CRD daemon surucu calismiyor' }
$chrome = @('C:\Program Files\Google\Chrome\Application\chrome.exe', 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe', (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
Add-Line ('- Chrome kurulu: ' + $(if ($chrome) { $chrome } else { 'HAYIR (CRD kaydi icin Chrome gerekli)' }))

Add-Section '3. Windows RDP durumu'
$ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
Add-Line ('- fDenyTSConnections: ' + $ts.fDenyTSConnections + ' (0 = RDP acik)')
$tsPol = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
if ($tsPol) {
    foreach ($p in $tsPol.PSObject.Properties) {
        if ($p.Name -match '^PS') { continue }
        Add-Line ('- GPO: ' + $p.Name + ' = ' + (Fmt $p.Value))
    }
    if ($tsPol.PSObject.Properties['MaxIdleTime']) { Add-Suspect ('GPO MaxIdleTime=' + $tsPol.MaxIdleTime + ' dk -> RDP oturumlari bos kalinca otomatik KAPATILIR ("baglanti koptu" hissi)') 'yuksek' }
    if ($tsPol.PSObject.Properties['fDenyTSConnections'] -and $tsPol.fDenyTSConnections -eq 1) { Add-Suspect 'GPO ile RDP kapali' 'yuksek' }
}
$tsUser = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\TSAppAllowList' -ErrorAction SilentlyContinue
$fwrules = @(Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue | Sort-Object Name)
Add-Line '- Firewall kurallari:'
foreach ($r in $fwrules) { Add-Line ('  - ' + $r.Name + ' | enabled=' + $r.Enabled + ' | yon=' + $r.Direction + ' | aksiyon=' + $r.Action) }
if (@($fwrules | Where-Object { $_.Enabled -ne 'True' }).Count -gt 0) { Add-Suspect ('RDP firewall kurallarindan ' + @($fwrules | Where-Object { $_.Enabled -ne 'True' }).Count + ' tanesi kapali -> RDP disaridan reddedilir') 'kritik' }
foreach ($s in @('TermService', 'UmRdpService')) {
    $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($sv) { Add-Line ('- Servis ' + $s + ': ' + $sv.Status + ' | start=' + $sv.StartType) }
}
$listen = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 3389 })
Add-Line ('- 3389 dinleyen adres sayisi: ' + @($listen).Count)

Add-Section '4. Ag durumu ve gecmisi'
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { Add-Line ('- Adaptor: ' + $_.Name + ' | durum=' + $_.Status + ' | hiz=' + $_.LinkSpeed + ' | mac=' + $_.MacAddress) }
Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
    Add-Line ('  - IP yapilandirmasi ' + $_.InterfaceAlias + ': IPv4=' + $(if ($_.IPv4Address) { ($_.IPv4Address.IPAddress -join ',') } else { 'yok' }) + ' | aggecidi=' + $(if ($_.IPv4DefaultGateway) { ($_.IPv4DefaultGateway.NextHop -join ',') } else { 'yok' }))
}
Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | ForEach-Object { Add-Line ('- DNS (' + $_.InterfaceAlias + '): ' + ($_.ServerAddresses -join ', ')) }
$proxy = netsh winhttp show proxy 2>&1 | Out-String
Add-Line ('- WinHTTP proxy: ' + (($proxy -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | '))
$ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
Add-Line ('- Kullanici proxy: enable=' + $ie.ProxyEnable + ' sunucu=' + $ie.ProxyServer + ' pac=' + $(if ($ie.AutoConfigURL) { $ie.AutoConfigURL } else { 'yok' }))
if ($ie.ProxyEnable -eq 1 -or $ie.AutoConfigURL) { Add-Suspect 'Sistem/uygulama proxy tanimli -> CRD sinyal trafigi yonlendirilmis olabilir' 'orta' }
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hostsFile) {
    $hEntries = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    Add-Line ('- hosts dosyasi etkin giris sayisi: ' + $hEntries.Count)
    foreach ($e in $hEntries) { Add-Line ('  - ' + $e) }
    if ($hEntries -match '(?i)google|microsoft|mtalk|remotedesktop') { Add-Suspect 'hosts dosyasinda Google/Microsoft engelleme kaydi var' 'yuksek' }
}
$vpns = @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -ErrorAction SilentlyContinue)
if ($vpns.Count -gt 0) { $vpns | ForEach-Object { Add-Line ('- VPN: ' + $_.Name + ' | sunucu=' + $_.ServerAddress + ' | tur=' + $_.TunnelType) }; Add-Suspect 'VPN yapilandirmasi var; VPN up/down olaylari CRD baglantisini dusurebilir' 'dusuk' }
$tap = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match '(?i)tap|tunnel|vpn|virtual' }
if ($tap) { Add-Suspect ('Sanal/VPN adaptoru var: ' + (($tap | ForEach-Object { $_.Name }) -join ', ')) 'dusuk' }
$wlan = Get-Events -Log 'Microsoft-Windows-WLAN-AutoConfig/Operational' -Max 400
$disconnects = @($wlan | Where-Object { $_.Id -in 8001, 8003, 11004, 11005, 10049 })
Add-Line ('- WLAN olaylari (son ' + $Days + ' gun): ' + @($wlan).Count + ' | disconnect/resort sayisi ~ ' + $disconnects.Count)
if ($disconnects.Count -gt 3) { Add-Suspect ('Wi-Fi ' + $disconnects.Count + ' kez baglantiyi koptu/degistirdi -> CRD oturumu duser') 'yuksek' }
$ndr = Get-Events -Log 'System' -Ids @(27, 32, 10400, 10401, 4201, 4202) -Max 40
if ($ndr.Count -gt 0) { Add-Suspect ('Ag adaptoru/link olayi: ' + $ndr.Count + ' adet') 'orta' }
Event-Lines ($wlan | Where-Object { $_.Id -in 8001, 8003 } | Select-Object -First 15)

Add-Section '5. Guc, uyku ve beklenmeyen kapanmalar'
$standby = Get-AcIndexSeconds -AliasPath @('SUB_SLEEP', 'STANDBYIDLE')
$hibIdle = Get-AcIndexSeconds -AliasPath @('SUB_SLEEP', 'HIBERNATEIDLE')
$hibAfter = Get-AcIndexSeconds -AliasPath @('SUB_SLEEP', 'HIBERNATEAFTER')
$unattend = Get-AcIndexSeconds -AliasPath @('SUB_SLEEP', 'UNATTENDSLEEP')
$monitor = Get-AcIndexSeconds -AliasPath @('SUB_VIDEO', 'VIDEOTIMEOUT')
$diskIdle = Get-AcIndexSeconds -AliasPath @('SUB_DISK', 'DISKIDLE')
Add-Line ('- AC uyku (STANDBYIDLE): ' + $(if ($null -eq $standby) { 'okunamadi' } elseif ($standby -eq 0) { 'KAPALI (asla)' } else { [int]($standby / 60) + ' dk' }))
Add-Line ('- AC sistem disi uyku (UNATTENDSLEEP): ' + $(if ($null -eq $unattend) { 'okunamadi' } elseif ($unattend -eq 0) { 'KAPALI' } else { [int]($unattend / 60) + ' dk (Modern Standby: ekran kapaninca uyur)' }))
Add-Line ('- AC hibernasyon (HIBERNATEIDLE): ' + $(if ($null -eq $hibIdle) { 'okunamadi' } elseif ($hibIdle -eq 0) { 'KAPALI' } else { [int]($hibIdle / 60) + ' dk' }))
Add-Line ('- AC ekran (VIDEOTIMEOUT): ' + $(if ($null -eq $monitor) { 'okunamadi' } else { [int]($monitor / 60) + ' dk' }))
Add-Line ('- AC disk (DISKIDLE): ' + $(if ($null -eq $diskIdle) { 'okunamadi' } else { [int]($diskIdle / 60) + ' dk' }))
$sleepStates = (powercfg /a 2>&1 | Out-String)
Add-Line ('- Desteklenen uyku durumlari: ' + (($sleepStates -split "`r?`n" | Where-Object { $_ -match '(?i)S3|S0|standby|uyku|MoS|Modern' } | Select-Object -First 4) -join ' | '))
if ($null -ne $unattend -and $unattend -gt 0) { Add-Suspect ('UNATTENDSLEEP=' + [int]($unattend / 60) + ' dk -> ekran kapaninca makine uykuya giriyor, uzak erisim duser') 'kritik' }
if ($null -ne $standby -and $standby -gt 0) { Add-Suspect ('STANDBYIDLE=' + [int]($standby / 60) + ' dk -> makine bos kalinca uyuyor') 'yuksek' }
$hibBoot = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
Add-Line ('- Fast Startup (HiberbootEnabled): ' + $hibBoot)
if ($hibBoot -eq 1) { Add-Suspect 'Fast Startup acik -> "kapatip acmak" aslinda hibernasyon; servisler tam restart olmaz, CRD geri gelmeyebilir' 'orta' }
$bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
if ($bat) {
    Add-Line ('- Pil: ' + $bat.Name + ' | durum=' + $bat.BatteryStatus + ' (1=ciktaki) | %=' + $bat.EstimatedChargeRemaining)
    if ($bat.BatteryStatus -eq 1) { Add-Suspect 'Makine pil ile calisiyor (AC bagli degil)' 'yuksek' }
} else { Add-Line '- Pil yok (masaustu)' }
$lastWake = (powercfg /lastwake 2>&1 | Out-String)
Add-Line ('- Son uyandirma: ' + ((($lastWake -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' | '))
$sleep7 = @(Get-Events -Log 'System' -Ids @(42) -Max 500 | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) })
$wake7 = @(Get-Events -Log 'System' -Ids @(107) -Max 500 | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) })
$sleep24 = @($sleep7 | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-1) })
Add-Line ('- Uykuya giriş (ID 42): son 7 gun ' + $sleep7.Count + ' kez, son 24 saat ' + $sleep24.Count + ' kez | uyanma (ID 107): ' + $wake7.Count + ' kez')
$longSleep = 0
$wakeTimes = @($wake7 | Sort-Object TimeCreated)
$sleepTimes = @($sleep7 | Sort-Object TimeCreated)
foreach ($s in $sleepTimes) {
    $w = $wakeTimes | Where-Object { $_.TimeCreated -gt $s.TimeCreated } | Select-Object -First 1
    if ($w) { $h = ($w.TimeCreated - $s.TimeCreated).TotalHours; if ($h -gt $longSleep) { $longSleep = $h } }
}
if ($longSleep -gt 0) { Add-Line ('- En uzun tespit edilen uyku suresi: ~' + [math]::Round($longSleep, 1) + ' saat'); Add-Suspect ('Makine ' + [math]::Round($longSleep, 1) + ' saat uyuyor -> uzak masaustu oturumlari ve CRD baglantisi o sure boyunca oluyor') 'kritik' }
if ($sleep7.Count -ge 2) { Add-Suspect ('7 günde ' + $sleep7.Count + ' kez uykuya giris -> "bir sure sonra baglanti koptu" sikayetinin birincil nedeni olabilir') 'kritik' }
$wifiPower = Get-AcIndexSeconds -AliasPath @('19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a')
Add-Line ('- Kablosuz adaptor guc modu: ' + $(if ($null -eq $wifiPower) { 'okunamadi' } elseif ($wifiPower -eq 0) { '0 = en yuksek performans' } else { [string]$wifiPower + ' (dusuk guc modu aktif olabilir)' }))
if ($null -ne $wifiPower -and $wifiPower -ne 0) { Add-Suspect 'Wi-Fi dusuk guc modunda -> adaptor uykuya girer, baglanti duser' 'orta' }
$kp = Get-Events -Log 'System' -Ids @(41, 6008) -Max 40
$unexpected = @($kp)
if ($unexpected.Count -gt 0) { Add-Suspect ('Beklenmeyen kapanma / elektrik kesintisi: ' + $unexpected.Count + ' adet (ID 41/6008)') 'yuksek' }
Event-Lines (@($kp | Select-Object -First 15))

Add-Section '6. Servis ve oturum olaylari (RDP)'
$scm = Get-Events -Log 'System' -Match 'chromoting|TermService|UmRdpService' -Max 60
Event-Lines $scm
$lsm = Get-Events -Log 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -Ids @(21, 22, 23, 24, 25, 39, 40) -Max 40
Event-Lines $lsm
$rcm = Get-Events -Log 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' -Ids @(1149, 261, 262, 263) -Max 30
Event-Lines $rcm

Add-Section '7. Guvenlik ve ucuncu parti yazilimlar'
$av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
if ($av) { $av | ForEach-Object { Add-Line ('- Antivirus: ' + $_.displayName + ' | durum=' + $_.productState) } }
$cleanupPattern = '(?i)ccleaner|systemcare|advanced systemcare|avast|avg|norton|mcafee|kaspersky|eset|bitdefender|malwarebytes|iobit|rev uninstaller|tuneup|glary|total uninstall|wise|360|kingsoft'
$apps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $cleanupPattern -or $_.Publisher -match 'Google' } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
if ($apps) { $apps | ForEach-Object { Add-Line ('- Yazilim: ' + $_.DisplayName + ' ' + $_.DisplayVersion + ' (' + $_.Publisher + ') kurulum=' + $_.InstallDate) } } else { Add-Line ('- Bilinen temizlik/guvenlik araci bulunamadi (filtre: ' + $cleanupPattern + ')') }
$tp = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)anydesk|teamviewer|rustdesk|sunlogin|todesk|parsec|vnc|zerotier|tailscale' }
if ($tp) { $tp | ForEach-Object { Add-Line ('- Aktif uzak erisim araci: ' + $_.ProcessName + ' PID=' + $_.Id) } }

Add-Section '8. Windows Update / guncelleme gecmisi'
Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 12 |
    ForEach-Object { Add-Line ('- ' + $_.InstalledOn + ' | ' + $_.Description) }
$updLog = Get-Events -Log 'System' -Match 'Windows Update|Service Control Manager' -Max 25
Event-Lines ($updLog | Where-Object { $_.Message -match '(?i)update|guncelle' })

Add-Section '9. Oneriler (supheli siralamasiyla)'
if ($Suspects.Count -eq 0) {
    Add-Line '- Belirgin bir kalip bulunamadi. Bir sonraki adim: host watchdog kurup bir gun boyunca "googleBaglanti" sayacini izlemek.'
} else {
    $order = @{ 'kritik' = 0; 'yuksek' = 1; 'orta' = 2; 'dusuk' = 3 }
    foreach ($s in @($Suspects | Sort-Object { $order[$_.Weight] })) { Add-Line ('- [' + $s.Weight + '] ' + $s.Text) }
}
Add-Line ''
Add-Line ('Toplam supheli: ' + $Suspects.Count)

if (-not $OutFile) { $OutFile = Join-Path $env:USERPROFILE ('Desktop\rd-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.md') }
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -LiteralPath $OutFile -Value ($L -join "`r`n") -Encoding UTF8
Write-Host ('Rapor yazildi: ' + $OutFile)
Write-Host ('Supheli sayisi: ' + $Suspects.Count)
Write-Host 'Bu raporu bana ver; watchdog revizyonunu buna gore yaparim.'
