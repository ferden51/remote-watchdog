# RemoteWatchdog - Contract: host/client ile panel arasindaki TEK veri sozlesmesi.
# Dot-source edilir:  . <repo>\lib\Contract.ps1
#
# Sozlesme: host ve client "last-run.json" yazar, panel okur. Panelin watchdog'a hicbir
# bagimliligi yoktur. Bu dosya semayi tanimlar, yazimda schemaVersion damgalar ve
# ESKI (schemaVersion'siz, eksik alanli) dosyalari geriye donuk uyumlu sekilde normalize eder.
#
# Surum gecmisi:
#   v1 (schemaVersion yok) : ok = taskInstalled(bool) + taskState + checks[].detail/repair
#   v2 (bu surum)          : + taskVisible, state.RebootsUtc, checks[].metrics, client.targets,
#                            + config.intervalMinutes, + 'unknown' degeri (gorev gorunemiyorsa)

$script:StatusSchemaVersion = 2

function Write-Status {
    <#  last-run.json yazar ve sema surumunu damgalar. -NoSkip verilirse hic yazmaz (testler icin). #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Object, [switch]$NoSkip)
    if ($NoSkip) { return $null }
    try {
        $Object | Add-Member -NotePropertyName 'schemaVersion' -NotePropertyValue $script:StatusSchemaVersion -Force
        $json = $Object | ConvertTo-Json -Depth 6
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        <#
            ATOMIK YAZIM. Neden: dogrudan WriteAllText yarim kalmis dosya birakir ve
            panel tam o anda okudugunda JSON parse hatasi alip NULL doner. Boylece
            "Bekleyen is yok / Her sey yolunda" gibi SAHTE YESIL bir kart gosterilir -
            bir watchdog icin en tehlikeli hata sinifi: olmayan alarm.
            Cozum: once ayni klasorde gecici dosyaya yaz, sonra tek hamleyle yerine
            koy. Okuyan surec ya tam eski ya tam yeni icerigi gorur.
            Dosyali Replace/Move, hedefin ACL/ozelliklerini korur (ProgramData icindeki
            icacls izinleri bozulmaz).
        #>
        $tmp = $Path + '.tmp.' + [guid]::NewGuid().ToString('N')
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
        try {
            if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, $null) }
            else { [System.IO.File]::Move($tmp, $Path) }
        } catch {
            # Replace/Move basarisiz (dosya kilitli vb.) -> eski duz yazma yoluna dus
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
            [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
        }
        return $json
    } catch {
        Write-Verbose ("last-run.json yazilamadi: " + $_.Exception.Message)
        return $null
    }
}

function ConvertTo-StatusObject {
    <#
        Ham JSON nesnesini semaya gore normalize eder.
        - schemaVersion yoksa v1 kabul edilir, eksik alanlar tamamlanir.
        - bilinmeyen (yeni) alanlar oldugu gibi korunur.
    #>
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $o = $Raw
    $ver = 0
    if ($o.PSObject.Properties.Name -contains 'schemaVersion') { $ver = [int]$o.schemaVersion }
    if ($ver -lt 1) { $ver = 1 }

    if (-not ($o.PSObject.Properties.Name -contains 'checks')) { $o | Add-Member -NotePropertyName 'checks' -NotePropertyValue @() -Force }
    if (-not ($o.PSObject.Properties.Name -contains 'taskInstalled')) { $o | Add-Member -NotePropertyName 'taskInstalled' -NotePropertyValue 'unknown' -Force }
    if (-not ($o.PSObject.Properties.Name -contains 'taskVisible')) { $o | Add-Member -NotePropertyName 'taskVisible' -NotePropertyValue $false -Force }
    if (-not ($o.PSObject.Properties.Name -contains 'generated')) { $o | Add-Member -NotePropertyName 'generated' -NotePropertyValue '' -Force }
    if (-not ($o.PSObject.Properties.Name -contains 'config')) { $o | Add-Member -NotePropertyName 'config' -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not ($o.PSObject.Properties.Name -contains 'state')) { $o | Add-Member -NotePropertyName 'state' -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not ($o.PSObject.Properties.Name -contains 'lastRepair')) { $o | Add-Member -NotePropertyName 'lastRepair' -NotePropertyValue $null -Force }
    if (-not ($o.config.PSObject.Properties.Name -contains 'intervalMinutes')) { $o.config | Add-Member -NotePropertyName 'intervalMinutes' -NotePropertyValue 0 -Force }
    if (-not ($o.state.PSObject.Properties.Name -contains 'RebootsUtc')) { $o.state | Add-Member -NotePropertyName 'RebootsUtc' -NotePropertyValue @() -Force }
    if (-not ($o.state.PSObject.Properties.Name -contains 'consecutiveFailures')) { $o.state | Add-Member -NotePropertyName 'consecutiveFailures' -NotePropertyValue 0 -Force }

    $norm = @()
    foreach ($c in @($o.checks)) {
        if ($null -eq $c) { continue }
        if (-not ($c.PSObject.Properties.Name -contains 'metrics')) { $c | Add-Member -NotePropertyName 'metrics' -NotePropertyValue ([pscustomobject]@{}) -Force }
        if (-not ($c.PSObject.Properties.Name -contains 'skipped')) { $c | Add-Member -NotePropertyName 'skipped' -NotePropertyValue $false -Force }
        if (-not ($c.PSObject.Properties.Name -contains 'repair')) { $c | Add-Member -NotePropertyName 'repair' -NotePropertyValue '' -Force }
        $norm += $c
    }
    if ($o.PSObject.Properties.Name -contains 'checks') { $o.checks = $norm }
    $o | Add-Member -NotePropertyName 'schemaVersion' -NotePropertyValue $ver -Force
    return $o
}

function Read-Status {
    <#  last-run.json okur ve normalize eder. Panelin tek giriş noktası. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return (ConvertTo-StatusObject -Raw $raw)
    } catch { return $null }
}

function Test-StatusFresh {
    <#  Veri kac dakika taze; eski sema dosyalari icin de kullanilabilir. #>
    param($Status, [double]$MaxMinutes = 30)
    if ($null -eq $Status) { return $false }
    $m = Get-RwDateMinutesAgo $Status.generated
    return ($m -ge 0 -and $m -le $MaxMinutes)
}

function Get-StatusTaskState {
    <#
        Zamanlanmis gorevin durumunu tek yerde hesaplar.
        Normal kullanici SYSTEM'e ait gorevi GOREMEYEBILIR; bu durumda JSON'daki
        taskInstalled + veri yasi kullanilir.

        ONEMLI - "calisiyor" NASIL ANLASILIR:
        Watchdog gorevi PERIYODIK bir gorevdir (her 5 dk'da bir tetiklenir, dongu ~10 sn
        surer). Boyle bir gorev calistigi aralikta State = 'Ready' olur; 'Running' yalnizca
        o ~10 sn'lik pencerede gorunur. Bu yuzden ONCEDEN "State -ne Running" kontrolu
        kullanilip surekli "kurulu, su an calismiyor" (Warn) gosteriliyordu - bu bir ALARM
        DEGIL, normal durumdu; kullaniciyi yaniltiyordu.
        Dogru kural: veri yeterince tazeyse gorev KENDI ISINI YAPIYOR demektir. Esik,
        dongu araliginin ~2 kati (en az 3 dk) olur; bu surede veri gelmezse gorev gercekten
        takilmis demektir (Disabled / silinmis / cok uzun sürmüş / cok sık hata).
        Görünür görevde ayrica 'Disabled' acikca hata sayilir.
    #>
    param($Status, $VisibleTask)
    $fresh = Test-StatusFresh -Status $Status
    $ageMin = 999
    $age = $null
    if ($Status -and ([string]$Status.generated) -ne '') {
        $ageMin = Get-RwDateMinutesAgo $Status.generated
        if ($ageMin -ge 0) { $age = (New-TimeSpan -Minutes $ageMin) }
    }
    # Beklenen dongu araligi (dk) -> "calisiyor" esigi.
    # intervalMinutes yalnizca gorev GORUNURKEN yazilir; yonetici olmayan panelde 0 gelir.
    # 0'da "3 dk" demek yanlis olur (sistem 5 dk'da bir calisir) -> guvenli varsayilan 10 dk.
    $esik = 10
    if ($Status -and $Status.config -and $Status.config.intervalMinutes) {
        try { $esik = [math]::Max(3, [math]::Round([double]$Status.config.intervalMinutes * 2)) } catch { }
    }
    $working = ($ageMin -ge 0 -and $ageMin -le $esik)
    $disabled = $false
    $says = $null
    if ($Status -and $Status.PSObject.Properties.Name -contains 'taskInstalled') { $says = $Status.taskInstalled }
    if ($VisibleTask) {
        $disabled = ([string]$VisibleTask.State -eq 'Disabled')
        $running = ($working -and -not $disabled)
        return [pscustomobject]@{
            Installed = $true; Visible = $true; Running = $running; Fresh = $fresh
            Disabled = $disabled; Age = $age; AgeMinutes = $ageMin
            Text = $(if ($disabled) { 'Zamanlanmış görev: DEVRE DIŞI (kapalı)' } elseif ($running) { 'Zamanlanmış görev: ÇALIŞIYOR (son kontrol ' + [int][math]::Floor($ageMin) + ' dk önce)' } else { 'Zamanlanmış görev: kurulu ama son kontrol ' + [int][math]::Floor($ageMin) + ' dk önce - takılmış olabilir' })
            Color = $(if ($running) { 'Ok' } elseif ($disabled) { 'Bad' } else { 'Warn' })
            Short = $(if ($running) { 'Görev: çalışıyor' } else { 'Görev: takılmış?' })
        }
    }
    if ($says -eq $true -or ($says -eq 'unknown' -and $fresh)) {
        $runNow = $working
        return [pscustomobject]@{
            Installed = $true; Visible = $false; Running = $runNow; Fresh = $fresh
            Disabled = $false; Age = $age; AgeMinutes = $ageMin
            Text = $(if ($runNow) { 'Zamanlanmış görev: ÇALIŞIYOR (SYSTEM hesabında, son kontrol ' + [int][math]::Floor($ageMin) + ' dk önce)' } else { 'Zamanlanmış görev: kurulu, SYSTEM hesabında - takılmış olabilir (son kontrol ' + [int][math]::Floor($ageMin) + ' dk önce)' })
            Color = $(if ($runNow) { 'Ok' } else { 'Warn' })
            Short = $(if ($runNow) { 'Görev: çalışıyor' } else { 'Görev: takılmış?' })
        }
    }
    <#  Görev YOK: Visible de false'tur. Daha once burada true donuyordu; alan anlam
        celiskisi tasiyordu ve ileride yalnizca .Visible'a bakan bir tuketici (gorunur
        olmadiği icin aslinda gorunmeyen) tumu hatali karar verirdi. #>
    return [pscustomobject]@{
        Installed = $false; Visible = $false; Running = $false; Fresh = $fresh
        Disabled = $false; Age = $age; AgeMinutes = $ageMin
        Text = 'Watchdog: kurulu değil - Install-Host.ps1 ile kurun'
        Color = 'Bad'
        Short = 'Görev: kurulu değil'
    }
}
