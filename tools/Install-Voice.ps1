#Requires -Version 5.1
<#
    Install-Voice - Turkce KONUSMA motorunu (yerel, internet gerektirmeyen) kurar

    Neden? edge-tts'in ucretsiz bulut ucu Microsoft tarafindan kapatildi (HTTP 403), bu yuzden
    dogal Turkce ses uretilemiyor. Windows'ta Turkce SAPI sesi de kurulu degilse panel susuyor.
    Piper TTS + Turkce dogal kadin modeli (DFKI tr_TR) tamamen yerel calisir: internet gerekmez,
    gecikme dusuktur (anons uretimi ~1 sn) ve sesi dogaldir.

    Kurulan yer: %LOCALAPPDATA%\RemoteWatchdog\voice   (depo kirletilmez, ~82 MB)
      voice\piper\piper.exe        + ses motoru kutuphaneleri + espeak-ng-data
      voice\tr_TR-dfki-medium.onnx + .onnx.json         (Turkce kadin modeli)

    Panel otomatik bulur; oncelik sirasi: Piper (yerel) -> edge-tts (bulut) -> Turkce SAPI -> susar.

    Kullanim:
      .\tools\Install-Voice.ps1            motoru indir + kur + kisa ses testi uret
      .\tools\Install-Voice.ps1 -Status    sadece kurulu mu diye bak
      .\tools\Install-Voice.ps1 -Force     yeniden indirip kur
#>
[CmdletBinding()]
param(
    [string]$VoiceDir = '',
    [switch]$Status,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $VoiceDir) { $VoiceDir = Join-Path $env:LOCALAPPDATA 'RemoteWatchdog\voice' }

$PiperZip = 'https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_windows_amd64.zip'
$ModelBase = 'https://huggingface.co/rhasspy/piper-voices/resolve/main/tr/tr_TR/dfki/medium/'
$ModelName = 'tr_TR-dfki-medium.onnx'
$PiperDir = Join-Path $VoiceDir 'piper'
$PiperExe = Join-Path $PiperDir 'piper.exe'
$ModelPath = Join-Path $VoiceDir $ModelName

function Get-VoiceStatus {
    $exe = Test-Path -LiteralPath $PiperExe
    $model = Test-Path -LiteralPath $ModelPath
    $cfg = Test-Path -LiteralPath ($ModelPath + '.json')
    return [pscustomobject]@{ Exe = $exe; Model = $model; Config = $cfg; Ok = ($exe -and $model -and $cfg) }
}

function Show-Status {
    $s = Get-VoiceStatus
    Write-Host ''
    Write-Host ('Konusma motoru: ' + $VoiceDir) -ForegroundColor Cyan
    Write-Host ('  motor (piper.exe) : ' + $(if ($s.Exe) { 'VAR' } else { 'yok' }))
    Write-Host ('  Turkce model      : ' + $(if ($s.Model) { 'VAR (' + [math]::Round((Get-Item -LiteralPath $ModelPath).Length / 1MB, 1) + ' MB)' } else { 'yok' }))
    Write-Host ('  model ayari (.json): ' + $(if ($s.Config) { 'VAR' } else { 'yok' }))
    if ($s.Ok) { Write-Host '  Durum: hazir (Piper = internetsiz yedek motor)' -ForegroundColor Green }
    else { Write-Host '  Durum: kurulu degil -> internetsiz anons uretilemez' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'edge-tts (dogal KADIN Turkce, bulut, ucretsiz):' -ForegroundColor Cyan
    $py = $null
    try { $py = (Get-Command python.exe -ErrorAction Stop).Source } catch { }
    if (-not $py) { Write-Host '  python.exe YOK -> edge-tts kurulamaz' -ForegroundColor Yellow; return $s }
    $hasMod = $false
    try { & $py -c 'import edge_tts' 2>$null; $hasMod = ($LASTEXITCODE -eq 0) } catch { }
    $wrap = Join-Path (Split-Path -Parent $PSCommandPath) 'edge_tts_win.py'
    Write-Host ('  python: ' + $py)
    Write-Host ('  edge_tts modulu: ' + $(if ($hasMod) { 'VAR' } else { 'yok - kurun: python -m pip install --user edge-tts' }))
    Write-Host ('  Windows sarmalayici: ' + $(if (Test-Path -LiteralPath $wrap) { 'VAR (aiodns/Selector duzeltmeli)' } else { 'yok' }))
    if ($hasMod) { Write-Host '  Durum: hazir (birincil motor; internet gerekir)' -ForegroundColor Green }
    return $s
}

if ($Status) { [void](Show-Status); exit 0 }

$st = Show-Status
if ($st.Ok -and -not $Force) { Write-Host 'Zaten kurulu. Yeniden kurmak icin -Force kullanin.' -ForegroundColor DarkGray; exit 0 }

if (-not (Test-Path -LiteralPath $VoiceDir)) { New-Item -ItemType Directory -Force -Path $VoiceDir | Out-Null }
$tmp = Join-Path $env:TEMP ('piper-dl-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    if (-not (Test-Path -LiteralPath $PiperExe) -or $Force) {
        Write-Host ''
        Write-Host '1) Piper motoru indiriliyor (~21 MB)...' -ForegroundColor Cyan
        $zip = Join-Path $tmp 'piper.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $PiperZip -OutFile $zip -UseBasicParsing -TimeoutSec 300
        $ex = Join-Path $tmp 'ex'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        $exeFound = Get-ChildItem -LiteralPath $ex -Recurse -Filter 'piper.exe' | Select-Object -First 1
        if (-not $exeFound) { throw 'piper.exe arsivde bulunamadi' }
        if (Test-Path -LiteralPath $PiperDir) { Remove-Item -LiteralPath $PiperDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $PiperDir | Out-Null
        Copy-Item -Path (Join-Path $exeFound.Directory.FullName '*') -Destination $PiperDir -Recurse -Force
        Write-Host ('   kuruldu: ' + $PiperExe) -ForegroundColor Green
    } else { Write-Host '1) Piper motoru zaten kurulu, atlaniyor' -ForegroundColor DarkGray }

    Write-Host '2) Turkce dogal kadin modeli indiriliyor (~60 MB, birkac dakika surebilir)...' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($f in @($ModelName, ($ModelName + '.json'))) {
        $dest = Join-Path $VoiceDir $f
        if ((Test-Path -LiteralPath $dest) -and -not $Force) { Write-Host ('   -> ' + $f + ' zaten var, atlaniyor') -ForegroundColor DarkGray; continue }
        Write-Host ('   -> ' + $f)
        Invoke-WebRequest -Uri ($ModelBase + $f) -OutFile $dest -UseBasicParsing -TimeoutSec 900
    }
    Write-Host ('   kuruldu: ' + $ModelPath) -ForegroundColor Green
} catch {
    Write-Host ('Kurulum hatasi: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Gecici dosyalar: ' + $tmp -ForegroundColor DarkGray
    exit 1
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$st2 = Show-Status
if (-not $st2.Ok) { exit 1 }

Write-Host ''
Write-Host '3) Kisa ses testi uretiliyor (dogal Turkce kadin sesi)...' -ForegroundColor Cyan
$testWav = Join-Path $env:TEMP 'rw-voice-test.wav'
$txt = Join-Path $env:TEMP 'rw-voice-test.txt'
[System.IO.File]::WriteAllText($txt, 'Uzak makine baglantisi duzeldi.', (New-Object System.Text.UTF8Encoding($false)))
if (Test-Path -LiteralPath $testWav) { Remove-Item -LiteralPath $testWav -Force }
try {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('type "' + $txt + '" | "' + $PiperExe + '" -m "' + $ModelPath + '" -f "' + $testWav + '"')) -WindowStyle Hidden -PassThru -Wait
    if (Test-Path -LiteralPath $testWav) {
        Write-Host ('   test sesi uretildi: ' + [math]::Round((Get-Item -LiteralPath $testWav).Length / 1KB, 1) + ' KB -> ' + $testWav) -ForegroundColor Green
        Write-Host '   Paneli yeniden baslatin; Turkce anonslar artik bu sesle calacak.' -ForegroundColor Green
    } else {
        Write-Host ('   test sesi uretilemedi (cikis kodu: ' + $p.ExitCode + ')') -ForegroundColor Yellow
    }
} catch { Write-Host ('   test calistirilamadi: ' + $_.Exception.Message) -ForegroundColor Yellow }
Remove-Item -LiteralPath $txt -Force -ErrorAction SilentlyContinue
