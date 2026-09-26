#Requires -Version 5.1
<#
    Protect-OpenDocuments - Kaydedilmemis belge riskine karsi kullanici oturumunda calisir.

    Gorevleri:
      1) Word/Excel AutoRecover araligini kisaltir (varsayilan 10 dk -> 3 dk)
      2) Kaydedilmemis, dosya yolu olan belgeleri periyodik olarak diske kaydeder
      3) Kaydedilemeyenleri (yeni/adli belgeler, salt okunur, paylasimli) raporlar
      4) SYSTEM tarafindan yazilan reboot istegi gelirse kaydedip Word/Excel'i kapatir
      5) Durumu C:\Windows\Temp\RemoteWatchdog-docs.json olarak yazar; reboot kapisi bunu okur

    Elle calistirma:
      .\Protect-OpenDocuments.ps1              tek koruma turu
      .\Protect-OpenDocuments.ps1 -Status      sadece listele
      .\Protect-OpenDocuments.ps1 -Force       istege bakmadan kaydet ve kapat
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Status,
    [int]$AutoRecoverMinutes = 3,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Continue'
$TempDir = $env:windir + '\Temp'
$RequestFile = Join-Path $TempDir 'RemoteWatchdog-reboot.flag'
$ResultFile = Join-Path $TempDir 'RemoteWatchdog-office-result.txt'
$StateFile = Join-Path $TempDir 'RemoteWatchdog-docs.json'
$LogFile = Join-Path $TempDir 'RemoteWatchdog-office.log'
$StartedAt = Get-Date
$script:Saved = @()
$script:Failed = @()

function Write-Log {
    param([string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1}] {2} (kullanici={3})' -f $StartedAt.ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message, $env:USERNAME
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Get-ActiveOfficeApp {
    param([string]$ProgId)
    try {
        $t = [System.Runtime.InteropServices.Marshal]
        $m = $t.GetType().GetMethod('GetActiveObject')
        if (-not $m) { return $null }
        return $m.Invoke($null, @($ProgId))
    } catch { return $null }
}

function Get-WordApp { return (Get-ActiveOfficeApp 'Word.Application') }
function Get-ExcelApp { return (Get-ActiveOfficeApp 'Excel.Application') }

function Get-OfficeSnapshot {
    $snap = [ordered]@{ WordOpen = $false; ExcelOpen = $false; Unsaved = 0; Saved = 0; SavedNow = 0; Failed = @(); Names = @() }
    $w = Get-WordApp
    if ($w) {
        $snap.WordOpen = $true
        try {
            try { $w.Options.SaveInterval = $AutoRecoverMinutes } catch { }
            foreach ($d in @($w.Documents)) {
                $hasPath = $false
                try { $hasPath = ($d.Path -and -not [string]::IsNullOrEmpty([string]$d.Path)) } catch { }
                $ro = $false
                try { $ro = [bool]$d.ReadOnly } catch { }
                $shared = $false
                try { $shared = [bool]$d.Shared } catch { }
                if ($d.Saved) { $snap.Saved++ } else {
                    $snap.Unsaved++
                    if ($hasPath -and -not $ro) {
                        try { $d.Save(); $script:Saved += ('word: ' + $d.Name); $snap.SavedNow++ } catch { $script:Failed += ('word: ' + $d.Name + ' -> ' + $_.Exception.Message); $snap.Failed += ('word: ' + $d.Name) }
                    } else {
                        $why = if (-not $hasPath) { 'yeni/adli belge (Save As gerekir)' } elseif ($ro) { 'salt okunur' } else { 'kaydedilemiyor' }
                        $script:Failed += ('word: ' + $d.Name + ' -> ' + $why)
                        $snap.Failed += ('word: ' + $d.Name + ' (' + $why + ')')
                    }
                    $snap.Names += ('word: ' + $d.Name)
                }
                if ($shared) { $snap.Failed += ('word paylasimli: ' + $d.Name) }
            }
        } catch { }
    }
    $x = Get-ExcelApp
    if ($x) {
        $snap.ExcelOpen = $true
        try {
            try { $x.AutoRecoverInterval = $AutoRecoverMinutes } catch { }
            foreach ($b in @($x.Workbooks)) {
                $hasPath = $false
                try { $hasPath = ($b.Path -and -not [string]::IsNullOrEmpty([string]$b.Path)) } catch { }
                $ro = $false
                try { $ro = [bool]$b.ReadOnly } catch { }
                if ($b.Saved) { $snap.Saved++ } else {
                    $snap.Unsaved++
                    if ($hasPath -and -not $ro) {
                        try { $b.Save(); $script:Saved += ('excel: ' + $b.Name); $snap.SavedNow++ } catch { $script:Failed += ('excel: ' + $b.Name + ' -> ' + $_.Exception.Message); $snap.Failed += ('excel: ' + $b.Name) }
                    } else {
                        $why = if (-not $hasPath) { 'yeni/adli kitap' } elseif ($ro) { 'salt okunur' } else { 'kaydedilemiyor' }
                        $script:Failed += ('excel: ' + $b.Name + ' -> ' + $why)
                        $snap.Failed += ('excel: ' + $b.Name + ' (' + $why + ')')
                    }
                    $snap.Names += ('excel: ' + $b.Name)
                }
            }
        } catch { }
    }
    return [pscustomobject]$snap
}

function Save-StateFile {
    param($Snap)
    try {
        Set-Content -LiteralPath $StateFile -Encoding UTF8 -Value (([pscustomobject]@{
            time = (Get-Date).ToString('o')
            user = $env:USERNAME
            wordOpen = $Snap.WordOpen
            excelOpen = $Snap.ExcelOpen
            unsaved = $Snap.Unsaved
            savedNow = $Snap.SavedNow
            savedTotal = $Snap.Saved
            failed = @($Snap.Failed)
            names = @($Snap.Names)
        }) | ConvertTo-Json -Depth 4)
    } catch { }
}

function Invoke-Protect {
    $snap = Get-OfficeSnapshot
    Save-StateFile $snap
    if ($snap.SavedNow -gt 0) { Write-Log 'INFO' ('kaydedilmemiis ' + $snap.SavedNow + ' belge diske yazildi: ' + ($script:Saved -join ', ')) }
    if ($snap.Unsaved -eq 0) { Write-Log 'INFO' ('Word=' + $(if ($snap.WordOpen) { 'acik' } else { 'kapali' }) + ', Excel=' + $(if ($snap.ExcelOpen) { 'acik' } else { 'kapali' }) + ', kaydedilmemis belge yok') }
    else { Write-Log 'WARN' ('kaydedilmemis belge var (' + $snap.Unsaved + '): ' + ($snap.Names -join ', ') + $(if ($snap.Failed.Count) { ' | sorunlu: ' + (@($snap.Failed) -join '; ') } else { '' })) }
    return 0
}

function Invoke-SaveAndClose {
    $snap = Get-OfficeSnapshot
    $w = Get-WordApp
    $x = Get-ExcelApp
    $out = @()
    if ($w) {
        try { foreach ($d in @($w.Documents)) { if (-not $d.Saved) { $d.Save(); $out += 'word kaydedildi: ' + $d.Name } }; $w.Quit(-1); $out += 'word kapatildi' } catch { $out += 'word HATA: ' + $_.Exception.Message }
    }
    if ($x) {
        try { foreach ($b in @($x.Workbooks)) { if (-not $b.Saved) { $b.Save(); $out += 'excel kaydedildi: ' + $b.Name } }; $x.Quit(-1); $out += 'excel kapatildi' } catch { $out += 'excel HATA: ' + $_.Exception.Message }
    }
    if ($out.Count -eq 0) { $out += 'word/excel acik degil' }
    Save-StateFile $snap
    Set-Content -LiteralPath $ResultFile -Value (($out -join "`r`n") + "`r`n") -Encoding UTF8
    Start-Sleep -Seconds 2
    $after = Get-OfficeSnapshot
    $problem = ($after.WordOpen -or $after.ExcelOpen)
    $text = $out -join ' | '
    if ($after.WordOpen -or $after.ExcelOpen) { $text += ' | UYGULAMA HALA ACIK' }
    Set-Content -LiteralPath $ResultFile -Value ($text + "`r`n") -Encoding UTF8
    Write-Log $(if ($problem) { 'WARN' } else { 'INFO' }) ('sonuc: ' + $text)
    if ($problem) { return 1 }
    return 0
}

if ($Status) {
    $snap = Get-OfficeSnapshot
    Write-Host ('Word: ' + $(if ($snap.WordOpen) { 'acik' } else { 'kapali' }) + ' | Excel: ' + $(if ($snap.ExcelOpen) { 'acik' } else { 'kapali' }))
    Write-Host ('kaydedilmemis: ' + $snap.Unsaved + ' | kayitli: ' + $snap.Saved)
    if ($snap.Names.Count) { Write-Host ('  ' + ($snap.Names -join ', ')) }
    if ($snap.Failed.Count) { Write-Host ('  sorunlu: ' + (@($snap.Failed) -join '; ')) }
    Write-Host ('reboot istegi bekliyor mu: ' + (Test-Path -LiteralPath $RequestFile))
    Write-Host ('durum dosyasi: ' + $StateFile + ' | var: ' + (Test-Path -LiteralPath $StateFile))
    exit 0
}

$hasRequest = Test-Path -LiteralPath $RequestFile
if ($hasRequest -or $Force) {
    $job = Start-Job -ScriptBlock {
        param($req, $res, $st, $arm)
        $ErrorActionPreference = 'Continue'
        function Get-App { param($p) try { $t = [System.Runtime.InteropServices.Marshal]; $m = $t.GetType().GetMethod('GetActiveObject'); if (-not $m) { return $null }; return $m.Invoke($null, @($p)) } catch { return $null } }
        $out = @()
        $w = Get-App 'Word.Application'
        if ($w) {
            try { try { $w.Options.SaveInterval = $arm } catch { }; foreach ($d in @($w.Documents)) { if (-not $d.Saved) { $d.Save(); $out += 'word kaydedildi: ' + $d.Name } }; $w.Quit(-1); $out += 'word kapatildi' } catch { $out += 'word HATA: ' + $_.Exception.Message }
        }
        $x = Get-App 'Excel.Application'
        if ($x) {
            try { try { $x.AutoRecoverInterval = $arm } catch { }; foreach ($b in @($x.Workbooks)) { if (-not $b.Saved) { $b.Save(); $out += 'excel kaydedildi: ' + $b.Name } }; $x.Quit(-1); $out += 'excel kapatildi' } catch { $out += 'excel HATA: ' + $_.Exception.Message }
        }
        if ($out.Count -eq 0) { $out += 'word/excel acik degil' }
        $stillOpen = ((Get-App 'Word.Application') -ne $null) -or ((Get-App 'Excel.Application') -ne $null)
        if ($stillOpen) { $out += 'UYGULAMA HALA ACIK' }
        Set-Content -LiteralPath $res -Value (($out -join "`r`n") + "`r`n") -Encoding UTF8
        Set-Content -LiteralPath $st -Encoding UTF8 -Value (([pscustomobject]@{ time = (Get-Date).ToString('o'); user = $env:USERNAME; wordOpen = $false; excelOpen = $false; unsaved = 0; savedNow = 0; savedTotal = 0; failed = @(); names = @(); note = 'reboot: kaydedildi ve kapatildi' }) | ConvertTo-Json -Depth 4)
    } -ArgumentList $RequestFile, $ResultFile, $StateFile, $AutoRecoverMinutes

    $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $finished) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $ResultFile -Value 'TIMEOUT: Word/Excel kapanmadi (muhtemelen Save As penceresi acik)' -Encoding UTF8
        Write-Log 'ERR' ('zaman asimi ' + $TimeoutSeconds + ' sn: Word/Excel kapanmadi')
        exit 2
    }
    Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $txt = ''
    try { if (Test-Path -LiteralPath $ResultFile) { $txt = (Get-Content -LiteralPath $ResultFile -Raw).Trim() } } catch { }
    Write-Log 'INFO' ('kaydetme/kapatma sonucu: ' + ($txt -replace "`r?`n", ' | '))
    if ($txt -match 'HATA|TIMEOUT|HALA ACIK') { exit 3 }
    exit 0
}

exit (Invoke-Protect)
