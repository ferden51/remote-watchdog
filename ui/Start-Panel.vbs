' RemoteWatchdogPanel - pencere gorunmeden (hidden) baslatir.
' Zamanlanmis gorev bu dosyayi calistirir; boylece siyah konsol penceresi belirmez.
Option Explicit
Dim shell, fso, here, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\RemoteWatchdogPanel.ps1"" -Background"
shell.Run cmd, 0, False
