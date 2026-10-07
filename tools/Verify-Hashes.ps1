#Requires -Version 5.1
<#
    Verify-Hashes - indirilen/calistirilan betiklerin SHA256 DOGRULAMASI.

    NEDEN: README'deki kurulum komutu `irm https://raw.githubusercontent.com/... -OutFile`
    ile TEK SATIR indirme yapiyor ve indirilen betik -ExecutionPolicy Bypass ile
    calistiriliyor. DOGRULAMA YOKTU: ag MITM'i, ele gecirilmis depo erisimi veya
    bozuk indirme sessizce keyfi kod calistirmaya yol acardi.

    KULLANIM:
        .\tools\Verify-Hashes.ps1                 # tum dosyalari manifest'e gore dogrula
        .\tools\Verify-Hashes.ps1 -Update         # manifest'i mevcut dosyalardan uret
        .\tools\Verify-Hashes.ps1 -File 'host\RemoteHostWatchdog.ps1'   # tek dosya

    CI: .github/workflows'a da eklenebilir; bkz. hash-verify.yml notu.
#>
[CmdletBinding()]
param(
    [switch]$Update,
    [string]$File = ''
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ManifestPath = Join-Path $Root 'hashes.sha256.json'

# INDIRME ARACLARI: bu ikisi calistirilabilir kod getirir; en kritik olanlar.
$Tracked = @(
    'host\RemoteHostWatchdog.ps1'
    'client\RemoteClientWatchdog.ps1'
    'host\Protect-OpenDocuments.ps1'
    'host\Collect-Diagnostics.ps1'
    'ui\RemoteWatchdogPanel.ps1'
    'ui\Panel-Setup.ps1'
    'host\Start-Hidden.vbs'
    'lib\Common.ps1'
    'lib\Contract.ps1'
    'lib\Settings.ps1'
)

function Get-FileHashHex {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() }
    catch { return '' }
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }
    try { return (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

if ($Update) {
    $m = [ordered]@{}
    foreach ($t in $Tracked) {
        $p = Join-Path $Root $t
        if (-not (Test-Path -LiteralPath $p)) { Write-Host ('  [!] yok, atlandi: ' + $t) -ForegroundColor Yellow; continue }
        $m[$t] = Get-FileHashHex $p
        Write-Host ('  [OK] ' + $t + '  ' + $m[$t].Substring(0, 16) + '...') -ForegroundColor Green
    }
    [ordered]@{
        algorithm = 'SHA256'
        note      = 'Bu dosyalar indirildikten sonra Verify-Hashes.ps1 ile dogrulanir. Manifesti degistirdiyseniz de guvenli de degildir: kaynak de ayni anda ele gecmis olabilir.'
        files     = $m
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    Write-Host ''
    Write-Host ('Manifest yazildi: ' + $ManifestPath) -ForegroundColor Cyan
    exit 0
}

# --- DOGRULAMA ---
$targets = if ($File) { @($File) } else { $Tracked }
$manifest = Read-Manifest
if (-not $manifest) {
    Write-Host 'HATA: hashes.sha256.json yok. Once -Update ile uretin:' -ForegroundColor Red
    Write-Host '       .\tools\Verify-Hashes.ps1 -Update' -ForegroundColor Red
    exit 2
}

$fail = 0
$missing = 0
$ok = 0
Write-Host ''
Write-Host '=== SHA256 DOGRULAMA ===' -ForegroundColor Cyan
foreach ($t in $targets) {
    $p = Join-Path $Root $t
    $expected = ''
    try { $expected = [string]$manifest.files.$t } catch { }
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ('  [KOPUK] ' + $t + '  (dosya bulunamadi)') -ForegroundColor Red
        $missing++
        continue
    }
    $actual = Get-FileHashHex $p
    if (-not $expected) {
        Write-Host ('  [?] ' + $t + '  (manifestte yok - guvenilemez)') -ForegroundColor Yellow
        $fail++
        continue
    }
    if ($actual -eq $expected) {
        Write-Host ('  [OK] ' + $t) -ForegroundColor Green
        $ok++
    } else {
        Write-Host ('  [BOZUK] ' + $t) -ForegroundColor Red
        Write-Host ('         beklenen: ' + $expected) -ForegroundColor Red
        Write-Host ('         bulunan : ' + $actual) -ForegroundColor Red
        $fail++
    }
}

Write-Host ''
if ($fail -eq 0 -and $missing -eq 0) {
    Write-Host ('DOGRULAMA BASARILI: ' + $ok + ' dosya') -ForegroundColor Green
    exit 0
}
Write-Host ('DOGRULAMA BASARISIZ: bozuk=' + $fail + ' kopuk=' + $missing + ' (toplam ' + $targets.Count + ')') -ForegroundColor Red
Write-Host 'Bu dosyalari CALISTIRMAYIN. Depoyu yeniden indirip tekrar dogrulayin.' -ForegroundColor Red
exit 1