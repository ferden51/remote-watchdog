# RemoteWatchdog - Common: iki ve daha fazla betik arasinda paylasilan yardimcilar.
# Dot-source edilir:  . <repo>\lib\Common.ps1
# Bu dosya veri yazmaz; sadece okuma/yazma yardimcilari ve donusumleri icerir.

function Get-RwJson {
    <#  JSON dosyasi okur. Hata olursa null doner (cagiran taraf karar verir). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-RwJson {
    <#  JSON dosyasi yazar. PS 5.1 Turkce karakterleri dogru okusun diye UTF-8 BOM kullanilir. #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Object, [int]$Depth = 6)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Object | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-RwTcpMs {
    <#  TCP baglantisini acar ve sureyi dondurur. Basarisizsa -1. #>
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return -1 }
        $c.EndConnect($iar)
        $sw.Stop()
        return [int]$sw.ElapsedMilliseconds
    } catch { return -1 } finally { try { $c.Close() } catch { } }
}

function Test-RwTcpPort {
    <#  Port acik mi: $true / $false. #>
    param([string]$HostName, [int]$Port = 3389, [int]$TimeoutMs = 3000)
    return ((Get-RwTcpMs -HostName $HostName -Port $Port -TimeoutMs $TimeoutMs) -ge 0)
}

function ConvertTo-RwDayNames {
    <#  Gun listesini 0-6 (0=Pazar, .NET DayOfWeek) veya ad olarak alir, her zaman ad listesine cevirir. #>
    param($Val)
    $map = @{ 0 = 'Paz'; 1 = 'Pzt'; 2 = 'Sal'; 3 = 'Car'; 4 = 'Per'; 5 = 'Cum'; 6 = 'Cmt' }
    $out = @()
    foreach ($v in @($Val)) {
        if ($null -eq $v) { continue }
        $t = ([string]$v).Trim()
        if ($t -eq '') { continue }
        if ($t -match '^\d+$') { $out += $map[[int]$t] } else { $out += $t }
    }
    return @($out)
}

function ConvertTo-RwDayNumbers {
    <#  Gun adlarini/listesini 0-6 .NET sayilarina cevirir. Taninmayan giris yok sayilir. #>
    param($Spec)
    $map = @{
        'paz' = 0; 'pazar' = 0; 'sun' = 0; 'sunday' = 0
        'pzt' = 1; 'pazartesi' = 1; 'mon' = 1; 'monday' = 1
        'sal' = 2; 'sali' = 2; 'tue' = 2; 'tuesday' = 2
        'car' = 3; 'carsamba' = 3; 'wed' = 3; 'wednesday' = 3
        'per' = 4; 'persembe' = 4; 'thu' = 4; 'thursday' = 4
        'cum' = 5; 'cuma' = 5; 'fri' = 5; 'friday' = 5
        'cmt' = 6; 'cumartesi' = 6; 'sat' = 6; 'saturday' = 6
    }
    $out = @()
    foreach ($s in @($Spec)) {
        if ($null -eq $s) { continue }
        $t = ([string]$s).Trim().ToLowerInvariant()
        if ($t -eq '') { continue }
        if ($t -match '^\d+$') { $out += [int]$t; continue }
        if ($map.ContainsKey($t)) { $out += $map[$t]; continue }
        Write-Verbose ("Tanimlanmayan gun yok sayildi: " + $s)
    }
    return @($out | Sort-Object -Unique)
}

function Get-RwDateMinutesAgo {
    <#  Bir tarih damgasinin kac dakika once oldugunu doner (gecmis veya gelecek). #>
    param($Stamp)
    if (-not $Stamp) { return [double]::MaxValue }
    try {
        $t = [datetime]::Parse([string]$Stamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        return ((Get-Date) - $t).TotalMinutes
    } catch { return [double]::MaxValue }
}
