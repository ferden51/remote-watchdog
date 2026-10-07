# RemoteWatchdog - Common: iki ve daha fazla betik arasinda paylasilan yardimcilar.
# Dot-source edilir:  . <repo>\lib\Common.ps1
# Bu dosya veri yazmaz; sadece okuma/yazma yardimcilari ve donusumleri icerir.

# =====================================================================
# GIZLI DEGERLER (DPAPI) - v1.4.0
# ---------------------------------------------------------------------
# Neden: Telegram bot token'i config.json'da DUZ METIN saklaniyordu. Dosya ACL'i
# BUILTIN\Users -> ReadAndExecute veriyordu, yani HER yerel kullanici okuyabiliyordu;
# ayrica kurulum betigi token'i komut satirindan geciriyordu (islem listesi + 4688
# olay gunlugu sizintisi).
#
# KAPSAM NEDEN LocalMachine: config.json'u PANEL (kullanici hesabi) yaziyor ama
# SYSTEM'deki watchdog OKUYOR. CurrentUser kapsami kullaniciya ozel oldugu icin
# SYSTEM ayni makinede cozemezdi -> alarm sessizce susardi. LocalMachine kapsami
# makine anahtariyla korur ve her iki hesap da cozer; sifreli metin baska makineye
# tasinsa COZULEMEZ (yedek/ekip paylasimi sizintisi engellenir).
#
# Prefix: "dpapi:" - duz metin degerler ("123:ABC") onceden kayitlidir; okunurken
# prefix yoksa DEGISMEDEN donulur (geriye donuk uyum, ilk calistirmada otomatik
# donusum saglanir).
# =====================================================================

$script:RwSecretPrefix = 'dpapi:'

function Initialize-RwCrypto {
    <#  System.Security assembly'sini yukler (PS 5.1'de otomatik gelmeyebilir). #>
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Protect-RwSecret {
    <#
        Duz metni sifreler (DPAPI LocalMachine). Bos/gecersiz girdi bos doner.
        Cikis: "dpapi:<base64>"
    #>
    param([string]$Plain)
    if ([string]::IsNullOrWhiteSpace($Plain)) { return '' }
    if ($Plain.StartsWith($script:RwSecretPrefix)) { return $Plain }   # zaten sifreli
    try {
        if (-not (Initialize-RwCrypto)) { return $Plain }            # assembly yok: duz metin kalsin (veri kaybi olmasin)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Plain)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return ($script:RwSecretPrefix + [Convert]::ToBase64String($enc))
    } catch { return $Plain }
}

function Unprotect-RwSecret {
    <#
        Sifreli degeri cozer. Duz metin (prefix yok) DEGISMEDEN doner -> eski
        config.json'lar ve elle girilmis degerler bozulmaz.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if (-not $Value.StartsWith($script:RwSecretPrefix)) { return $Value }
    try {
        if (-not (Initialize-RwCrypto)) { return '' }
        $raw = $Value.Substring($script:RwSecretPrefix.Length)
        $bytes = [Convert]::FromBase64String($raw)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Text.Encoding]::UTF8.GetString($dec)
    } catch {
        # Cozulemiyorsa (makine degisti, yedekten geri yuklendi) sessizce yutma:
        # cagiran taraf "kirik" deger olarak bos gormeli, ham sifreli metni ASLA kullanmamali.
        return ''
    }
}

function Test-RwSecretProtected {
    <#  Deger DPAPI ile korunmus mu? #>
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and $Value.StartsWith($script:RwSecretPrefix)
}

function Protect-RwSecretInObject {
    <#
        Bir config nesnesinin (PSCustomObject / [ordered] hashtable) gizli alanlarini
        sifreler. Alan adlari verilir. Alan yoksa dokunmaz.
        Get-Config cikisinda cagrilir: config.json'a DUZ METIN sizmasin.
    #>
    param($Obj, [string[]]$Field = @('TelegramToken', 'TelegramChatId'))
    if (-not $Obj) { return $Obj }
    foreach ($f in $Field) {
        try {
            $has = $false
            if ($Obj -is [System.Collections.IDictionary]) { $has = $Obj.Contains($f) }
            elseif ($Obj.PSObject.Properties.Name -contains $f) { $has = $true }
            if (-not $has) { continue }
            $cur = [string]$Obj.$f
            if ([string]::IsNullOrWhiteSpace($cur)) { continue }
            $Obj.$f = Protect-RwSecret -Plain $cur
        } catch { }
    }
    return $Obj
}

function Unprotect-RwSecretInObject {
    <#
        Ters islem: config.json'dan okunan degeri COZER. Boylece cagiran kod
        ($cfg.TelegramToken) her zaman duz metin gorur, API cagrisi degismez.
    #>
    param($Obj, [string[]]$Field = @('TelegramToken', 'TelegramChatId'))
    if (-not $Obj) { return $Obj }
    foreach ($f in $Field) {
        try {
            $has = $false
            if ($Obj -is [System.Collections.IDictionary]) { $has = $Obj.Contains($f) }
            elseif ($Obj.PSObject.Properties.Name -contains $f) { $has = $true }
            if (-not $has) { continue }
            $cur = [string]$Obj.$f
            if ([string]::IsNullOrWhiteSpace($cur)) { continue }
            $Obj.$f = Unprotect-RwSecret -Value $cur
        } catch { }
    }
    return $Obj
}

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
