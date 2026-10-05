<#
.SYNOPSIS
  Installs GSPro Slow-Mo Replay: builds the OBS scenes, picks the best camera modes,
  and sets the watcher to start with Windows.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GSProSlowMoReplay'),
    [string]$DtlCamera,       # exact camera name for the down-the-line view (skips the prompt)
    [string]$FaceOnCamera,    # exact camera name for the face-on view (skips the prompt)
    [switch]$NoStartup        # don't add to the Startup folder / don't start the watcher
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'src\ObsWs.ps1')

$ProfileName    = 'GSPro Replay'
$CollectionName = 'GSPro Replay'
$SceneName      = 'Replay Overlay'
$CanvasW = 1280; $CanvasH = 480; $TileW = 640; $TileH = 480

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }

function Set-IniValue([string]$path, [string]$section, [string]$key, [string]$value) {
    $lines = [Collections.Generic.List[string]]@()
    if (Test-Path $path) { $lines.AddRange([string[]](Get-Content $path)) }
    $start = $lines.IndexOf("[$section]")
    if ($start -lt 0) { $lines.Add(''); $lines.Add("[$section]"); $lines.Add("$key=$value") }
    else {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\[.+\]$') { $end = $i; break } }
        $found = $false
        for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i] -like "$key=*") { $lines[$i] = "$key=$value"; $found = $true } }
        if (-not $found) { $lines.Insert($start + 1, "$key=$value") }
    }
    [IO.File]::WriteAllLines($path, $lines, (New-Object Text.UTF8Encoding $false))
}

function Get-IniValue([string]$path, [string]$section, [string]$key) {
    if (-not (Test-Path $path)) { return $null }
    $cur = ''
    foreach ($l in Get-Content $path) {
        if ($l -match '^\[(.+)\]$') { $cur = $Matches[1]; continue }
        if ($cur -eq $section -and $l -like "$key=*") { return $l.Substring($key.Length + 1) }
    }
    $null
}

function New-Password { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ }) }

function Wait-Obs([int]$seconds = 60) {
    for ($i = 0; $i -lt $seconds; $i++) {
        try { return (Connect-Obs 2000) } catch { Start-Sleep 1 }
    }
    Fail "Could not connect to OBS's WebSocket server. Is something else using port 4455?"
}

# ---------------------------------------------------------------- checks
Step 'Checking requirements'
$obsExe = Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'
if (-not (Test-Path $obsExe)) { Fail "OBS Studio not found at $obsExe. Install it from https://obsproject.com" }
$obsVer = [version](Get-Item $obsExe).VersionInfo.ProductVersion.Split('-')[0]
Ok "OBS Studio $obsVer"
if ($obsVer.Major -lt 28) { Fail 'OBS 28 or newer is required (it has the WebSocket server built in).' }

$pluginPaths = @(
    (Join-Path $env:ProgramFiles 'obs-studio\obs-plugins\64bit\replay-source.dll'),
    (Join-Path $env:ProgramData 'obs-studio\plugins\replay-source'),
    (Join-Path $env:APPDATA 'obs-studio\plugins\replay-source'))
if (-not ($pluginPaths | Where-Object { Test-Path $_ })) {
    Fail "The Replay Source plugin isn't installed. Get it from https://obsproject.com/forum/resources/replay-source.686/ and run this again."
}
Ok 'Replay Source plugin found'

$obsCfg = Join-Path $env:APPDATA 'obs-studio'
$userIni = Join-Path $obsCfg 'user.ini'; $globalIni = Join-Path $obsCfg 'global.ini'
$appIni = if (Test-Path $userIni) { $userIni } elseif (Test-Path $globalIni) { $globalIni } else { $null }
if (-not $appIni) { Fail 'OBS has never been run on this PC. Open OBS once (skip the auto-configuration wizard), close it, then run this again.' }

$connectLog = 'C:\GSProV1\Core\GSPC\ConnectDebug.txt'
if (Test-Path (Split-Path $connectLog)) { Ok 'GSPro Connect found' }
else { Warn "GSPro Connect folder not found at $(Split-Path $connectLog). If GSPro is installed elsewhere, set `$ConnectLog in settings.ps1 after install." }

if (Get-Process obs64 -ErrorAction SilentlyContinue) {
    Write-Host '    OBS is running. Please close OBS now (File > Exit), then press Enter.' -ForegroundColor Yellow
    while (Get-Process obs64 -ErrorAction SilentlyContinue) { [void](Read-Host) }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'GolfReplay\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# ---------------------------------------------------------------- files
Step "Installing to $InstallDir"
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $here 'src\*') $InstallDir -Force
$settings = Join-Path $InstallDir 'settings.ps1'
if (-not (Test-Path $settings)) { Copy-Item (Join-Path $here 'src\settings.default.ps1') $settings; Ok 'Created settings.ps1' }
else { Ok 'Kept your existing settings.ps1' }

$backup = Join-Path $InstallDir ('backup\obs-config-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $backup | Out-Null
Copy-Item (Join-Path $obsCfg 'basic') $backup -Recurse -ErrorAction SilentlyContinue
Get-ChildItem $obsCfg -Filter *.ini | Copy-Item -Destination $backup
$wsJson = Join-Path $obsCfg 'plugin_config\obs-websocket\config.json'
if (Test-Path $wsJson) { Copy-Item $wsJson $backup }
Ok "Backed up your OBS settings to $backup"

# ---------------------------------------------------------------- OBS app settings
Step 'Configuring OBS'
if ($obsVer.Major -ge 30) {
    $j = if (Test-Path $wsJson) { Get-Content $wsJson -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $j | Add-Member server_enabled $true -Force
    if (-not $j.server_port) { $j | Add-Member server_port 4455 -Force }
    if ($null -eq $j.auth_required) { $j | Add-Member auth_required $true -Force }
    if ($j.auth_required -and -not $j.server_password) { $j | Add-Member server_password (New-Password) -Force }
    $j | Add-Member first_load $false -Force
    New-Item -ItemType Directory -Force (Split-Path $wsJson) | Out-Null
    [IO.File]::WriteAllText($wsJson, ($j | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
} else {
    Set-IniValue $globalIni 'OBSWebSocket' 'ServerEnabled' 'true'
    Set-IniValue $globalIni 'OBSWebSocket' 'FirstLoad' 'false'
    if (-not (Get-IniValue $globalIni 'OBSWebSocket' 'ServerPort')) { Set-IniValue $globalIni 'OBSWebSocket' 'ServerPort' '4455' }
    if ((Get-IniValue $globalIni 'OBSWebSocket' 'AuthRequired') -ne 'false' -and -not (Get-IniValue $globalIni 'OBSWebSocket' 'ServerPassword')) {
        Set-IniValue $globalIni 'OBSWebSocket' 'AuthRequired' 'true'
        Set-IniValue $globalIni 'OBSWebSocket' 'ServerPassword' (New-Password)
    }
}
Ok 'WebSocket server enabled'
# The overlay can only stay above GSPro if OBS itself marks projectors always-on-top.
Set-IniValue $appIni 'BasicWindow' 'ProjectorAlwaysOnTop' 'true'
Ok 'Projectors set to always on top'

# ---------------------------------------------------------------- build scenes
Step 'Starting OBS'
# Launch detached so OBS doesn't close when this console does.
Invoke-CimMethod Win32_Process -MethodName Create -Arguments @{
    CommandLine = "`"$obsExe`" --disable-shutdown-check --disable-updater"; CurrentDirectory = (Split-Path $obsExe) } | Out-Null
$ws = Wait-Obs
Ok 'Connected'

Step 'Creating profile and scene collection'
if ((Invoke-Obs $ws GetProfileList).profiles -contains $ProfileName) { Invoke-Obs $ws SetCurrentProfile @{ profileName = $ProfileName } | Out-Null }
else { Invoke-Obs $ws CreateProfile @{ profileName = $ProfileName } | Out-Null }
Start-Sleep 2
Invoke-Obs $ws SetVideoSettings @{ baseWidth = $CanvasW; baseHeight = $CanvasH; outputWidth = $CanvasW; outputHeight = $CanvasH; fpsNumerator = 60; fpsDenominator = 1 } | Out-Null

if ((Invoke-Obs $ws GetSceneCollectionList).sceneCollections -contains $CollectionName) {
    Invoke-Obs $ws SetCurrentSceneCollection @{ sceneCollectionName = $CollectionName } | Out-Null
} else {
    Invoke-Obs $ws CreateSceneCollection @{ sceneCollectionName = $CollectionName } | Out-Null
}
Start-Sleep 4
$ws = Wait-Obs
# Start clean: remove anything a previous install created.
$inputs = (Invoke-Obs $ws GetInputList).inputs | ForEach-Object { $_.inputName }
foreach ($n in 'DTL Replay', 'Face-On Replay', 'DTL Cam', 'Face-On Cam', '_probe') { if ($inputs -contains $n) { Invoke-Obs $ws RemoveInput @{ inputName = $n } | Out-Null } }
$scenes = (Invoke-Obs $ws GetSceneList).scenes | ForEach-Object { $_.sceneName }
if ($scenes -notcontains $SceneName) {
    if ($scenes -contains 'Scene') { Invoke-Obs $ws SetSceneName @{ sceneName = 'Scene'; newSceneName = $SceneName } | Out-Null }
    else { Invoke-Obs $ws CreateScene @{ sceneName = $SceneName } | Out-Null }
}
Invoke-Obs $ws SetCurrentProgramScene @{ sceneName = $SceneName } | Out-Null
Ok "Scene '$SceneName' ready"

# ---------------------------------------------------------------- cameras
Step 'Finding cameras'
Invoke-Obs $ws CreateInput @{ sceneName = $SceneName; inputName = '_probe'; inputKind = 'dshow_input'; inputSettings = @{}; sceneItemEnabled = $false } | Out-Null
$devices = (Invoke-Obs $ws GetInputPropertiesListPropertyItems @{ inputName = '_probe'; propertyName = 'video_device_id' }).propertyItems |
    Where-Object { $_.itemValue -and $_.itemName -notmatch 'Virtual' }
Invoke-Obs $ws RemoveInput @{ inputName = '_probe' } | Out-Null
if (@($devices).Count -lt 2) { Fail "Found $(@($devices).Count) camera(s); two are needed. Plug both in and run this again." }

function Pick-Camera([string]$label, [string]$preset, $exclude) {
    $choices = @($devices | Where-Object { $_.itemValue -ne $exclude })
    if ($preset) {
        $m = $choices | Where-Object { $_.itemName -eq $preset } | Select-Object -First 1
        if (-not $m) { Fail "No camera named '$preset'. Found: $(($devices | ForEach-Object itemName) -join ', ')" }
        return $m
    }
    if ($choices.Count -eq 1) { return $choices[0] }
    Write-Host "    Which camera is the $label view?"
    for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host "      [$($i + 1)] $($choices[$i].itemName)" }
    do { $a = Read-Host "    Enter 1-$($choices.Count)" } until ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $choices.Count)
    $choices[[int]$a - 1]
}
Write-Host '    (Cameras with the same name are listed in USB order; you can swap them later in OBS.)'
$dtl = Pick-Camera 'DOWN-THE-LINE' $DtlCamera $null
$fo  = Pick-Camera 'FACE-ON' $FaceOnCamera $dtl.itemValue
Ok "Down-the-line: $($dtl.itemName)"
Ok "Face-on:       $($fo.itemName)"

# Pick the highest frame rate the camera offers at up to 1280x720 (ties go to the bigger picture).
function Set-BestMode([string]$name) {
    $res = (Invoke-Obs $ws GetInputPropertiesListPropertyItems @{ inputName = $name; propertyName = 'resolution' }).propertyItems |
        ForEach-Object { $_.itemValue } | Where-Object { $_ -match '^(\d+)x(\d+)$' -and [int]$Matches[2] -le 720 -and [int]$Matches[2] -ge 360 } |
        Sort-Object { $w, $h = $_ -split 'x'; -([int]$w * [int]$h) } -Unique
    $best = $null
    foreach ($r in $res) {
        Invoke-Obs $ws SetInputSettings @{ inputName = $name; inputSettings = @{ res_type = 1; resolution = $r } } | Out-Null
        $iv = (Invoke-Obs $ws GetInputPropertiesListPropertyItems @{ inputName = $name; propertyName = 'frame_interval' }).propertyItems |
            Where-Object { [long]$_.itemValue -gt 0 } | ForEach-Object { [long]$_.itemValue } | Sort-Object | Select-Object -First 1
        if (-not $iv) { continue }
        $fps = [math]::Round(1e7 / $iv)
        if (-not $best -or $fps -gt $best.Fps) { $best = @{ Res = $r; Interval = $iv; Fps = $fps } }
    }
    if (-not $best) { Warn "$name : couldn't read camera modes; using the camera's default"; Invoke-Obs $ws SetInputSettings @{ inputName = $name; inputSettings = @{ res_type = 0 } } | Out-Null; return @(1280, 720) }
    $fmts = (Invoke-Obs $ws GetInputPropertiesListPropertyItems @{ inputName = $name; propertyName = 'video_format' }).propertyItems
    $mjpeg = ($fmts | Where-Object { $_.itemName -eq 'MJPEG' }).itemValue
    Invoke-Obs $ws SetInputSettings @{ inputName = $name; inputSettings = @{ res_type = 1; resolution = $best.Res; frame_interval = $best.Interval; video_format = $(if ($mjpeg) { $mjpeg } else { 0 }) } } | Out-Null
    Ok "$name : $($best.Res) @ $($best.Fps) fps"
    if ($best.Fps -lt 100) { Warn "$name only offers $($best.Fps) fps; slow motion will be less smooth. 120 fps or more is recommended." }
    $best.Res -split 'x' | ForEach-Object { [int]$_ }
}

Step 'Configuring cameras (this tries each mode, so it takes a few seconds)'
$sizes = @{}
foreach ($c in @(@{ Name = 'DTL Cam'; Dev = $dtl }, @{ Name = 'Face-On Cam'; Dev = $fo })) {
    Invoke-Obs $ws CreateInput @{ sceneName = $SceneName; inputName = $c.Name; inputKind = 'dshow_input'; inputSettings = @{ video_device_id = $c.Dev.itemValue } } | Out-Null
    $sizes[$c.Name] = Set-BestMode $c.Name
}

# ---------------------------------------------------------------- replay sources + layout
Step 'Creating slow-motion replay sources'
. (Join-Path $InstallDir 'settings.default.ps1'); . $settings
if (-not (Test-Path $SaveDirectory)) { New-Item -ItemType Directory -Force $SaveDirectory | Out-Null }
foreach ($p in @(@{ Name = 'DTL Replay'; Src = 'DTL Cam'; Tag = 'DTL' }, @{ Name = 'Face-On Replay'; Src = 'Face-On Cam'; Tag = 'Face-On' })) {
    Invoke-Obs $ws CreateInput @{ sceneName = $SceneName; inputName = $p.Name; inputKind = 'replay_source'; inputSettings = @{
        source = $p.Src; source_audio = ''; duration = [int]($CaptureSeconds * 1000); retrieve_delay = $RetrieveDelayMs
        speed_percent = [double]$SpeedPercent; end_action = 1; visibility_action = 3; replays = 1
        internal_frames = $true; sound_trigger = $false; lossless = $false
        directory = ($SaveDirectory -replace '\\', '/'); file_format = "%CCYY-%MM-%DD %hh.%mm.%ss $($p.Tag)" } } | Out-Null
}
$items = (Invoke-Obs $ws GetSceneItemList @{ sceneName = $SceneName }).sceneItems
$x = @{ 'DTL Cam' = 0; 'DTL Replay' = 0; 'Face-On Cam' = $TileW; 'Face-On Replay' = $TileW }
foreach ($it in $items) {
    $cam = $it.sourceName -replace 'Replay$', 'Cam'
    $w, $h = $sizes[$cam]
    $crop = [int][math]::Max(0, ($w - $h * $TileW / $TileH) / 2)   # center-crop to the tile shape
    Invoke-Obs $ws SetSceneItemTransform @{ sceneName = $SceneName; sceneItemId = $it.sceneItemId; sceneItemTransform = @{
        positionX = [double]$x[$it.sourceName]; positionY = 0.0; alignment = 5
        boundsType = 'OBS_BOUNDS_SCALE_INNER'; boundsWidth = [double]$TileW; boundsHeight = [double]$TileH; boundsAlignment = 0
        cropLeft = $crop; cropRight = $crop } } | Out-Null
}
foreach ($n in 'DTL Replay', 'Face-On Replay') {   # replays above the live cameras
    $id = ($items | Where-Object sourceName -eq $n).sceneItemId
    Invoke-Obs $ws SetSceneItemIndex @{ sceneName = $SceneName; sceneItemId = $id; sceneItemIndex = 3 } | Out-Null
}
foreach ($n in 'DTL Replay', 'Face-On Replay') {
    if (-not (Invoke-Obs $ws GetInputSettings @{ inputName = $n }).inputSettings.internal_frames) {
        Warn "Couldn't confirm 'Capture internal frames' is on for $n; tick it in that source's properties in OBS."
    }
}
Ok 'Replay sources and layout ready'

# ---------------------------------------------------------------- hotkeys (needs OBS closed)
Step 'Saving and closing OBS'
$ws.Dispose()
$obs = Get-Process obs64
[void]$obs.CloseMainWindow()
if (-not $obs.WaitForExit(30000)) { Fail "OBS didn't close. Close it yourself (File > Exit) and run this again." }
Ok 'OBS closed'

Step 'Binding replay hotkeys'
# obs-websocket can't target one source's hotkey, so each action gets a key no keyboard has.
$sceneFile = Get-ChildItem (Join-Path $obsCfg 'basic\scenes') -Filter *.json | Where-Object {
    (Get-Content $_.FullName -Raw | ConvertFrom-Json).name -eq $CollectionName } | Select-Object -First 1
if (-not $sceneFile) { Fail "Couldn't find the saved '$CollectionName' scene collection file." }
$d = Get-Content $sceneFile.FullName -Raw | ConvertFrom-Json
$saveKey = @{ 'DTL Replay' = 'OBS_KEY_F14'; 'Face-On Replay' = 'OBS_KEY_F15' }
foreach ($s in $d.sources | Where-Object id -eq 'replay_source') {
    if (-not $s.hotkeys) { $s | Add-Member hotkeys ([pscustomobject]@{}) -Force }
    $s.hotkeys | Add-Member 'ReplaySource.Replay' @(@{ key = 'OBS_KEY_F13' }) -Force
    $s.hotkeys | Add-Member 'ReplaySource.Save' @(@{ key = $saveKey[$s.name] }) -Force
}
[IO.File]::WriteAllText($sceneFile.FullName, ($d | ConvertTo-Json -Depth 100 -Compress), (New-Object Text.UTF8Encoding $false))
Ok 'F13 = replay both angles, F14 / F15 = save DTL / face-on'

# ---------------------------------------------------------------- startup
$watcher = Join-Path $InstallDir 'GolfReplay.ps1'
$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""
if (-not $NoStartup) {
    Step 'Starting with Windows'
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'GSPro Slow-Mo Replay.lnk'
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = $psArgs; $sc.WorkingDirectory = $InstallDir; $sc.WindowStyle = 7
    $sc.Description = 'Slow-motion swing replays for GSPro'; $sc.Save()
    Invoke-CimMethod Win32_Process -MethodName Create -Arguments @{ CommandLine = "powershell.exe $psArgs"; CurrentDirectory = $InstallDir } | Out-Null
    Ok 'Watcher is running and will start automatically at login'
}

Write-Host "`nDone! Open GSPro and hit a shot. The replay appears about a second later." -ForegroundColor Green
Write-Host "  Clips are saved to: $SaveDirectory"
Write-Host "  Settings:           $settings"
Write-Host "  Log:                $(Join-Path $InstallDir 'GolfReplay.log')"
