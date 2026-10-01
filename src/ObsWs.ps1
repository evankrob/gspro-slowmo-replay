# Minimal obs-websocket v5 client for Windows PowerShell 5.1.
# Dot-source this file:  . .\ObsWs.ps1

$ErrorActionPreference = 'Stop'

$script:ObsConfigDir = Join-Path $env:APPDATA 'obs-studio'

# OBS 30+ keeps websocket settings in plugin_config\obs-websocket\config.json;
# OBS 28/29 keep them in global.ini under [OBSWebSocket].
function Get-ObsWsConfig {
    $cfg = @{ Port = 4455; Password = $null; Enabled = $false; Source = $null }
    $json = Join-Path $script:ObsConfigDir 'plugin_config\obs-websocket\config.json'
    if (Test-Path $json) {
        $j = Get-Content $json -Raw | ConvertFrom-Json
        $cfg.Enabled = [bool]$j.server_enabled
        if ($j.server_port) { $cfg.Port = [int]$j.server_port }
        if ($j.auth_required) { $cfg.Password = $j.server_password }
        $cfg.Source = $json
        return $cfg
    }
    foreach ($f in @('global.ini', 'user.ini')) {
        $path = Join-Path $script:ObsConfigDir $f
        if (-not (Test-Path $path)) { continue }
        $section = ''
        foreach ($line in Get-Content $path) {
            if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
            if ($section -ne 'OBSWebSocket') { continue }
            if ($line -match '^ServerEnabled=true') { $cfg.Enabled = $true; $cfg.Source = $path }
            if ($line -match '^ServerPort=(\d+)') { $cfg.Port = [int]$Matches[1] }
            if ($line -match '^ServerPassword=(.*)$') { $cfg.Password = $Matches[1] }
            if ($line -match '^AuthRequired=false') { $cfg.Password = $null }
        }
    }
    $cfg
}

function Get-Sha256Base64([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
}

function Receive-ObsMessage($ws, [int]$timeoutMs = 10000) {
    $buf = New-Object byte[] 65536
    $ms = New-Object IO.MemoryStream
    $cts = New-Object Threading.CancellationTokenSource $timeoutMs
    do {
        $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf)
        $r = $ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
        if ($r.MessageType -eq 'Close') { throw "OBS closed the websocket" }
        $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

function Send-ObsRaw($ws, $obj) {
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] -ArgumentList @(, $bytes)
    $ws.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Connect-Obs([int]$timeoutMs = 5000) {
    $cfg = Get-ObsWsConfig
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $cts = New-Object Threading.CancellationTokenSource $timeoutMs
    $ws.ConnectAsync([Uri]"ws://127.0.0.1:$($cfg.Port)", $cts.Token).GetAwaiter().GetResult() | Out-Null
    $hello = Receive-ObsMessage $ws
    $ident = @{ rpcVersion = 1; eventSubscriptions = 0 }
    if ($hello.d.authentication) {
        $secret = Get-Sha256Base64 ($cfg.Password + $hello.d.authentication.salt)
        $ident.authentication = Get-Sha256Base64 ($secret + $hello.d.authentication.challenge)
    }
    Send-ObsRaw $ws @{ op = 1; d = $ident }
    $resp = Receive-ObsMessage $ws
    if ($resp.op -ne 2) { throw "OBS websocket identify failed (wrong password?)" }
    $ws
}

$script:ObsReqId = 0
function Invoke-Obs($ws, [string]$type, $data = @{}, [switch]$NoThrow) {
    $script:ObsReqId++
    $id = "r$script:ObsReqId"
    Send-ObsRaw $ws @{ op = 6; d = @{ requestType = $type; requestId = $id; requestData = $data } }
    while ($ws.State -eq 'Open') {
        $m = Receive-ObsMessage $ws
        if ($m.op -eq 7 -and $m.d.requestId -eq $id) {
            if (-not $m.d.requestStatus.result -and -not $NoThrow) {
                throw "OBS $type failed: $($m.d.requestStatus.code) $($m.d.requestStatus.comment)"
            }
            return $m.d.responseData
        }
    }
    throw "OBS websocket is not open"
}
