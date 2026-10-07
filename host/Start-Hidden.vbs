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

' GUVENLIK: parametreler TIRNAK ICINDE birlestirilir.
' Onceki surum "cmd & "" "" & Arguments(i)" idi -> argumanlar tirnaksiz gidiyordu.
' & | " iceren bir deger komut ENJEKSIYONU yapiyordu (orn. -X & calc.exe).
' Burada her arguman cift tirnakla sarilir ve icteki tirnaklar "" ile kacirilir;
' boylece deger komut olarak yorumlanamaz, tek basina bir arguman olur.
Function QuoteArg(s)
    QuoteArg = Chr(34) & Replace(CStr(s), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

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

cmd = QuoteArg(ps) & " -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(script)
For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & QuoteArg(WScript.Arguments(i))
Next

' 0 = pencere gizli, False = bekleme
shell.Run cmd, 0, False
