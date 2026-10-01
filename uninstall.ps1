<#
.SYNOPSIS
  Stops GSPro Slow-Mo Replay and removes it from Windows startup.
  Your saved clips and your OBS settings are left alone.
#>
param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GSProSlowMoReplay'))

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'GolfReplay\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Write-Host 'Stopped the watcher.'

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'GSPro Slow-Mo Replay.lnk'
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host 'Removed it from Windows startup.' }

Write-Host @"

To finish removing it:
  - Delete the folder $InstallDir (your OBS settings backup is in its 'backup' subfolder).
  - In OBS, switch to another scene collection and profile, then remove 'GSPro Replay'
    under Scene Collection > Remove and Profile > Remove.
  - Optional: Settings > General > Projectors > untick 'Make projectors always on top'.
"@
