#Requires -Version 5.1
<#
    New-SoundPack - "uzay filmi" tarzi arayuz ses paketini uretir (ui\sounds\*.wav)

    Neden hazir dosya? Panel onemli olaylarda sesli anons yapiyor; ama anons bilgisayarin
    urettigi "konusma" sesi. Onemli EYLEM ve UYARILAR icin filmlerdeki gibi NET, KESKIN ve
    PARLAK bir efekt gerekiyor. Efektler burada sentezlenip WAV olarak depoya konur; panel
    calarken yalnizca calar (uretim maliyeti yok, aninda baslar).

    Ses tasarimi (tools/SfxSynth.cs):
      * Attack < 2 ms + 4 ms parlak transient  -> net, keskin "cis" hissi
      * Inharmonik can kisimlari               -> metalik, uzay istasyonu tini
      * HP'li shimmer reverb                   -> genis, temiz, film kuyrugu
      * Sub katman (55-330 Hz)                 -> guc hissi
      * tanh soft limiter                      -> kirpmasiz, temiz tepe

    Efektler: online, ok, warn, alert, repair, recover, reboot, scan

    Kullanim:
      .\tools\New-SoundPack.ps1            ses paketini yeniden uret (ui\sounds)
      .\tools\New-SoundPack.ps1 -List      paketi ve dosya durumunu listele
      .\tools\New-SoundPack.ps1 -Verify    yalnizca dogrula (uretim yapmaz)
      .\tools\New-SoundPack.ps1 -List -OutDir C:\tmp\ses
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$List,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Source = Join-Path (Split-Path -Parent $PSCommandPath) 'SfxSynth.cs'
if (-not $OutDir) { $OutDir = Join-Path $Root 'ui\sounds' }
if (-not (Test-Path -LiteralPath $Source)) { Write-Host ('Ses motoru bulunamadi: ' + $Source) -ForegroundColor Red; exit 1 }

try { Add-Type -Path $Source -ErrorAction Stop }
catch {
    # Ayni tip ayni oturumda zaten derlendiyse "tip zaten var" hatasi gelir; gercek hata ayirt edilir
    if (-not ('SfxPack' -as [type])) { Write-Host ('Ses motoru derlenemedi: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}

function Read-SfxInfo {
    param([string]$Path)
    $null_ = [pscustomobject]@{ Ok = $false; Info = 'yok'; Seconds = 0; Kb = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $null_ }
    $kb = [math]::Round((Get-Item -LiteralPath $Path).Length / 1KB, 1)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 200) { return [pscustomobject]@{ Ok = $false; Info = 'cok kucuk'; Seconds = 0; Kb = $kb } }
        $riff = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
        $wave = [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4)
        if ($riff -ne 'RIFF' -or $wave -ne 'WAVE') { return [pscustomobject]@{ Ok = $false; Info = 'WAV basligi bozuk'; Seconds = 0; Kb = $kb } }
        $dataBytes = [BitConverter]::ToInt32($bytes, 40)
        return [pscustomobject]@{ Ok = $true; Info = 'tamam'; Seconds = [math]::Round(($dataBytes / 4.0) / 44100.0, 2); Kb = $kb }
    } catch { return [pscustomobject]@{ Ok = $false; Info = $_.Exception.Message; Seconds = 0; Kb = $kb } }
}

$names = @([SfxPack]::Names)

if ($List -or $Verify) {
    Write-Host ''
    Write-Host ('Ses paketi: ' + $OutDir) -ForegroundColor Cyan
    $bad = 0
    $total = 0
    foreach ($n in $names) {
        $t = Read-SfxInfo -Path (Join-Path $OutDir ($n + '.wav'))
        if (-not $t.Ok) { $bad++ }
        $total += $t.Kb
        Write-Host ('  ' + $n.PadRight(9) + ' ' + $t.Info.PadRight(18) + ' ' + ([string]$t.Kb).PadLeft(7) + ' KB  ' + $t.Seconds + ' sn') -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' })
    }
    Write-Host ('  toplam: ' + $total + ' KB') -ForegroundColor DarkGray
    if ($Verify) {
        if ($bad -gt 0) { Write-Host ('Eksik/bozuk efekt: ' + $bad) -ForegroundColor Red; exit 1 }
        Write-Host ('Paket tam: ' + $names.Count + ' efekt') -ForegroundColor Green
    }
    exit 0
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$count = [SfxPack]::BuildAll($OutDir)
$sw.Stop()
Write-Host ''
Write-Host ('Ses paketi uretildi: ' + $OutDir + '  (' + $count + ' efekt, ' + [math]::Round($sw.Elapsed.TotalSeconds, 2) + ' sn)') -ForegroundColor Green
$total = 0
$bad = 0
foreach ($n in $names) {
    $t = Read-SfxInfo -Path (Join-Path $OutDir ($n + '.wav'))
    if (-not $t.Ok) { $bad++ }
    $total += $t.Kb
    Write-Host ('  ' + $n.PadRight(9) + ' ' + ([string]$t.Kb).PadLeft(7) + ' KB  ' + $t.Seconds + ' sn  ' + $t.Info) -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' })
}
Write-Host ('  toplam: ' + $total + ' KB') -ForegroundColor DarkGray
if ($bad -gt 0) { exit 1 }
