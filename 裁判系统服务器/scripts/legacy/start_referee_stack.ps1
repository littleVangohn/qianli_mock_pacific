# DEPRECATED: 旧的“手动逐个起服务”脚本，保留作对照。
# 现在请用根目录的 start_local_sim.bat / scripts\start_local_sim.ps1。
# 它按“停 ICS → 起引擎（引擎自己拉起服务）→ 再开热点”的顺序启动。
#
# Starts the RoboMaster referee stack in dependency order, and keeps the robot
# wifi port (UDP 62101/62102) out of ICS's hands.
#
# Why this script exists
# ----------------------
# The Windows mobile hotspot (ICS) reserves a contiguous block of dynamic ports
# every time it starts, and re-rolls that block on each start or reboot.  When the
# block happens to cover 62101/62102, `AdapterSvrS0` fails to bind them *silently*:
# the process stays up, TCP 15861/15862 look healthy, and the engine simply never
# sees the robot.  The official client and the log viewer then both read as offline
# even though the robot is connected to the hotspot and transmitting.
#
# The fix is a persistent admin port exclusion over the block ICS was taking.  An
# excluded range is off-limits to the system's automatic assignment, but an
# application can still bind it explicitly - so `AdapterSvrS0` gets 62101 while ICS
# picks somewhere else.  `store=persistent` carries it across reboots.
#
# Run with an elevated PowerShell.

$ErrorActionPreference = 'Continue'

$engineRoot = 'D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine 12.0.0.176_Student'
$bridgeRoot = 'D:\Pacific_doorlock\接入真实图传的自定义ui'
$python = 'C:\Users\ty\AppData\Local\Programs\Python\Python313\python.exe'
$rmServer = Join-Path $engineRoot 'RoboMasterEngine_Data\StreamingAssets\RMServer'

$exclusionStart = 62000
$exclusionCount = 301
$robotPorts = 62101, 62102

function Test-PortFree([int]$port) {
    try {
        $client = New-Object System.Net.Sockets.UdpClient
        $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $port)))
        $client.Close()
        return $true
    }
    catch { return $false }
}

function Start-Detached([string]$exe, [string]$workingDirectory, [string]$arguments = '') {
    # Start-Process, not Win32_Process.Create.  On this machine the WMI call starts
    # RMServer / AdapterSvrS0 and they exit immediately (processes created that way
    # are not attached to the interactive desktop), so every Wait-For below times
    # out and none of the four components survive - while the failures are hidden
    # by Out-Null, making it look like a port conflict.  Start-Process works.
    if ($arguments) {
        $proc = Start-Process -FilePath $exe -WorkingDirectory $workingDirectory -ArgumentList $arguments -PassThru
        return $proc.Id
    }
    $proc = Start-Process -FilePath $exe -WorkingDirectory $workingDirectory -PassThru
    return $proc.Id
}

function Wait-For([scriptblock]$condition, [string]$what, [int]$timeoutSeconds = 40) {
    for ($i = 0; $i -lt $timeoutSeconds; $i++) {
        if (& $condition) { return $true }
        Start-Sleep -Seconds 1
    }
    Write-Output "  TIMEOUT waiting for $what"
    return $false
}

# ------------------------------------------------- 1. free the robot ports
# ICS (the mobile hotspot service) grabs a block of dynamic UDP ports on every
# start, and it CAN take 62101/62102 - the ports the robot transmits to.  While
# ICS holds them, AdapterSvrS0 cannot bind them and the robot link stays dead:
# the process is up, TCP looks healthy, and the engine simply never sees a robot.
#
# Two things were tried before and both are wrong here:
#   - `netsh add excludedportrange` does NOT help.  An excluded range blocks
#     explicit binds too (WSAEACCES / WinError 10013), so it guarantees
#     AdapterSvrS0 can never bind 62101 rather than protecting it.
#   - Starting the hotspot first and hoping ICS picks elsewhere does not hold.
#
# The order that works is the reverse: release ICS, let AdapterSvrS0 claim
# 62101/62102, and only then bring the hotspot back up.  ICS only takes ports
# that are still free.
$excluded = netsh int ipv4 show excludedportrange protocol=udp | Select-String "$exclusionStart"
if ($excluded) {
    Write-Output "Removing UDP exclusion $exclusionStart-$($exclusionStart + $exclusionCount - 1) - it blocks AdapterSvrS0 from binding the robot ports."
    netsh int ipv4 delete excludedportrange protocol=udp startport=$exclusionStart numberofports=$exclusionCount | Out-Null
    Start-Sleep -Seconds 2
}

if (-not (Get-Process -Name AdapterSvrS0 -ErrorAction SilentlyContinue)) {
    Write-Output 'Stopping ICS to release the robot ports...'
    Stop-Service SharedAccess -Force -ErrorAction SilentlyContinue
    Stop-Service icssvc -Force -ErrorAction SilentlyContinue
    Wait-For { (Get-Service SharedAccess -ErrorAction SilentlyContinue).Status -eq 'Stopped' } 'SharedAccess stop' 30 | Out-Null
    Start-Sleep -Seconds 3
}

# ------------------------------------------------------------------ 2. services
if (-not (Get-Process -Name RMServer -ErrorAction SilentlyContinue)) {
    Write-Output 'Starting RMServer...'
    Start-Detached (Join-Path $rmServer 'Server\RMServer.exe') (Join-Path $rmServer 'Server') | Out-Null
    Wait-For { Get-Process -Name RMServer -ErrorAction SilentlyContinue } 'RMServer' | Out-Null
    Start-Sleep -Seconds 6
}

# AdapterSvrS0 exits on startup when RMServer is not already listening, so this
# ordering is required, not cosmetic.  It must also start BEFORE the hotspot,
# so it wins 62101/62102 while ICS is still down.
if (-not (Get-Process -Name AdapterSvrS0 -ErrorAction SilentlyContinue)) {
    Write-Output 'Starting AdapterSvrS0...'
    Start-Detached (Join-Path $rmServer 'AdapterSvr\AdapterSvrS0.exe') (Join-Path $rmServer 'AdapterSvr') | Out-Null
    Wait-For { Get-Process -Name AdapterSvrS0 -ErrorAction SilentlyContinue } 'AdapterSvrS0' | Out-Null
    Start-Sleep -Seconds 8
}

# ------------------------------------------------------------------ 3. hotspot
# Bring the hotspot back after the services hold their ports; ICS only takes
# what is still free, so 62101/62102 stay with AdapterSvrS0.
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'setup_local_lan.ps1')
Start-Sleep -Seconds 5

if (-not (Get-Process -Name RMServerLogClient -ErrorAction SilentlyContinue)) {
    Write-Output 'Starting RMServerLogClient...'
    Start-Detached (Join-Path $rmServer 'RMServerLogClient\RMServerLogClient.exe') (Join-Path $rmServer 'RMServerLogClient') | Out-Null
}

if (-not (Get-Process -Name RoboMasterEngine -ErrorAction SilentlyContinue)) {
    Write-Output 'Starting RoboMasterEngine...'
    Start-Detached (Join-Path $engineRoot 'RoboMasterEngine.exe') $engineRoot | Out-Null
}

# ------------------------------------------------------------------- 4. bridge
# This bridge was the early reverse-engineering capture path (raw socket sniffing).
# It has been archived, and the directory now holds a different project, so the
# script file is usually gone.  Skip it rather than launching python against a
# missing file.  Note: when it IS present it holds MQTT ClientId "1", which stops
# the custom client from connecting to the broker.
$bridgeScript = Join-Path $bridgeRoot 'referee_live_server.py'
if (Test-Path $bridgeScript) {
    $bridge = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -like '*referee_live_server*' }
    if (-not $bridge) {
        Write-Output 'Starting referee bridge...'
        Start-Detached 'cmd.exe' $bridgeRoot "/c `"$python`" `"$bridgeScript`" --capture-ip 192.168.137.1 > `"$bridgeRoot\bridge-run.log`" 2>&1" | Out-Null
        Start-Sleep -Seconds 5
    }
}
else {
    Write-Output 'Referee bridge not present (archived) - skipping.'
}

# ----------------------------------------------------------------- 5. verdict
Write-Output ''
Write-Output '=== result ==='
foreach ($name in 'RMServer', 'AdapterSvrS0', 'RMServerLogClient', 'RoboMasterEngine') {
    $process = Get-Process -Name $name -ErrorAction SilentlyContinue
    Write-Output ("  {0,-20} {1}" -f $name, $(if ($process) { "RUN pid=$($process.Id)" } else { 'NOT RUNNING' }))
}

$owner = (netstat -ano -p UDP | Select-String ":$($robotPorts[0])\s" | Select-Object -First 1)
if ($owner) { Write-Output "  UDP $($robotPorts[0])         $($owner.ToString().Trim())" }
else { Write-Output "  UDP $($robotPorts[0])         NOT BOUND - the robot link will stay dead" }

$logClient = Get-Process -Name RMServerLogClient -ErrorAction SilentlyContinue
$stuck = Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -eq $logClient.Id -and $_.State -eq 'SynSent' }
if ($stuck) {
    Write-Output '  log viewer    [offline] - expected: it wants InfluxDB at 192.168.1.3:8086, which is not on this network.'
}
