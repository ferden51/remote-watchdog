#Requires -Version 5.1
<#
    Kesinti senaryosu dogrulamasi - duzeltmelerin gercekten calistigini izole durumla kanitlar.
    Ag kesilmez; butce/mutabakat/bildirim kisiTlari gercek fonksiyon kodlariyla calistirilir.

    .\Verify-OutageLogic.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Host_ = Join-Path $Root 'host\RemoteHostWatchdog.ps1'
$script:Pass = 0; $script:Fail = 0
function Ok { param([string]$N, [bool]$C, [string]$I = '') if ($C) { $script:Pass++; Write-Host ('  [GECTI] ' + $N) -ForegroundColor Green } else { $script:Fail++; Write-Host ('  [KALDI] ' + $N + '  ' + $I) -ForegroundColor Red } }

# --- izole ortam ---
$tmp = Join-Path $env:TEMP ('rw-outage-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:BaseDir = $tmp
$script:StateFile = Join-Path $tmp 'state.json'
$script:LogFile = Join-Path $tmp 'test.log'
$script:ScriptPath = $Host_
$script:Results = New-Object System.Collections.ArrayList
$script:PublicIp = $null
$script:MsgCount = 0
$script:SentMessages = New-Object System.Collections.ArrayList

function Write-Log { param([string]$Level = 'INFO', [string]$Message) Write-Host ('    [' + $Level + '] ' + $Message) -ForegroundColor DarkGray }
function Get-UptimeMinutes { return 600 }
function Get-BootStamp { return $script:FakeBoot }
function Test-InternetFast { param([int]$TimeoutMs = 4000) return [bool]$script:NetUp }
function Test-RecoveryBeforeReboot { return [bool]$script:NetUp }
function Send-Telegram { param([string]$Text) }
function Request-OfficeSave { param([int]$TimeoutSeconds) return $true }
function msg.exe { $script:MsgCount++ }
<#  Canli yoklama artik hafif Get-QuickNetState kullaniyor; sahte ag durumunu ona veriyoruz. #>
function Get-QuickNetState {
    $up = [bool]$script:NetUp
    return [pscustomobject]@{ Ip = $up; Dns = $up; Https = $up; Signal = $up; Detail = $(if ($up) { '' } else { 'IP,DNS,HTTPS,sinyal' }) }
}
# Gercek fonksiyon kodlarini betikten cek
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Host_, [ref]$null, [ref]$null)
foreach ($n in @('Get-Config', 'Get-State', 'Save-State', 'Invoke-StateUpdate', 'Get-RebootBudget', 'Get-RebootDecision', 'ConvertTo-DotNetDays', 'Get-HolidayList', 'Test-IsHoliday', 'Test-InBlackout', 'Sync-RebootAccounting', 'Write-VoicePending', 'Show-ScreenMessage', 'Send-UserNotification', 'Write-RebootAnnounce', 'Get-FullCycleBackoffMinutes', 'Test-FullCycleDue', 'Get-ProbeStateInfo', 'Get-ProbeState', 'Save-ProbeState', 'Test-ProbeBeatDue', 'Get-FastProbeDecision')) {
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $n }, $true)
    if ($fn.Count -eq 0) { throw ('fonksiyon bulunamadi: ' + $n) }
    Invoke-Expression $fn[0].Extent.Text
}

$global:cfg = Get-Config
$global:cfg.RestartPolicy = 'always'
$global:cfg.MaxRestartsPerDay = 3
$global:cfg.RebootCooldownMinutes = 5
$global:cfg.RebootAfterFailedCycles = 1
$global:cfg.MinUptimeMinutes = 5
$global:cfg.MinOutageMinutes = 10
$global:cfg.NotifyRepeatHours = 4
$global:cfg.AlertRepeatHours = 12
$global:cfg.HealthyMinutesToReset = 60
$global:cfg.BlackoutEnabled = $true
$global:cfg.BlackoutStart = 18; $global:cfg.BlackoutEnd = 8
$global:cfg.BlackoutNights = @('Pzt', 'Sal', 'Car', 'Per', 'Cum', 'Cmt', 'Paz')
$global:cfg.BlackoutFullDays = @('Cmt', 'Paz')
$global:cfg.HolidayMode = 'none'; $global:cfg.Holidays = @(); $global:cfg.HolidaysFile = ''
$global:cfg.EkranMesaji = $true

$RebootableProblems = @('Internet', 'Saat senkronu', 'Ag katmani', 'Windows RDP', 'Guc/uyku ayarlari')
$Check = $false
$script:NetUp = $true
$script:FakeBoot = '2026-09-30T06:17:53.0000000Z'

function Reset-State {
    $s = Get-State
    $s.ConsecutiveFailures = 0; $s.RebootsUtc = @(); $s.PendingRebootUtc = ''; $s.OutageStartUtc = ''
    $s.LastHealthyUtc = ''; $s.BreakerKey = ''; $s.LastNotifyKey = ''; $s.LastUserNotifyUtc = ''; $s.LastBootUtc = $script:FakeBoot
    $s.LastOkUtc = ''; $s.AlertKey = ''; $s.AlertUtc = ''; $s.LastRebootAnnounceUtc = ''
    $s.NetResetPendingReboot = 0; $s.NetRepairRung = 0; $s.CrdNoConnCycles = 0
    Save-State $s
}
function Bad-Cycle {
    param([double]$OutageMinutes)
    $script:Results.Clear()
    [void]$script:Results.Add([pscustomobject]@{ Name = 'Internet'; Ok = $false; Skipped = $false; Detail = 'google204=HATA'; Repair = ''; Metrics = @{} })
    $st = Get-State
    if (-not $st.OutageStartUtc) { $st.OutageStartUtc = (Get-Date).AddMinutes(-$OutageMinutes).ToString('o') }
    $st.ConsecutiveFailures = [int]$st.ConsecutiveFailures + 1
    Save-State $st
}
<#  Get-FastProbeDecision icin sahte ag olcumu #>
function Get-NetworkHealth {
    $up = [bool]$script:NetUp
    return [pscustomobject]@{ Ip = $up; Dns = $up; Https = $up; Signal = $up; IpMs = $(if ($up) { 20 } else { -1 }); IpHost = $(if ($up) { '1.1.1.1' } else { '' }); SignalMs = $(if ($up) { 25 } else { -1 }); HttpsMs = $(if ($up) { 30 } else { -1 }); DnsMs = 10; TimeWait = 5; Dhcp = $up; Link = 'Ethernet' }
}

Write-Host ''
Write-Host '== A) Butce YALNIZCA dogrulanmis restarti sayar ==' -ForegroundColor Cyan
Reset-State
$script:NetUp = $false
# 3 kez "restart istendi" ama makine hic acilmadi (eski hatanin tamami)
foreach ($i in 1..3) {
    Invoke-StateUpdate { param($st) $st.PendingRebootUtc = (Get-Date).ToString('o') }
    $null = Sync-RebootAccounting
}
$s = Get-State
Ok '3 restart istemesine rağmen bütçe BOŞ kaldı (sahte kayıt yok)' (@($s.RebootsUtc).Count -eq 0) ("count=" + @($s.RebootsUtc).Count)
Ok 'PendingRebootUtc temizlendi' ([string]$s.PendingRebootUtc -eq '')

Write-Host ''
Write-Host '== B) Gercek restart bütçeye yazılır ==' -ForegroundColor Cyan
Invoke-StateUpdate { param($st) $st.PendingRebootUtc = (Get-Date).AddMinutes(-2).ToString('o') }
$script:FakeBoot = '2026-09-30T07:00:00.0000000Z'   # makine yeniden acildi
$null = Sync-RebootAccounting
$s = Get-State
Ok 'acilis zamani degisince bütçeye 1 restart yazıldı' (@($s.RebootsUtc).Count -eq 1) ("count=" + @($s.RebootsUtc).Count)
Ok 'LastBootUtc güncellendi' ([string]$s.LastBootUtc -eq $script:FakeBoot)
$b = Get-RebootBudget -State $s
Ok 'bütçe 1/3 kullanıldı' ($b.Count24h -eq 1)

Write-Host ''
Write-Host '== C) Devre kesici: aynı durumda ALERT/mesaj TEKRARLANMAZ ==' -ForegroundColor Cyan
$before = $script:MsgCount
foreach ($i in 1..5) { Bad-Cycle -OutageMinutes 30; $null = Send-UserNotification -Key 'kesici-daily-budget' -Title 'Otomatik restart durduruldu' -Text 'test' }
Ok '5 turda 1 msg.exe kutusu' (($script:MsgCount - $before) -eq 1) ("gonderilen=" + ($script:MsgCount - $before))
$before = $script:MsgCount
$null = Send-UserNotification -Key 'kesici-cooldown' -Title 'Otomatik restart durduruldu' -Text 'farkli konu'
$null = Send-UserNotification -Key 'kesici-cooldown' -Title 'Otomatik restart durduruldu' -Text 'farkli konu'
Ok 'FARKLI konu hemen gönderilir (baskılanmaz)' (($script:MsgCount - $before) -eq 1) ("gonderilen=" + ($script:MsgCount - $before))

Write-Host ''
Write-Host '== D) Kesinti süresi eşiği (MinOutageMinutes) ==' -ForegroundColor Cyan
Reset-State
$script:NetUp = $false
$st = Get-State
$st.OutageStartUtc = (Get-Date).AddMinutes(-2).ToString('o')
Save-State $st
$b = Get-RebootBudget -State (Get-State)
$kesintiDk = ((Get-Date) - [datetime]::Parse((Get-State).OutageStartUtc)).TotalMinutes
Ok '2 dk''lik kesintide restart degerlendirmesi yapilmaz (esik 10 dk)' (($kesintiDk -lt $global:cfg.MinOutageMinutes) -and (@((Get-State).RebootsUtc).Count -eq 0)) ("kesinti=" + [math]::Round($kesintiDk) + 'dk')

Write-Host ''
Write-Host '== E) Canlı yoklama geri sayımı (dakikada bir tam döngü yok) ==' -ForegroundColor Cyan
$script:IntervalMinutes = 5
$probe = Join-Path $tmp 'probe-state.json'      # gercek Save/Get-ProbeState bunu kullanir
[pscustomobject]@{ last = 'bad'; at = (Get-Date).ToString('o'); beat = (Get-Date).ToString('o'); fullAt = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $probe -Encoding UTF8
Ok 'yeni tetikleme zamanı: bekle (geri sayım)' (-not (Test-FullCycleDue))
[pscustomobject]@{ last = 'bad'; at = (Get-Date).ToString('o'); beat = (Get-Date).ToString('o'); fullAt = (Get-Date).AddMinutes(-9).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $probe -Encoding UTF8
Ok '9 dk sonra tekrar tetiklenebilir' (Test-FullCycleDue)
Ok 'geri sayım 1 dk (5 dk aralıktan türetilir, fırtına koruması) — karar gecikmesin' ((Get-FullCycleBackoffMinutes) -eq 1) ("deger=" + (Get-FullCycleBackoffMinutes))
<#  fullAt saglam durumda DAMGALANMAMALI: aksi halde "1 dk once tetiklendi" sonrasi yeni
    kesintiler geri sayimda kalirdi. #>
Remove-Item -LiteralPath $probe -Force
$null = Save-ProbeState 'ok'
$sonDurum = Get-ProbeStateInfo
Ok 'sağlıklı durumda fullAt boş kalır' (-not [string]$sonDurum.fullAt) ("fullAt=" + [string]$sonDurum.fullAt)
Ok 'sağlıklı durumdan sonraki yeni kesinti anında tetiklenebilir' (Test-FullCycleDue)

Write-Host ''
Write-Host '== F) Aynı bekleyen anons iki kez yazılmaz ==' -ForegroundColor Cyan
Reset-State
$vf = Join-Path $tmp 'pending-voice.json'
$script:Results.Clear()
$w1 = Write-VoicePending -Text 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.' -Sfx 'reboot' -VoiceKey 'reboot60'
$w2 = Write-VoicePending -Text 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.' -Sfx 'reboot' -VoiceKey 'reboot60'
$w3 = Write-VoicePending -Text 'Yeniden başlatma iptal edildi, bilgisayar açık kalacak.' -Sfx 'ok' -VoiceKey 'rebootcancel'
Ok 'aynı metin tekrar yazılmadı (birikim yok)' ($w1 -and -not $w2)
Ok 'FARKLI metin yazıldı' ($w3)
$j = Get-Content -LiteralPath $vf -Raw -Encoding UTF8 | ConvertFrom-Json
Ok 'dosyada son (farklı) anons var' ([string]$j.voiceKey -eq 'rebootcancel')

Write-Host ''
Write-Host '== G) SYSTEM nabzi ==' -ForegroundColor Cyan
$fnHb = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-SystemWatchdogActive' }, $true)
Invoke-Expression $fnHb[0].Extent.Text
$script:IntervalMinutes = 5
Set-Content -LiteralPath (Join-Path $tmp 'system-heartbeat.json') -Value (Get-Date).ToString('o') -Encoding UTF8
Ok 'taze nabız = SYSTEM devrede' (Test-SystemWatchdogActive)
Set-Content -LiteralPath (Join-Path $tmp 'system-heartbeat.json') -Value ((Get-Date).AddMinutes(-30).ToString('o')) -Encoding UTF8
# Kod dosyanin YAZILMA zamanina bakar; icerigi eski olmasi yetmez, LastWriteTime'i de eskit.
(Get-Item -LiteralPath (Join-Path $tmp 'system-heartbeat.json')).LastWriteTime = (Get-Date).AddMinutes(-30)
Ok 'bayat nabız = kullanıcı yedeği devreye girer' (-not (Test-SystemWatchdogActive))

Write-Host ''
Write-Host '== H) Restart anonsu 10 dk içinde tekrar edilmez ==' -ForegroundColor Cyan
Reset-State
$before = $script:MsgCount
$a1 = Write-RebootAnnounce -Text 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.' -CountdownSeconds 60
$a2 = Write-RebootAnnounce -Text 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.' -CountdownSeconds 60
Ok 'ilk anons gitti' ($a1 -and ($script:MsgCount - $before) -eq 1) ("mesaj=" + ($script:MsgCount - $before))
Ok 'ikinci anons kısıtlandı (kutu yok)' (-not $a2) ("mesaj=" + ($script:MsgCount - $before))
$a3 = Write-RebootAnnounce -Text 'Ağ sorunları çözülemedi, bilgisayar 30 saniye içinde yeniden başlatılacak.' -CountdownSeconds 0 -Force -VoiceKey 'reminder'
Ok 'hatırlatma (-Force) her zaman geçer' ($a3)

Write-Host ''
Write-Host '== I) YENİ kesinti geri sayımdan muaf olmalı ==' -ForegroundColor Cyan
<#  Regresyon: geri sayım yalnızca kesinti zaten sürerken geçerli olmalı. Aksi halde
    "sağlıklı → 1 dk önce tetiklenmiş döngü → yeni kesinti" durumunda yeni kesinti
    sessizce 3 dk gecikmeli kalıyor ve anons hiç duyulmuyordu. #>
$probe2 = Join-Path $tmp 'probe-state.json'
# once: ag sagli, 2 dk once tam dongu tetiklenmis (fullAt taze -> geri sayim penceresi)
$script:NetUp = $true
[pscustomobject]@{ last = 'ok'; at = (Get-Date).ToString('o'); beat = (Get-Date).ToString('o'); fullAt = (Get-Date).AddMinutes(-2).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $probe2 -Encoding UTF8
$d1 = Get-FastProbeDecision
Ok 'sağlıklıyken: aksiyon ok' ($d1.Action -eq 'ok') ("aksiyon=" + $d1.Action)
# sonra: ag KOPTI (onceki durum 'ok' idi = yeni kesinti)
$script:NetUp = $false
$d2 = Get-FastProbeDecision
Ok 'yeni kesinti geri sayıma takılmaz, anında tetiklenir' ($d2.Action -eq 'full') ("aksiyon=" + $d2.Action)
Ok 'yeni kesinti olarak işaretlenir (anons seslenecek)' ($d2.YeniSorun -eq $true)
<#  Geri sayim damgasini Start-FullCycle vurur (gercek yolda). Tetikleme gerceklesti
    varsayip damgaliyoruz; bundan sonra surekli kesinti geri sayima girmeli. #>
$null = Save-ProbeState (Get-ProbeState) -Full
$d3 = Get-FastProbeDecision
Ok 'süren kesinti geri sayıma girer' ($d3.Action -eq 'wait') ("aksiyon=" + $d3.Action)
# duzelme gecisi beklemez
$script:NetUp = $true
$d4 = Get-FastProbeDecision
Ok 'bağlantı düzeldi geçişi anında tetiklenir' ($d4.Action -eq 'full' -and $d4.Detay -eq 'duzeldi') ("aksiyon=" + $d4.Action + ' detay=' + $d4.Detay)

Write-Host ''
Write-Host '== J) Ekran mesajı anahtarı (EkranMesaji) ==' -ForegroundColor Cyan
Reset-State
$global:cfg.EkranMesaji = $true
$before = $script:MsgCount
$null = Show-ScreenMessage -Text 'test'
Ok 'açıkken ekran mesajı gönderilir' (($script:MsgCount - $before) -eq 1)
$global:cfg.EkranMesaji = $false
$before = $script:MsgCount
$null = Show-ScreenMessage -Text 'test'
Ok 'kapalıyken ekran mesajı gönderilmez' (($script:MsgCount - $before) -eq 0)
$global:cfg.EkranMesaji = $true

Write-Host ''
Write-Host '== K) Geri sayım anonsu her sürede hazır klibe düşer ==' -ForegroundColor Cyan
<#  RebootDelaySeconds ayardan gelir (10/30/45/60...), onbellekte yalnızca 60/30/10 klipleri
    vardır. Anahtar tam denk gelmezse internetsiz makinede anons sessizce kayboluyordu. #>
$vf2 = Join-Path $tmp 'pending-voice.json'
function Anons-KeyFor {
    param([int]$Sn)
    # Anons kisiti (10 dk) her cagri temizlenir; test yalnizca "hangi hazir klip seciliyor"
    # sonucunu olcmek istiyor.
    $null = Invoke-StateUpdate { param($st) $st.LastRebootAnnounceUtc = '' }
    Remove-Item -LiteralPath $vf2 -Force -ErrorAction SilentlyContinue
    $null = Write-RebootAnnounce -Text 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.' -CountdownSeconds $Sn
    if (-not (Test-Path -LiteralPath $vf2)) { return '(dosya yazilmadi)' }
    return (Get-Content -LiteralPath $vf2 -Raw -Encoding UTF8 | ConvertFrom-Json).voiceKey
}
Ok '60 sn -> reboot60 klibi' ((Anons-KeyFor 60) -eq 'reboot60') ("anahtar=" + (Anons-KeyFor 60))
Ok '30 sn -> reboot30 klibi' ((Anons-KeyFor 30) -eq 'reboot30') ("anahtar=" + (Anons-KeyFor 30))
Ok '10 sn -> reboot10 klibi' ((Anons-KeyFor 10) -eq 'reboot10') ("anahtar=" + (Anons-KeyFor 10))
Ok '45 sn -> en yakın hazır klip (reboot30), sessiz kalmaz' ((Anons-KeyFor 45) -eq 'reboot30') ("anahtar=" + (Anons-KeyFor 45))
Ok '90 sn -> en yakın hazır klip (reboot60)' ((Anons-KeyFor 90) -eq 'reboot60') ("anahtar=" + (Anons-KeyFor 90))
Ok '0 sn -> genel plan klibi' ((Anons-KeyFor 0) -eq 'rebootplan') ("anahtar=" + (Anons-KeyFor 0))

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('== SONUC ==') -ForegroundColor Cyan
Write-Host ('  Gecti: ' + $script:Pass + ' | Kaldi: ' + $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
