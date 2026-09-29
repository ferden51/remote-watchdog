' RemoteWatchdogPanel - pencere gorunmeden (hidden) baslatir.
' Zamanlanmis gorev bu dosyayi cagirir; boylece siyah konsol penceresi belirmez.
'
'   wscript Start-Panel.vbs         -> arka planda (tepsi, pencere gizli)
'   wscript Start-Panel.vbs show    -> paneli AC (masaustu / Baslat menusu kisayolu)
'
' "show" argumani kritik: kullanici kisa yola bastiginda panelin gorunur acilmasi gerekir.
' -Background ile baslatilirsa pencere gizli kalir ve kullanici "acmadi" sanir.
Option Explicit
Dim shell, fso, here, ps, cmd, args, i, showMode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then ps = "powershell.exe"

showMode = False
For i = 0 To WScript.Arguments.Count - 1
    If LCase(Trim(WScript.Arguments(i))) = "show" Then showMode = True
Next

If showMode Then
    cmd = """" & ps & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\RemoteWatchdogPanel.ps1"""
Else
    cmd = """" & ps & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\RemoteWatchdogPanel.ps1"" -Background"
End If
shell.Run cmd, 0, False
