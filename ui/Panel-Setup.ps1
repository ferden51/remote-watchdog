# RemoteWatchdog - panel kurulum/kaldirma isleri (oturum acilinda baslatma, gorev, kisayollar).
# Panel betiginden cagrilir; tek basina da calistirilabilir:
#   powershell -File Panel-Setup.ps1 -Action Install
#   powershell -File Panel-Setup.ps1 -Action Uninstall
#   powershell -File Panel-Setup.ps1 -Action Status
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Status')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Continue'
$UiDir = Split-Path -Parent $PSCommandPath
$ScriptPath = Join-Path $UiDir 'RemoteWatchdogPanel.ps1'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'RemoteWatchdogTray'
$TaskName = 'RemoteHostPanel'

function Info { param([string]$Text) Write-Host $Text }
function Warn2 { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }

function Get-ShortcutPaths {
    return @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'RemoteWatchdog Kontrol Paneli.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'RemoteWatchdog Kontrol Paneli.lnk')
    )
}

function New-PanelShortcuts {
    <#
        Baslat menusu + masaustu kisayolu. Hedef wscript + Start-Panel.vbs: konsol penceresi
        acilmaz (Windows Terminal -WindowStyle Hidden'i yok sayiyor), tiklaninca panel acar.
        "show" argumani sart: Start-Panel.vbs argumansiz cagrildiginda -Background ile baslar ve
        pencere gizli kalir; kisa yoldan beklenen davranis panelin gorunur acilmasi.
    #>
    $vbs = Join-Path $UiDir 'Start-Panel.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { return @() }
    $ico = Join-Path $UiDir 'app.ico'
    $made = @()
    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($p in (Get-ShortcutPaths)) {
            try {
                $dir = Split-Path -Parent $p
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                $lnk = $ws.CreateShortcut($p)
                $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
                $lnk.Arguments = '"' + $vbs + '" show'
                $lnk.WorkingDirectory = $UiDir
                if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico + ',0' }
                $lnk.Description = 'RemoteWatchdog kontrol paneli (tepsi simgesi)'
                $lnk.WindowStyle = 7
                $lnk.Save()
                $made += $p
            } catch { Warn2 ('  kisayol olusturulamadi (' + $p + '): ' + $_.Exception.Message) }
        }
    } catch { Warn2 ('  kisayol hatasi: ' + $_.Exception.Message) }
    return $made
}

function Install-Panel {
    $cmd = 'powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    try {
        New-ItemProperty -Path $RunKey -Name $RunName -Value $cmd -PropertyType String -Force | Out-Null
        Info 'Panel oturum acilinda otomatik baslayacak.'
    } catch { Warn2 ('  Run kaydi yazilamadi: ' + $_.Exception.Message) }
    try {
        $vbs = Join-Path $UiDir 'Start-Panel.vbs'
        $pa = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
        $pp = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $ps = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
        $pt1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $pt2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $TaskName -Action $pa -Trigger @($pt1, $pt2) -Principal $pp -Settings $ps -Force -ErrorAction Stop | Out-Null
        Info 'Gorev kuruldu: RemoteHostPanel (oturum acilinda + her 5 dk, pencere gostermeden)'
    } catch { Warn2 ('  Panel gorevi kurulamadi: ' + $_.Exception.Message) }
    $made = @(New-PanelShortcuts)
    if ($made.Count -gt 0) { Info ('Kisayol olusturuldu: ' + ($made -join '  |  ')) } else { Warn2 '  Kisayol olusturulamadi.' }
    Info 'Panelin restart sonrasi da acik gelmesi icin konsolda otomatik giris gerekir: host\Enable-ConsoleAutoLogon.ps1'
}

function Uninstall-Panel {
    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Info 'Gorev kaldirildi: RemoteHostPanel' } catch { }
    }
    foreach ($p in (Get-ShortcutPaths)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Info 'Oturum acilista baslatma ve kisayollar kaldirildi.'
}

function Show-Status {
    $run = (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue).($RunName)
    Info ('Run kaydi      : ' + $(if ($run) { 'VAR' } else { 'YOK' }))
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Info ('Panel gorevi   : ' + $(if ($t) { $t.State } else { 'YOK' }))
    foreach ($p in (Get-ShortcutPaths)) {
        if (Test-Path -LiteralPath $p) {
            try {
                $ws = New-Object -ComObject WScript.Shell
                $l = $ws.CreateShortcut($p)
                Info ('Kisayol        : VAR  -> ' + $p)
                Info ('                 hedef: ' + $l.TargetPath + ' ' + $l.Arguments)
            } catch { Info ('Kisayol        : VAR  -> ' + $p) }
        } else { Info ('Kisayol        : YOK  -> ' + $p) }
    }
}

switch ($Action) {
    'Install' { Install-Panel }
    'Uninstall' { Uninstall-Panel }
    'Status' { Show-Status }
}
