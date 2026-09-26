' RemoteWatchdogPanel - pencere gorunmeden (hidden) baslatir.
' Zamanlanmis gorev bu dosyayi calistirir; boylece siyah konsol penceresi belirmez.
Option Explicit
Dim shell, fso, here, ps, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then ps = "powershell.exe"
cmd = """" & ps & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\RemoteWatchdogPanel.ps1"" -Background"
shell.Run cmd, 0, False
