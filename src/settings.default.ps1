# GSPro Slow-Mo Replay settings.
# The installer copies this to settings.ps1 in the install folder. Edit that copy;
# reinstalling never overwrites it. Restart the watcher (or the PC) after changes.

# ---- Replay timing ----
$CaptureSeconds   = 2.5     # seconds of real time kept per swing (raise if the takeaway is cut off)
$RetrieveDelayMs  = 300     # wait after the shot is reported before grabbing (raise if the finish is cut off)
$SpeedPercent     = 25      # playback speed: 25 = 4x slower (120 fps cameras -> smooth 30 fps playback)

# ---- Saving ----
$SaveEverySwing   = $true
$SaveDirectory    = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'GSPro Replays'

# ---- Overlay ----
$OverlayWidthPct  = 0.50            # overlay width as a fraction of the GSPro screen width
$OverlayCorner    = 'BottomRight'   # TopLeft, TopRight, TopCenter, BottomLeft, BottomRight, BottomCenter
$OverlayMarginPx  = 30
$ExtraShowSeconds = 1.5             # keep the overlay up this long after playback finishes

# ---- Paths ----
# GSPro Connect writes "Sending Shot" here each time the launch monitor sends a shot.
$ConnectLog       = 'C:\GSProV1\Core\GSPC\ConnectDebug.txt'
$ObsExe           = Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'
