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
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
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

        ONEMLI: Host kontrolu BITIRDIKTEN SONRA JSON'u yazdig icin JSON'daki taskState
        her zaman "Running" olur. Bu deger ancak veri cok tazeyse (calisma su an suruyor)
        anlamlidir; veri yaslandiginda gorev "hazir" (Ready) durumundadir.
    #>
    param($Status, $VisibleTask)
    $fresh = Test-StatusFresh -Status $Status
    $ageMin = 999
    if ($Status -and ([string]$Status.generated) -ne '') { $ageMin = Get-RwDateMinutesAgo $Status.generated }
    $justRan = ($ageMin -ge 0 -and $ageMin -le 1.5)
    $says = $null
    if ($Status -and $Status.PSObject.Properties.Name -contains 'taskInstalled') { $says = $Status.taskInstalled }
    if ($VisibleTask) {
        $running = ($VisibleTask.State -eq 'Running')
        return [pscustomobject]@{
            Installed = $true; Visible = $true; Running = $running; Fresh = $fresh
            Text = $(if ($running) { 'Zamanlanmış görev: ÇALIŞIYOR' } else { 'Zamanlanmış görev: kurulu, şu an çalışmıyor' })
            Color = $(if ($running) { 'Ok' } else { 'Warn' })
            Short = $(if ($running) { 'Görev: çalışıyor' } else { 'Görev: hazır' })
        }
    }
    if ($says -eq $true -or ($says -eq 'unknown' -and $fresh)) {
        $runNow = $false
        return [pscustomobject]@{
            Installed = $true; Visible = $false; Running = $runNow; Fresh = $fresh
            Text = $(if ($runNow) { 'Zamanlanmış görev: ÇALIŞIYOR (SYSTEM hesabında, bu oturumda görünmüyor)' } else { 'Zamanlanmış görev: kurulu, şu an çalışmıyor (son kontrol ' + [int][math]::Floor($ageMin) + ' dk önce - SYSTEM hesabında)' })
            Color = $(if ($runNow) { 'Ok' } else { 'Warn' })
            Short = $(if ($runNow) { 'Görev: çalışıyor' } else { 'Görev: hazır' })
        }
    }
    return [pscustomobject]@{
        Installed = $false; Visible = $true; Running = $false; Fresh = $fresh
        Text = 'Watchdog: kurulu değil - Install-Host.ps1 ile kurun'
        Color = 'Bad'
        Short = 'Görev: kurulu değil'
    }
}
