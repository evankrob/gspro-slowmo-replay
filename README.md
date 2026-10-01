# GSPro Slow-Mo Replay

Automatic slow-motion swing replays for [GSPro](https://gsprogolf.com), using two high-frame-rate USB cameras and [OBS Studio](https://obsproject.com).

Hit a shot. About a second later, a down-the-line and a face-on replay of your swing play at quarter speed in a small overlay on top of GSPro, then disappear. Every swing is also saved as video files you can review later, for example frame by frame in [Kinovea](https://www.kinovea.org).

- **Triggered by the shot itself.** Replays fire when GSPro Connect sends a shot from your launch monitor. Practice swings, speakers and other noise never set it off.
- **Captures your whole swing.** The cameras record nonstop into a short memory buffer, so the clip includes your backswing even though the trigger arrives after impact.
- **Uses the full 120 fps** (or more) from your cameras, not OBS's normal 30–60 fps.
- **Follows GSPro** to whichever screen it's on: projector or PC monitor.
- **Hands-off.** It starts with Windows, launches OBS when GSPro opens, and needs no buttons.

## Requirements

| | |
|---|---|
| **PC** | Windows 10 or 11 |
| **GSPro** | Installed in the default location (`C:\GSProV1`) with **GSPro Connect**. Tested with a Foresight launch monitor; anything that sends shots through GSPro Connect should work. |
| **OBS Studio** | Version 28 or newer, 64-bit. Tested on 29.1. |
| **Replay Source plugin** | By Exeldro: [download here](https://obsproject.com/forum/resources/replay-source.686/). Get the version that matches your OBS version. |
| **Two USB cameras** | 120 fps or faster recommended. These have been used: *RYS HFR USB2.0 Camera* (1280×720 @ 120) and an ELP-style *HD USB Camera* (640×480 @ 120). |

## Setup

### 1. Install OBS and the Replay Source plugin
1. Install [OBS Studio](https://obsproject.com/download).
2. Open OBS once. You can skip the auto-configuration wizard. Then close it (**File → Exit**).
3. Install the [Replay Source plugin](https://obsproject.com/forum/resources/replay-source.686/) using its installer, or copy its files into the OBS folder.

### 2. Mount and connect the cameras
- Plug both cameras into the PC. If possible, use USB ports on different controllers, for example one on the back and one on the front.
- Aim one **down the line** (behind you, looking at the target) and one **face-on** (in front of you, at chest height).
- Light the hitting area well. Many cameras automatically drop their frame rate in dim light (see [Troubleshooting](#troubleshooting)).

### 3. Run the installer
1. Download this repository (**Code → Download ZIP**) and unzip it anywhere.
2. Close OBS.
3. Open PowerShell in the unzipped folder (in File Explorer, Shift + right-click inside the folder and choose **Open PowerShell window here**). Then run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

4. When asked, choose which camera is down-the-line and which is face-on.

The installer then does the following:
- **Backs up your OBS settings first** (to `%LOCALAPPDATA%\GSProSlowMoReplay\backup`).
- Turns on OBS's built-in WebSocket server, which the script uses to control OBS. It creates a password if there isn't one.
- Turns on **Make projectors always on top**, which keeps the overlay above GSPro.
- Creates a separate OBS profile and scene collection, both named **GSPro Replay**. Your existing scenes aren't touched.
- Tests each camera mode and picks the highest frame rate available at up to 720p.
- Sets up the two slow-motion replay sources and the side-by-side layout.
- Binds the replay actions to the unused keys F13–F15.
- Adds the watcher to Windows startup and starts it.

### 4. Hit balls
Open GSPro and hit a shot. That's it.

You don't need to open OBS yourself. If it isn't running when GSPro opens, the watcher starts it, hidden in the system tray. It's fine to leave GSPro and OBS running all day: nothing is saved to disk unless a shot is detected.

## Settings

Edit `%LOCALAPPDATA%\GSProSlowMoReplay\settings.ps1`, then restart the PC. Reinstalling keeps your settings file.

| Setting | Default | What it does |
|---|---|---|
| `$CaptureSeconds` | `2.5` | Seconds of real time kept per swing. Raise it if your takeaway is cut off. |
| `$RetrieveDelayMs` | `300` | Wait after the shot is reported before grabbing the clip. Raise it if your finish is cut off. |
| `$SpeedPercent` | `25` | Playback speed. 25 means 4× slower. |
| `$SaveEverySwing` | `$true` | Save both angles of every swing. |
| `$SaveDirectory` | `Videos\GSPro Replays` | Where clips are saved. |
| `$OverlayWidthPct` | `0.50` | Overlay width as a fraction of the screen. |
| `$OverlayCorner` | `BottomRight` | `TopLeft`, `TopRight`, `TopCenter`, `BottomLeft`, `BottomRight` or `BottomCenter`. |
| `$ConnectLog` | `C:\GSProV1\Core\GSPC\ConnectDebug.txt` | Change this if GSPro is installed somewhere else. |

To adjust cropping (for example to zoom in on the golfer), open OBS, switch to the **GSPro Replay** scene collection, and edit the scene items in **Replay Overlay**. Keep each replay item cropped the same as its live camera item underneath.

## How it works

```
Launch monitor ──► GSPro Connect ──► ConnectDebug.txt: "Sending Shot"
                                              │
                                     GolfReplay.ps1 checks the file 10×/second
                                              │  obs-websocket
                                              ▼
OBS:  cameras ──► Replay Source buffer (last 2.5 s, every frame)
                     F13 → load replay → play at 25% in the "Replay Overlay" projector
                     F14/F15 → save clips
```

- **Detecting shots.** GSPro Connect logs `Sending Shot` the moment it forwards a shot to GSPro. The watcher spots that line within about 0.1 seconds.
- **Capturing frames.** The Replay Source plugin's *Capture internal frames* option grabs every frame the cameras send. Without it, slow motion would be limited to OBS's 60 fps canvas.
- **Triggering replays.** The OBS WebSocket API can't reliably press a hotkey for one specific source. So each action is bound to a key no keyboard has (F13–F15), and the watcher presses those keys through OBS.
- **Showing the overlay.** The overlay is an OBS windowed projector. The watcher removes its border, keeps it out of the taskbar, places it on GSPro's screen, and shows and hides it without taking focus from GSPro.

## Troubleshooting

Start with the log: `%LOCALAPPDATA%\GSProSlowMoReplay\GolfReplay.log`.

| Problem | What to check |
|---|---|
| No `Shot detected` lines in the log | Is GSPro Connect running? Check that `$ConnectLog` points to its `ConnectDebug.txt`. |
| Shots detected, but no overlay appears | In OBS, open **Settings → General → Projectors** and check that **Make projectors always on top** is ticked. The log line for each shot should say `topmost=True`. |
| Choppy slow motion, or saved clips have fewer frames than expected (OBS's log shows `Total frames output`, which should be about 300 for 2.5 s at 120 fps) | The camera is probably cutting its frame rate in low light. Add light, or in OBS open the camera source and choose **Properties → Configure Video**, set exposure to manual, and turn off "low light compensation". |
| Down-the-line and face-on are swapped | Run the installer again and pick the other camera, or swap the devices in each camera source's properties in OBS. |
| Only one angle replays | Run the installer again to rebind the hotkeys, with OBS closed. |
| Overlay covers something you need | Change `$OverlayCorner` or `$OverlayWidthPct`. |

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

This stops the watcher and removes it from startup, then tells you how to remove the OBS scene collection and profile. Your saved clips aren't touched.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with GSPro, Foresight Sports, OBS or the Replay Source plugin.
