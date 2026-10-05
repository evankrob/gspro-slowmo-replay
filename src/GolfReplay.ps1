# GSPro Slow-Mo Replay watcher.
#
# Runs in the background (started from the Windows Startup folder). While GSPro is
# running it makes sure OBS is up, watches GSPro Connect's log for "Sending Shot",
# and on every shot:
#   1. tells both Replay Sources to grab the last few seconds from the cameras,
#   2. saves each clip to $SaveDirectory (if $SaveEverySwing),
#   3. pops an always-on-top overlay over GSPro (on whatever screen GSPro is on),
#      then hides it again when the slow-motion playback is done.
#
# Settings: settings.ps1 next to this script.   Log: GolfReplay.log next to this script.

param([string]$TestLog)   # testing only: watch this file instead, and don't require GSPro to be running

. (Join-Path $PSScriptRoot 'settings.default.ps1')
$userSettings = Join-Path $PSScriptRoot 'settings.ps1'
if (Test-Path $userSettings) { . $userSettings }
if ($TestLog) { $ConnectLog = $TestLog }

# Names created by install.ps1 - don't change unless you rename them in OBS too.
$ObsProfile    = 'GSPro Replay'
$ObsCollection = 'GSPro Replay'
$OverlayScene  = 'Replay Overlay'
$ReplaySources = @('DTL Replay', 'Face-On Replay')
# OBS hotkeys bound by install.ps1 (F13-F15 don't exist on real keyboards):
$ReplayKey     = 'OBS_KEY_F13'                     # Load Replay on both replay sources
$SaveKeys      = @('OBS_KEY_F14', 'OBS_KEY_F15')   # Save Replay: DTL, Face-On

$LogFile = Join-Path $PSScriptRoot 'GolfReplay.log'
function Log($msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss.fff}  {1}" -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line
    if ((Get-Item $LogFile).Length -gt 2MB) { Move-Item $LogFile "$LogFile.old" -Force }
}

# Single instance
$mutex = New-Object Threading.Mutex($false, 'Global\GSProSlowMoReplayWatcher')
if (-not $mutex.WaitOne(0)) { exit }

. (Join-Path $PSScriptRoot 'ObsWs.ps1')
$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class GRWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    public static IntPtr FindWindowOf(uint pid, string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
            if (sb.ToString().Contains(titlePart)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static RECT MonitorRect(IntPtr h) {
        var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        GetMonitorInfo(MonitorFromWindow(h, 1 /* nearest-or-primary */), ref mi);
        return mi.rcMonitor;
    }
    public static void MakeOverlay(IntPtr h) {
        long style = GetWindowLongPtr(h, -16).ToInt64();
        style &= ~(0x00C00000L | 0x00040000L);            // no caption, no resize frame
        SetWindowLongPtr(h, -16, new IntPtr(style));
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        ex |= 0x00000080L | 0x08000000L;                  // TOOLWINDOW (no taskbar), NOACTIVATE
        ex &= ~0x00040000L;                               // not APPWINDOW
        SetWindowLongPtr(h, -20, new IntPtr(ex));
    }
    // HWND_TOPMOST, SWP_NOACTIVATE|SWP_SHOWWINDOW|SWP_FRAMECHANGED. Topmost only sticks when OBS's
    // "Make projectors always on top" setting is on (install.ps1 enables it); Qt strips it otherwise.
    public static void Show(IntPtr h, int x, int y, int w, int hh) { SetWindowPos(h, new IntPtr(-1), x, y, w, hh, 0x0010 | 0x0040 | 0x0020); }
    // Keep overlay above GSPro: re-raise without moving or activating.
    public static void Raise(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040); }
    public static void Hide(IntPtr h) { ShowWindow(h, 0); }
    public static string Describe(IntPtr h) {
        if (h == IntPtr.Zero || !IsWindow(h)) return "none";
        RECT r; GetWindowRect(h, out r);
        bool top = (GetWindowLongPtr(h, -20).ToInt64() & 0x8L) != 0;
        return string.Format("{0},{1}-{2},{3} topmost={4} visible={5}", r.L, r.T, r.R, r.B, top, IsWindowVisible(h));
    }
}
'@
[void][GRWin]::SetProcessDpiAwarenessContext([IntPtr](-4))  # per-monitor v2 so pixel math is real pixels

$script:ws = $null
$script:overlay = [IntPtr]::Zero
$script:canvas = @(1280, 480)
$script:hideAt = $null
$script:pendingSaveAt = $null
$script:lastShot = [datetime]::MinValue
$script:logPos = -1L
$script:settingsApplied = $false

function Start-ObsIfNeeded {
    if (Get-Process obs64 -ErrorAction SilentlyContinue) { return }
    Log "Starting OBS"
    $obsArgs = "--profile `"$ObsProfile`" --collection `"$ObsCollection`" --minimize-to-tray --disable-shutdown-check --disable-updater"
    Start-Process -FilePath $ObsExe -ArgumentList $obsArgs -WorkingDirectory (Split-Path $ObsExe)
    $script:ws = $null; $script:overlay = [IntPtr]::Zero; $script:settingsApplied = $false
    Start-Sleep 6
}

function Get-Obs {
    if ($script:ws -and $script:ws.State -eq 'Open') { return $script:ws }
    try { $script:ws = Connect-Obs 3000; Log "Connected to OBS websocket" } catch { $script:ws = $null }
    $script:ws
}

function Apply-ReplaySettings($ws) {
    if (-not (Test-Path $SaveDirectory)) { New-Item -ItemType Directory -Force $SaveDirectory | Out-Null }
    foreach ($s in $ReplaySources) {
        Invoke-Obs $ws SetInputSettings @{ inputName = $s; inputSettings = @{
            duration = [int]($CaptureSeconds * 1000); retrieve_delay = $RetrieveDelayMs
            speed_percent = [double]$SpeedPercent; directory = ($SaveDirectory -replace '\\', '/')
            internal_frames = $true; sound_trigger = $false; end_action = 1
            # Keep exactly one replay. With more, Replay Source switches to the oldest kept
            # replay (already finished and paused) once the list is full, so the overlay shows
            # a frozen frame of an earlier swing.
            replays = 1 } } | Out-Null
    }
    $v = Invoke-Obs $ws GetVideoSettings
    $script:canvas = @([int]$v.baseWidth, [int]$v.baseHeight)
    $script:settingsApplied = $true
    Log "Applied replay settings: ${CaptureSeconds}s @ $SpeedPercent%, delay ${RetrieveDelayMs}ms"
}

function Get-Overlay($ws) {
    $obs = Get-Process obs64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $obs) { return [IntPtr]::Zero }
    if ($script:overlay -ne [IntPtr]::Zero -and [GRWin]::IsWindow($script:overlay)) { return $script:overlay }
    $h = [GRWin]::FindWindowOf([uint32]$obs.Id, $OverlayScene)
    if ($h -eq [IntPtr]::Zero) {
        Invoke-Obs $ws OpenSourceProjector @{ sourceName = $OverlayScene; monitorIndex = -1 } | Out-Null
        for ($i = 0; $i -lt 20 -and $h -eq [IntPtr]::Zero; $i++) {
            Start-Sleep -Milliseconds 100
            $h = [GRWin]::FindWindowOf([uint32]$obs.Id, $OverlayScene)
        }
    }
    if ($h -ne [IntPtr]::Zero) { [GRWin]::MakeOverlay($h); [GRWin]::Hide($h); Log "Overlay window ready" }
    $script:overlay = $h
    $h
}

function Show-Overlay($h) {
    $gs = Get-Process GSPro -ErrorAction SilentlyContinue | Select-Object -First 1
    $anchor = if ($gs -and $gs.MainWindowHandle -ne [IntPtr]::Zero) { $gs.MainWindowHandle } else { $h }
    $m = [GRWin]::MonitorRect($anchor)
    $mw = $m.R - $m.L
    $w = [int]($mw * $OverlayWidthPct); $hh = [int]($w * $script:canvas[1] / $script:canvas[0])
    $x = switch -Wildcard ($OverlayCorner) { '*Left' { $m.L + $OverlayMarginPx } '*Right' { $m.R - $w - $OverlayMarginPx } default { $m.L + [int](($mw - $w) / 2) } }
    $y = if ($OverlayCorner -like 'Top*') { $m.T + $OverlayMarginPx } else { $m.B - $hh - $OverlayMarginPx }
    [GRWin]::Show($h, $x, $y, $w, $hh)
    $gr = if ($gs) { [GRWin]::Describe($gs.MainWindowHandle) } else { 'GSPro window not found' }
    Log ("Overlay shown at {0},{1} {2}x{3}; GSPro: {4}; overlay: {5}" -f $x, $y, $w, $hh, $gr, [GRWin]::Describe($h))
}

function Read-NewShots {
    if (-not (Test-Path $ConnectLog)) { $script:logPos = 0; return 0 }
    $fs = [IO.File]::Open($ConnectLog, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $len = $fs.Length
        if ($script:logPos -lt 0) { $script:logPos = $len; return 0 }   # first look: skip old shots
        if ($len -lt $script:logPos) { $script:logPos = 0 }              # new GSPro session, log restarted
        if ($len -eq $script:logPos) { return 0 }
        $fs.Position = $script:logPos
        $buf = New-Object byte[] ($len - $script:logPos)
        $n = $fs.Read($buf, 0, $buf.Length)
        $script:logPos += $n
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        return ([regex]::Matches($text, 'Sending Shot')).Count
    } finally { $fs.Dispose() }
}

function On-Shot($ws) {
    $now = Get-Date
    if (($now - $script:lastShot).TotalSeconds -lt 2) { return }
    $script:lastShot = $now
    Invoke-Obs $ws TriggerHotkeyByKeySequence @{ keyId = $ReplayKey } | Out-Null
    Log "Shot detected -> replay triggered"
    if ($SaveEverySwing) { $script:pendingSaveAt = $now.AddMilliseconds($RetrieveDelayMs + 700) }
    $h = Get-Overlay $ws
    if ($h -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds ($RetrieveDelayMs + 100)   # let the replay load before showing
        Show-Overlay $h
        $script:hideAt = (Get-Date).AddSeconds($CaptureSeconds * 100 / $SpeedPercent + $ExtraShowSeconds)
    }
}

Log "GSPro Slow-Mo Replay watcher started"
while ($true) {
    try {
        $gsRunning = $TestLog -or [bool](Get-Process GSPro, GSPconnect -ErrorAction SilentlyContinue)
        if (-not $gsRunning) {
            if ($script:overlay -ne [IntPtr]::Zero -and [GRWin]::IsWindow($script:overlay)) { [GRWin]::Hide($script:overlay) }
            $script:logPos = -1L
            Start-Sleep -Seconds 3
            continue
        }
        Start-ObsIfNeeded
        $ws = Get-Obs
        if (-not $ws) { Start-Sleep 2; continue }
        if (-not $script:settingsApplied) { Apply-ReplaySettings $ws; [void](Get-Overlay $ws) }

        if ((Read-NewShots) -gt 0) { On-Shot $ws }

        if ($script:pendingSaveAt -and (Get-Date) -ge $script:pendingSaveAt) {
            foreach ($k in $SaveKeys) { Invoke-Obs $ws TriggerHotkeyByKeySequence @{ keyId = $k } | Out-Null }
            $script:pendingSaveAt = $null
            Log "Saved clips"
        }
        if ($script:hideAt -and (Get-Date) -ge $script:hideAt) {
            if ([GRWin]::IsWindow($script:overlay)) { [GRWin]::Hide($script:overlay) }
            $script:hideAt = $null
        } elseif ($script:hideAt -and [GRWin]::IsWindow($script:overlay)) {
            [GRWin]::Raise($script:overlay)
        }
    } catch {
        Log "Error: $($_.Exception.Message)"
        $script:ws = $null
        Start-Sleep 2
    }
    Start-Sleep -Milliseconds 100
}
