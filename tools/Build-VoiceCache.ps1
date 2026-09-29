#Requires -Version 5.1
<#
    Build-VoiceCache - ANONS SESLERINI ONCEDEN uretir (internetsiz kadin sesi)

    Neden? edge-tts dogal Turkce KADIN sesi verir ama BULUTTA calisir: internet kesilince
    (uzerine bu arac yazildigi an once) anons susuyordu. Yerel Piper internetsiz ama erkek
    ses ve robotik. Cozum: sabit anons cumleleri internet varken BIR KEZ mp3'e cevrilip
    onbellege alinir; internet gittiginde panel bu dosyalari calar. Ses ayni (kadin),
    motor ayni (edge-tts), yalnizca uretim onceden yapilir.

    Kullanim (internet varken calistirin):
      .\tools\Build-VoiceCache.ps1            onbellegi uret
      .\tools\Build-VoiceCache.ps1 -Status    sadece durum
      .\tools\Build-VoiceCache.ps1 -Play netdown   tek cumleyi dene

    Cikti: %LOCALAPPDATA%\RemoteWatchdog\voice\cache\<anahtar>.mp3
#>
[CmdletBinding()]
param(
    [string]$CacheDir = '',
    [switch]$Status,
    [string]$Play = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $CacheDir) { $CacheDir = Join-Path $env:LOCALAPPDATA 'RemoteWatchdog\voice\cache' }
$Voice = 'tr-TR-EmelNeural'
$Wrap = Join-Path $RepoRoot 'tools\edge_tts_win.py'

. (Join-Path $RepoRoot 'tools\VoiceLines.ps1')

function Get-Py {
    try { return (Get-Command python.exe -ErrorAction Stop).Source } catch { return $null }
}

function Get-Key {
    # Metinden kararli bir dosya adi uret (ayni metin -> ayni dosya)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    return ([BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)
}

function Build-One {
    param([string]$Key, [string]$Text)
    $out = Join-Path $CacheDir ($Key + '.mp3')
    if (Test-Path -LiteralPath $out) {
        try {
            if ((Get-Item -LiteralPath $out -ErrorAction Stop).Length -gt 0) { return @{ Ok = $true; File = $out; Note = 'zaten var' } }
        } catch { }
        # Dosya gorunuyor ama okunamaz/boz: yeniden uret
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
    $py = Get-Py
    if (-not $py) { return @{ Ok = $false; File = $out; Note = 'python yok' } }
    $txt = Join-Path $env:TEMP ('vw-voice-' + $Key + '.txt')
    try {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        [IO.File]::WriteAllText($txt, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Wrap) {
            & $py $Wrap --voice $Voice --file $txt --write-media $out 2>&1 | Out-Null
        } else {
            & $py -m edge_tts --voice $Voice --file $txt --write-media $out 2>&1 | Out-Null
        }
    } catch { return @{ Ok = $false; File = $out; Note = $_.Exception.Message } }
    if ((Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 0)) {
        return @{ Ok = $true; File = $out; Note = 'uretildi' }
    }
    return @{ Ok = $false; File = $out; Note = 'edge-tts ses uretemedi (internet yoksa 403)' }
}

if ($Play) {
    $k = $Play
    if (-not $script:VwVoiceLines.Contains($k)) { Write-Host ('Bilinmeyen anahtar: ' + $k) -ForegroundColor Red; exit 1 }
    $f = Join-Path $CacheDir ($k + '.mp3')
    if (-not (Test-Path -LiteralPath $f)) {
        $r = Build-One -Key $k -Text $script:VwVoiceLines[$k]
        if (-not $r.Ok) { Write-Host ('Uretilemedi: ' + $r.Note) -ForegroundColor Red; exit 1 }
    }
    Add-Type -AssemblyName PresentationCore
    $pl = New-Object System.Windows.Media.MediaPlayer
    $pl.Open([uri]$f); $pl.Play()
    Write-Host ('Caliniyor: ' + $script:VwVoiceLines[$k])
    Start-Sleep -Seconds 5
    $pl.Stop()
    exit 0
}

Write-Host ''
Write-Host ('Anons onbellegi: ' + $CacheDir) -ForegroundColor Cyan
Write-Host ('  motor: ' + $Voice + ' (dogal Turkce KADIN)') -ForegroundColor Cyan
if (-not (Get-Py)) { Write-Host '  python.exe YOK' -ForegroundColor Yellow }

$n = 0; $ok = 0
foreach ($k in $script:VwVoiceLines.Keys) {
    $n++
    $r = Build-One -Key $k -Text $script:VwVoiceLines[$k]
    if ($r.Ok) { $ok++; Write-Host ('  [TAMAM] ' + $k.PadRight(12) + ' ' + $r.Note) -ForegroundColor Green }
    else { Write-Host ('  [HATA ] ' + $k.PadRight(12) + ' ' + $r.Note) -ForegroundColor Red }
}
Write-Host ''
if ($ok -eq $n) { Write-Host ('Sonuc: ' + $ok + '/' + $n + ' anons hazir - panel internetsiz konusabilir.') -ForegroundColor Green }
else { Write-Host ('Sonuc: ' + $ok + '/' + $n + '. Eksik olanlar icin: internet varken tekrar calistirin.') -ForegroundColor Yellow }
Write-Host ''
