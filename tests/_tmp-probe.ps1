$q = "Name='powershell.exe' OR Name='pwsh.exe'"
Get-CimInstance -ClassName Win32_Process -Filter $q -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'RemoteWatchdogPanel' } |
  Select-Object ProcessId, CreationDate, CommandLine
