#Requires -Version 5.1
<#
    Enable-ConsoleAutoLogon - Watchdog reboot yaptiktan sonra makinenin kendi
    oturumunu acmasi icin otomatik konsol girisini acar. Yalnizca fiziksel erisimi
    olan biri tarafindan, bilerek calistirilmalidir.

    DIKKAT: Parola registry'de duz metin saklanir (LSA secrets sifrelemesi kullanilmaz).
    Bunu sadece evde/ofis gibi guvenli sayilan aglarda kullanin.

    .\Enable-ConsoleAutoLogon.ps1 -User 'ADMN' -Password 'parola'
    .\Enable-ConsoleAutoLogon.ps1 -Disable
#>
[CmdletBinding()]
param(
    [string]$User = $env:USERNAME,
    [string]$Password = '',
    [string]$Domain = '.',
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Winlogon'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($User) { $forward += @('-User', ('"' + $User + '"')) }
    if ($Password) { $forward += @('-Password', ('"' + ($Password -replace '"', '\"') + '"')) }
    if ($Domain) { $forward += @('-Domain', ('"' + $Domain + '"')) }
    if ($Disable) { $forward += '-Disable' }
    Write-Host 'Yonetici yetkisi icin yeniden baslatiliyor...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $forward
    exit 0
}

if ($Disable) {
    Set-ItemProperty -Path $Winlogon -Name 'AutoAdminLogon' -Value '0'
    Remove-ItemProperty -Path $Winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Write-Host 'Otomatik giris kapatildi.'
    exit 0
}

if (-not $Password) { Write-Host 'Parola gerekli. Kullanım: .\Enable-ConsoleAutoLogon.ps1 -User ADMN -Password "..."'; exit 1 }

$domainUser = if ($Domain -eq '.' -or -not $Domain) { '.' + $User } else { ($Domain.TrimEnd('.') + '\' + $User) }

Set-ItemProperty -Path $Winlogon -Name 'AutoAdminLogon' -Value '1'
Set-ItemProperty -Path $Winlogon -Name 'DefaultUserName' -Value $domainUser
Set-ItemProperty -Path $Winlogon -Name 'DefaultDomainName' -Value $Domain
Set-ItemProperty -Path $Winlogon -Name 'DefaultPassword' -Value $Password

Write-Host ('Otomatik konsol girisi aktif: ' + $domainUser)
Write-Host 'Kapatmak icin: .\Enable-ConsoleAutoLogon.ps1 -Disable'
Write-Host 'Not: Google Remote Desktop "headless" modunda otomatik giris olmadan da baglanilabilir; bu ayri olarak kullanilir.'
