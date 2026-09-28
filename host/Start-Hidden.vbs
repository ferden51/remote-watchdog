' RemoteWatchdog - bir PowerShell betigini KONSOL PENCERESI GOSTERMEDEN calistirir.
'
' Neden gerekiyor: Windows Terminal varsayilan terminal oldugunda, zamanlanmis gorevden
' cikan bir konsol penceresi Terminal tarafindan barindirilir ve -WindowStyle Hidden YOK sayilir
' (siyah/mavi ekranlar bir gelip bir gider). WScript.Shell.Run ... 0 ile pencere hic olusmaz.
'
' Kullanim:
'   wscript.exe Start-Hidden.vbs "<betigin tam yolu.ps1>" [parametreler...]
' Ornek:
'   wscript.exe Start-Hidden.vbs "C:\...\host\RemoteHostWatchdog.ps1" -UserFallback
Option Explicit
Dim shell, fso, ps, script, i, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

script = WScript.Arguments(0)
If Not fso.FileExists(script) Then
    WScript.Quit 2
End If

ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then ps = "powershell.exe"

cmd = """" & ps & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """"
For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next

' 0 = pencere gizli, False = bekleme
shell.Run cmd, 0, False
