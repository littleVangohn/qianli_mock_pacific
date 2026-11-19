# ============================================================================
# RoboMaster 本机模拟器 —— 一键启动
#
# 所有路径都相对本仓库目录（scripts 的上一级），不再写死盘符。
# 外部程序该放哪里见根目录 README.md。
#
# 默认行为（不加参数 = 完整链路 + 局域网热点）：
#   1. 停掉旧的引擎/服务/客户端
#   2. 停 ICS/热点，释放 UDP 62101-62103
#   3. 起 InfluxDB
#   4. 把 192.168.1.2/1.3 放到虚拟网卡，起引擎
#      （引擎自己拉起 RMServer / AdapterSvr / 日志端 / Redis）
#   5. 开热点 Local，并把 192.168.1.2/24 挪到热点网卡
#      （机器人按官方地址 192.168.1.2:62101 发才不会被 ICS NAT）
#   6. 图传 daemon → 官方选手端 → 自定义客户端
#
# 参数：
#   -NoHotspot      不开热点（只用本机服务；兼容 -SkipHotspot）
#   -WithHotspot    兼容旧参数（现在默认就开）
#   -ServicesOnly   只起服务，不起任何客户端
#   -SkipInflux     不起 InfluxDB
#   -DryRun         只打印路径/状态，不改任何东西
#   -WslDistro      覆盖 config.ps1 里的 WSL 发行版
# ============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipInflux,
    [switch]$NoHotspot,
    [switch]$SkipHotspot,
    [switch]$WithHotspot,
    [switch]$ServicesOnly,
    [string]$WslDistro = ''
)

if (($NoHotspot -or $SkipHotspot) -and $WithHotspot) {
    throw '-WithHotspot 与 -NoHotspot/-SkipHotspot 不能同时使用'
}

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $RepoRoot 'logs'
$DataDir = Join-Path $RepoRoot 'data'
$InfluxDir = Join-Path $RepoRoot 'tools\influxdb'
$InfluxExe = Join-Path $InfluxDir 'influxd.exe'
$InfluxData = Join-Path $DataDir 'influxdb'
$SetupLan = Join-Path $ScriptDir 'setup_local_lan.ps1'
$TcpPorts = 15861, 15862, 64998, 25862
$UdpPorts = 62101, 62102, 62103

# ---------------------------------------------------------------------------
# 配置：config.ps1 + 默认值
# ---------------------------------------------------------------------------
$Defaults = @{
    EngineRoot       = ''
    ClientRoot       = ''
    CustomClientMode = 'wsl'
    WslDistro        = 'Ubuntu-22.04'
    WslWorkDir       = '~/rm26-build'
    WslBinary        = './RoboMasterClient2025'
    CustomClientExe  = ''
    HotspotSsid      = 'Local'
    HotspotPassword  = '12345678'
    StartHotspot     = $true
}
$UserConfig = @{}
$ConfigFile = Join-Path $RepoRoot 'config.ps1'
if (Test-Path -LiteralPath $ConfigFile) {
    $Config = $null
    . $ConfigFile
    if ($Config -is [hashtable]) { $UserConfig = $Config }
}
$Config = @{}
foreach ($key in $Defaults.Keys) { $Config[$key] = $Defaults[$key] }
foreach ($key in $UserConfig.Keys) { $Config[$key] = $UserConfig[$key] }

$StartHotspot = [bool]$Config.StartHotspot
if ($NoHotspot -or $SkipHotspot) { $StartHotspot = $false }
if ($WithHotspot) { $StartHotspot = $true }
$WslDistroName = [string]$Config.WslDistro
if ($WslDistro) { $WslDistroName = $WslDistro }
$CustomMode = ([string]$Config.CustomClientMode).ToLowerInvariant()

# ---------------------------------------------------------------------------
# 输出与通用函数
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
}
function Write-Ok([string]$Message) { Write-Host "  OK   $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  WARN $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host "  ERR  $Message" -ForegroundColor Red }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RepoPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Find-ExeUnder([string]$Root, [string]$ExeName, [int]$MaxDepth = 4) {
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $start = (Resolve-Path -LiteralPath $Root).Path
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $start; Depth = 0 })
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $current.Path $ExeName)) { return $current.Path }
        if ($current.Depth -ge $MaxDepth) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $current.Path -Directory -ErrorAction SilentlyContinue) {
            $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = ($current.Depth + 1) })
        }
    }
    return $null
}

function Find-OfficialDir([string]$Kind, [string]$ExplicitPath) {
    if ($Kind -eq 'engine') {
        $exeName = 'RoboMasterEngine.exe'
        $dirPattern = 'RoboMasterEngine*'
    }
    else {
        $exeName = 'RoboMasterClient.exe'
        $dirPattern = 'RoboMasterClient*'
    }

    $explicit = Resolve-RepoPath $ExplicitPath
    if ($explicit) {
        if (Test-Path -LiteralPath (Join-Path $explicit $exeName)) { return $explicit }
        $found = Find-ExeUnder $explicit $exeName 4
        if ($found) { return $found }
    }

    $patterns = @(
        (Join-Path $RepoRoot ('vendor\' + $dirPattern)),
        (Join-Path $RepoRoot $dirPattern),
        (Join-Path $RepoRoot ('..\vendor\' + $dirPattern)),
        (Join-Path $RepoRoot ('..\' + $dirPattern)),
        (Join-Path $RepoRoot ('..\从零开始认识裁判系统\' + $dirPattern))
    )
    foreach ($pattern in $patterns) {
        # 注意：pattern 里带通配符，不能用 GetFullPath（.NET 会报 Illegal characters in path）
        foreach ($dir in Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue) {
            $found = Find-ExeUnder $dir.FullName $exeName 4
            if ($found) { return $found }
        }
    }
    return $null
}

function ConvertTo-WslPath([string]$WindowsPath) {
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2]
    }
    return $p
}

function Test-UdpBind([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.UdpClient
        $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
        $client.Close()
        return $true
    }
    catch { return $false }
}

function Test-AllUdpPortsFree {
    foreach ($port in $UdpPorts) {
        if (-not (Test-UdpBind $port)) { return $false }
    }
    return $true
}

function Test-InternetAccess {
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4Connectivity -eq 'Internet' }
    foreach ($p in $profiles) {
        if ($p.InterfaceAlias -match '^(Meta|Clash|Mihomo|TUN)') { continue }
        return $true
    }
    return $false
}

function Wait-InternetAccess([int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-InternetAccess) { return $true }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-VirtualServerAdapter {
    # 引擎启动阶段需要一个已启用的非 Wi-Fi 网卡承载 192.168.1.2/1.3。
    $adapters = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq 'Up' -and
            $_.Name -notmatch '^(WLAN|Meta|Clash|Mihomo|TUN|Bluetooth)' -and
            $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|Bluetooth'
        }
    $vm1 = $adapters | Where-Object { $_.Name -eq 'VMware Network Adapter VMnet1' } | Select-Object -First 1
    if ($vm1) { return $vm1 }
    $vm8 = $adapters | Where-Object { $_.Name -eq 'VMware Network Adapter VMnet8' } | Select-Object -First 1
    if ($vm8) { return $vm8 }
    return ($adapters | Select-Object -First 1)
}

function Ensure-VirtualServerAddress {
    $target = Get-VirtualServerAdapter
    if (-not $target) {
        Write-Err '找不到可挂 192.168.1.2 的虚拟网卡（VMnet1/VMnet8 或其它非 Wi-Fi 网卡）'
        return $false
    }

    foreach ($ip in @('192.168.1.2', '192.168.1.3')) {
        # 先把别处的同名地址清掉（典型是上次热点网卡上的 192.168.1.2/24）
        Get-NetIPAddress -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -ne $target.ifIndex } |
            ForEach-Object {
                Remove-NetIPAddress -IPAddress $ip -InterfaceIndex $_.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
            }

        $existing = Get-NetIPAddress -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq $target.ifIndex } |
            Select-Object -First 1
        if ($null -ne $existing -and $existing.AddressState -ne 'Preferred') {
            Remove-NetIPAddress -IPAddress $ip -InterfaceIndex $target.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
            $existing = $null
        }
        if ($null -eq $existing) {
            New-NetIPAddress -InterfaceIndex $target.ifIndex -IPAddress $ip -PrefixLength 32 -SkipAsSource $false -ErrorAction SilentlyContinue | Out-Null
        }
    }

    $deadline = (Get-Date).AddSeconds(10)
    do {
        $ok = $true
        foreach ($ip in @('192.168.1.2', '192.168.1.3')) {
            $addr = Get-NetIPAddress -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -eq $target.ifIndex -and $_.AddressState -eq 'Preferred' } |
                Select-Object -First 1
            if ($null -eq $addr) { $ok = $false; break }
        }
        if ($ok) {
            Write-Ok "服务器地址就绪：192.168.1.2/32, 192.168.1.3/32 @ $($target.Name)"
            return $true
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    Write-Err "192.168.1.2/1.3 在 $($target.Name) 上仍未变成 Preferred"
    return $false
}

function Get-OwnerName([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($p) { return $p.ProcessName }
    return "pid:$ProcessId"
}

function Get-ListeningPorts([int[]]$Ports) {
    $listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $Ports -contains $_.LocalPort }
    return @($listening.LocalPort | Sort-Object -Unique)
}

function Get-BoundUdpPorts([int[]]$Ports) {
    $bound = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $Ports -contains $_.LocalPort }
    return @($bound.LocalPort | Sort-Object -Unique)
}

function Stop-Stack {
    Write-Step '停止现有的本机赛事服务'
    Stop-Process -Name RoboMasterEngine -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    foreach ($name in 'RMServer', 'AdapterSvrS0', 'RMServerLogClient', 'redis-server') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Start-Sleep -Seconds 2
    Write-Ok '旧进程已清理'
}

function Wait-UdpPortsFree([int]$TimeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $busy = @($UdpPorts | Where-Object { -not (Test-UdpBind $_) })
        if ($busy.Count -eq 0) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Start-Influx {
    if ($SkipInflux) {
        Write-Warn '按参数跳过 InfluxDB'
        return
    }
    if (Get-Process -Name influxd -ErrorAction SilentlyContinue) {
        Write-Ok 'InfluxDB 已在运行（复用现有实例）'
        return
    }
    if (-not (Test-Path -LiteralPath $InfluxExe)) {
        Write-Warn "找不到 InfluxDB：$InfluxExe（跳过；日志端仍可 Online，只是历史数据不落库）"
        return
    }

    Write-Step '启动 InfluxDB'
    New-Item -ItemType Directory -Force -Path $InfluxData | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Start-Process -FilePath $InfluxExe `
        -ArgumentList '--http-bind-address', '0.0.0.0:8086',
                      '--bolt-path', (Join-Path $InfluxData 'influxd.bolt'),
                      '--engine-path', (Join-Path $InfluxData 'engine') `
        -WorkingDirectory $InfluxDir `
        -RedirectStandardOutput (Join-Path $LogDir 'influxd.out.log') `
        -RedirectStandardError (Join-Path $LogDir 'influxd.err.log') `
        -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds(25)
    do {
        try {
            $health = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8086/health' -TimeoutSec 3
            if ($health.StatusCode -eq 200) {
                Write-Ok 'InfluxDB 就绪 (http://127.0.0.1:8086/health)'
                return
            }
        }
        catch { }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    Write-Warn 'InfluxDB 启动后健康检查未通过；日志端仍可 Online，但历史数据可能不落库'
}

function Start-EngineAndWait {
    Write-Step '启动 RoboMasterEngine（引擎会自动拉起 RMServer/AdapterSvr/日志端/Redis）'
    Start-Process -FilePath $EngineExe -WorkingDirectory $EngineRoot | Out-Null

    $deadline = (Get-Date).AddSeconds(90)
    do {
        $ports = Get-ListeningPorts $TcpPorts
        if (($TcpPorts | Where-Object { $ports -notcontains $_ }).Count -eq 0) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $ports = Get-ListeningPorts $TcpPorts
    $missing = @($TcpPorts | Where-Object { $ports -notcontains $_ })
    if ($missing.Count -gt 0) {
        Write-Err "TCP 端口未全部监听：缺 $($missing -join ',')"
        return $false
    }
    Write-Ok "TCP 已监听：$($ports -join ',')"

    $deadline = (Get-Date).AddSeconds(40)
    do {
        $bound = Get-BoundUdpPorts $UdpPorts
        if (($UdpPorts | Where-Object { $bound -notcontains $_ }).Count -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    $bound = Get-BoundUdpPorts $UdpPorts
    $missingUdp = @($UdpPorts | Where-Object { $bound -notcontains $_ })
    if ($missingUdp.Count -gt 0) {
        Write-Err "UDP 端口未全部绑定：缺 $($missingUdp -join ',')（ICS 可能又抢回去了）"
        return $false
    }
    Write-Ok "UDP 已绑定：$($bound -join ',')"
    return $true
}

function Wait-EngineS1Link([int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $link = Get-NetTCPConnection -RemotePort 64998 -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -eq '192.168.1.2' } |
            Select-Object -First 1
        if ($link) { return $link }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-NewLogText([string]$Path, [long]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt $Offset) { $Offset = 0 }
        [void]$fs.Seek($Offset, [IO.SeekOrigin]::Begin)
        $sr = New-Object IO.StreamReader($fs)
        try { return $sr.ReadToEnd() } finally { $sr.Close() }
    }
    finally { $fs.Close() }
}

function Stop-Clients {
    Write-Step '停止官方选手端 / 图传 daemon'
    Stop-Process -Name RoboMasterClient -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    foreach ($name in 'RMClientDaemon', 'RMClientAssist_VideoRecord', 'RMClientAssist_MarkRecognition', 'RMClientAssist_SerialPort', 'RMClientAssist_RemoteSerialPort') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Start-Sleep -Seconds 2
    Write-Ok '旧客户端已清理'
}

function Start-CustomClient {
    if ($CustomMode -eq 'none') {
        Write-Warn '按配置跳过自定义客户端（CustomClientMode = none）'
        return
    }

    if ($CustomMode -eq 'windows') {
        $exe = Resolve-RepoPath $Config.CustomClientExe
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            Write-Warn "找不到自定义客户端 exe：$exe（CustomClientExe 为空或路径不对）"
            return
        }
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
        Write-Ok "自定义客户端已启动：$exe"
        return
    }

    # ---- WSL 模式 ----
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Warn '找不到 wsl.exe，跳过自定义客户端'
        return
    }

    $workDir = [string]$Config.WslWorkDir
    $binary = [string]$Config.WslBinary
    $binLeaf = Split-Path -Leaf $binary
    $procName = $binLeaf
    if ($procName.Length -gt 15) { $procName = $procName.Substring(0, 15) }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 产物检查（先杀旧进程，再看二进制是否存在）
        & wsl -d $WslDistroName -- pkill -9 -x $procName 2>&1 | Out-Null
        $checkCmd = 'test -x ' + $workDir + '/' + $binLeaf + ' && echo OK || echo MISSING'
        $check = (& wsl -d $WslDistroName -- bash -lc $checkCmd 2>$null) -join ''
        if ($check -notmatch 'OK') {
            Write-Warn "WSL 里没有可执行文件：$workDir/$binLeaf"
            Write-Warn '先构建自定义客户端：bash run.sh --build（产物固定到 ~/rm26-build/）'
            return
        }

        # Windows 主机在 WSL 里的地址
        $wslHost = $null
        for ($retry = 1; $retry -le 5; $retry++) {
            $route = & wsl -d $WslDistroName -- ip route show default 2>$null
            if ($route -match 'via\s+([0-9.]+)') { $wslHost = $Matches[1]; break }
            Start-Sleep -Seconds 2
        }
        if (-not $wslHost) {
            Write-Warn '拿不到 WSL 的 Windows 主机 IP，跳过自定义客户端'
            return
        }

        $engineLogWsl = ''
        if (Test-Path -LiteralPath $EngineLogDir) { $engineLogWsl = ConvertTo-WslPath $EngineLogDir }

        $envPart = "RM_MQTT_BROKER=$wslHost RM_MQTT_PORT=3333"
        if ($engineLogWsl) { $envPart += " RM_ENGINE_ARMOR_LOG_DIR='$engineLogWsl'" }

        # 末尾 sleep 6 必须保留：一次性 wsl.exe 会话退出会把还没初始化完的子进程带走。
        $bashCmd = "cd $workDir && $envPart setsid nohup $binary > /tmp/cquqianli_client.log 2>&1 < /dev/null & sleep 6"

        $wslProc = $null
        for ($try = 1; $try -le 3; $try++) {
            & wsl -d $WslDistroName -- pkill -9 -x $procName 2>&1 | Out-Null
            Start-Sleep -Seconds 1
            & wsl -d $WslDistroName -- bash -lc $bashCmd 2>&1 | Out-Null
            Start-Sleep -Seconds 8
            $wslProc = & wsl -d $WslDistroName -- pgrep -ax $procName 2>$null
            if ($wslProc) { break }
            Write-Warn "第 $try 次启动自定义客户端未成功，重试..."
        }

        if ($wslProc) {
            Write-Ok "自定义客户端运行中：$($wslProc -join ' ')"
        }
        else {
            Write-Warn 'WSL 里没找到自定义客户端，看 /tmp/cquqianli_client.log'
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Start-Clients {
    Write-Step '启动完整客户端链路（daemon → 官方选手端 → 自定义客户端）'

    if (-not $ClientExe -or -not (Test-Path -LiteralPath $ClientExe)) {
        Write-Err "找不到官方选手端 RoboMasterClient.exe（见根目录 README 的放置说明）"
        return $false
    }
    if (-not (Test-Path -LiteralPath $DaemonExe)) {
        Write-Err "找不到图传 daemon：$DaemonExe"
        return $false
    }

    $dji = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2CA3' }
    if ($dji) {
        $coms = @($dji | Where-Object { $_.Class -eq 'Ports' } | ForEach-Object { $_.FriendlyName })
        Write-Ok "图传接收端已枚举：$($coms -join ', ')"
    }
    else {
        Write-Warn '图传接收端未枚举（无 VID_2CA3 / COM5 / COM8）。服务会起来，但不会出图。'
    }

    Stop-Clients

    Write-Ok '启动图传 daemon...'
    Start-Process -FilePath $DaemonExe -WorkingDirectory (Split-Path -Parent $DaemonExe) | Out-Null
    Start-Sleep -Seconds 6

    $playerLog = Join-Path $env:USERPROFILE 'AppData\LocalLow\DJI\RoboMasterClient\Player.log'
    $logOffset = 0
    if (Test-Path -LiteralPath $playerLog) { $logOffset = (Get-Item $playerLog).Length }

    Write-Ok '启动官方选手端...'
    Start-Process -FilePath $ClientExe -WorkingDirectory $ClientRoot | Out-Null

    $deadline = (Get-Date).AddSeconds(60)
    $brokerUp = $false
    do {
        if (Get-NetTCPConnection -LocalPort 3333 -State Listen -ErrorAction SilentlyContinue) { $brokerUp = $true; break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    if ($brokerUp) { Write-Ok 'MQTT broker 3333 已监听' }
    else { Write-Warn 'MQTT broker 3333 未监听（官方选手端可能没登录/卡住）' }

    $deadline = (Get-Date).AddSeconds(90)
    $loggedIn = $false
    do {
        $newLog = Get-NewLogText $playerLog $logOffset
        if ($newLog -match 'Login : Success') { $loggedIn = $true; break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    if ($loggedIn) { Write-Ok '官方选手端 Login : Success' }
    else { Write-Warn '日志里没看到 Login : Success；请确认官方选手端已登录 R1-Hero' }

    Start-CustomClient

    # 自定义客户端可能先吃一次 CONNACK(2)（旧会话 / 官方选手端刚登录），会自动退避重试。
    # WSL 镜像网络下连接会显示成 127.0.0.1，所以 loopback 也算连接成功。
    $deadline = (Get-Date).AddSeconds(45)
    $mqttSessions = $null
    do {
        $mqttSessions = Get-NetTCPConnection -LocalPort 3333 -State Established -ErrorAction SilentlyContinue
        if ($mqttSessions) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    if ($mqttSessions) {
        $remotes = @($mqttSessions | ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique)
        Write-Ok "自定义客户端 MQTT 已连接：$($remotes -join ', ')"
    }
    else {
        Write-Warn '45 秒内没看到 3333 的 MQTT 连接；自定义客户端会自动重试，看 /tmp/cquqianli_client.log'
    }

    return $true
}

function Show-AdapterStatus {
    if (-not $EngineRoot) { return }
    $logDir = Join-Path $EngineRoot 'RoboMasterEngine_Data\StreamingAssets\RMServer\AdapterSvr\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { return }
    $log = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return }

    $line = Select-String -LiteralPath $log.FullName -Pattern 'Translator count' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($line) { Write-Host "  $($line.Line.Trim())" }

    $login = Select-String -LiteralPath $log.FullName -Pattern '\[LOGIN\]\[V1\]:' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($login -and $login.Line -match 'ip:(\d+\.\d+\.\d+\.\d+) port:(\d+)') {
        $source = $Matches[1] + ':' + $Matches[2]
        if ($Matches[1] -like '192.168.*' -or $Matches[1] -like '10.*' -or $Matches[1] -like '172.*') {
            Write-Host "  最近机器人登录来源：$source" -ForegroundColor Green
        }
        else {
            Write-Host "  最近机器人登录来源：$source" -ForegroundColor Yellow
        }
    }
}

function Show-Status {
    Write-Step '本机模拟器状态'
    foreach ($name in 'RoboMasterEngine', 'RMServer', 'AdapterSvrS0', 'RMServerLogClient', 'redis-server', 'influxd') {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($p) { Write-Host ("  {0,-20} RUN  pid={1}" -f $name, ($p.Id -join ',')) -ForegroundColor Green }
        else { Write-Host ("  {0,-20} NOT RUNNING" -f $name) -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '  TCP 监听：'
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $TcpPorts -contains $_.LocalPort } |
        Sort-Object LocalPort | ForEach-Object {
            Write-Host ("    {0,-6} {1}" -f $_.LocalPort, (Get-OwnerName $_.OwningProcess))
        }

    Write-Host '  UDP 绑定：'
    Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $UdpPorts -contains $_.LocalPort } |
        Sort-Object LocalPort | ForEach-Object {
            Write-Host ("    {0,-6} {1}" -f $_.LocalPort, (Get-OwnerName $_.OwningProcess))
        }

    $link = Get-NetTCPConnection -RemotePort 64998 -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -eq '192.168.1.2' } | Select-Object -First 1
    if ($link) { Write-Host "  引擎 -> 192.168.1.2:64998  ESTABLISHED ($(Get-OwnerName $link.OwningProcess))" -ForegroundColor Green }
    else { Write-Host '  引擎 -> 192.168.1.2:64998  未建立' -ForegroundColor Yellow }

    $logProc = Get-Process -Name RMServerLogClient -ErrorAction SilentlyContinue
    if ($logProc) {
        $title = $logProc.MainWindowTitle
        if ($title -match '\[offline\]') { Write-Host "  日志端：$title" -ForegroundColor Yellow }
        else { Write-Host "  日志端：$title" -ForegroundColor Green }
    }

    Write-Host ''
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -in '192.168.137.1', '192.168.1.2', '192.168.1.3' } |
        ForEach-Object {
            Write-Host ("  IP  {0,-15} {1} [{2}]" -f $_.IPAddress, $_.InterfaceAlias, $_.AddressState)
        }

    Show-AdapterStatus
}

# ---------------------------------------------------------------------------
# 解析外部程序路径（相对本目录 / 自动查找）
# ---------------------------------------------------------------------------
$EngineRoot = Find-OfficialDir 'engine' $Config.EngineRoot
$ClientRoot = Find-OfficialDir 'client' $Config.ClientRoot
$EngineExe = $null
$EngineLogDir = $null
$ClientExe = $null
$DaemonExe = $null

if ($EngineRoot) {
    $EngineExe = Join-Path $EngineRoot 'RoboMasterEngine.exe'
    $EngineLogDir = Join-Path $EngineRoot 'RoboMasterEngine_Data\StreamingAssets\RMServer\RMServerLogClient\RM裁判系统日志文件夹3.0'
}
if ($ClientRoot) {
    $ClientExe = Join-Path $ClientRoot 'RoboMasterClient.exe'
    $DaemonExe = Join-Path $ClientRoot 'RoboMasterClient_Data\StreamingAssets\Tools\RMClientDaemon\RMClientDaemon.exe'
}

$WithClients = -not $ServicesOnly

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' RoboMaster 本机模拟器 —— 赛事服务 + 裁判系统' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
$hotspotDesc = '不启动'
if ($StartHotspot) { $hotspotDesc = $Config.HotspotSsid + '（默认开启）' }
Write-Host "  本目录: $RepoRoot"
Write-Host "  引擎:   $(if ($EngineRoot) { $EngineRoot } else { '(未找到)' })"
Write-Host "  选手端: $(if ($ClientRoot) { $ClientRoot } else { '(未找到)' })"
Write-Host "  热点:   $hotspotDesc"

if ($DryRun) {
    Write-Step 'DryRun：只检查，不修改'
    Write-Host "  InfluxDB: $InfluxExe"
    Write-Host "  数据目录: $InfluxData"
    Write-Host "  热点脚本: $SetupLan"
    Write-Host "  自定义客户端: mode=$CustomMode distro=$WslDistroName dir=$($Config.WslWorkDir) bin=$($Config.WslBinary)"
    Write-Host "  当前 UDP 可绑定: $(($UdpPorts | ForEach-Object { "$_=$(Test-UdpBind $_)" }) -join ' ')"
    Show-Status
    exit 0
}

if (-not $EngineExe -or -not (Test-Path -LiteralPath $EngineExe)) {
    Write-Err '找不到 RoboMasterEngine.exe'
    Write-Host '  请把官方赛事服务器文件夹放到：'
    Write-Host '    <本目录>\vendor\RoboMasterEngine ...\'
    Write-Host '  或 <本目录>\ 的上一级（与仓库同级），脚本会自动查找。'
    Write-Host '  也可以在 config.ps1 里用 EngineRoot 显式指定。'
    exit 1
}
if ($WithClients) {
    if (-not $ClientExe -or -not (Test-Path -LiteralPath $ClientExe)) {
        Write-Err '找不到官方选手端 RoboMasterClient.exe'
        Write-Host '  请把官方选手端文件夹放到：'
        Write-Host '    <本目录>\vendor\RoboMasterClient ...\'
        Write-Host '  或 <本目录>\ 的上一级（与仓库同级），脚本会自动查找。'
        Write-Host '  也可以在 config.ps1 里用 ClientRoot 显式指定。'
        exit 1
    }
}

if (-not (Test-Admin)) {
    Write-Warn '需要管理员权限，正在重新以管理员身份启动...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit 0
}

$profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
if ($profiles | Where-Object { $_.Name -eq 'cpxt' }) {
    Write-Warn '当前连着 cpxt 外部裁判网：本机模拟器会占用 192.168.1.2，可能与外部服务器冲突。'
    Write-Warn '如果要用外部 cpxt，请现在按 Ctrl+C 取消；3 秒后继续...'
    Start-Sleep -Seconds 3
}

if ($StartHotspot) {
    $tunAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(Meta|Clash|Mihomo|TUN)' }
    if ($tunAdapters) {
        Write-Warn "检测到代理 TUN 网卡：$($tunAdapters.Name -join ', ')"
        Write-Warn '热点切换会瞬断 Wi-Fi，Clash 可能重启并短暂断外网；建议跑模拟器时关掉 TUN 模式。'
    }
}

# 1) 清理旧栈
Stop-Stack

# 2) InfluxDB
Start-Influx

# 3) 端口：开热点模式先停 ICS；不开热点只检查
if ($StartHotspot) {
    Write-Step '停止 ICS/移动热点，释放 UDP 62101-62103'
    Stop-Service SharedAccess -Force -ErrorAction SilentlyContinue
    Stop-Service icssvc -Force -ErrorAction SilentlyContinue
    if (-not (Wait-UdpPortsFree 60)) {
        Write-Err 'UDP 62101-62103 仍被占用，ICS 没有释放。'
        Write-Warn '试试在 Windows 设置里关闭移动热点，或重启电脑后再运行。'
        exit 1
    }
    Write-Ok 'UDP 62101/62102/62103 当前可绑定'
}
else {
    if (Test-AllUdpPortsFree) {
        Write-Step '检查 UDP 端口'
        Write-Ok 'UDP 62101/62102/62103 当前可绑定'
    }
    elseif (Wait-UdpPortsFree 10) {
        Write-Step '检查 UDP 端口'
        Write-Ok 'UDP 62101/62102/62103 当前可绑定'
    }
    else {
        Write-Err 'UDP 62101-62103 被 ICS/移动热点占用。'
        Write-Warn '要么先在 Windows 设置里关闭移动热点，要么去掉 -NoHotspot（默认模式会先停 ICS 再开热点）。'
        exit 1
    }
}

# 3.1) 引擎启动阶段：192.168.1.2/1.3 先放在虚拟网卡上
if (-not (Ensure-VirtualServerAddress)) {
    Write-Err '本地服务器地址没准备好，引擎/官方选手端会连不上 192.168.1.2'
    exit 1
}

# 3.2) 起引擎，占住 62101-62103
$stackOk = $false
for ($attempt = 1; $attempt -le 2; $attempt++) {
    if (Start-EngineAndWait) { $stackOk = $true; break }
    Write-Warn '本次启动未占住端口，清理后重试一次...'
    Stop-Stack
}
if (-not $stackOk) {
    Write-Err '服务未能占住 62101-62103。请确认没有别的程序占用，或重启电脑后再试。'
    exit 1
}

# 4) 热点（默认开）：开热点并把 192.168.1.2/24 挪到热点网卡
if ($StartHotspot) {
    if (-not (Wait-InternetAccess 30)) {
        Write-Warn 'WLAN 30 秒内没有恢复 InternetAccess，仍尝试启动热点'
    }

    $hotspotOk = $false
    for ($hotspotTry = 1; $hotspotTry -le 4; $hotspotTry++) {
        Write-Step "启动热点 $($Config.HotspotSsid)（第 $hotspotTry 次）"
        try {
            & $SetupLan -Ssid $Config.HotspotSsid -Passphrase $Config.HotspotPassword
            $hotspotOk = $true
            break
        }
        catch {
            Write-Warn "热点脚本失败：$($_.Exception.Message)"
        }
        Start-Sleep -Seconds 6
        [void](Wait-InternetAccess 20)
    }

    $ip137 = Get-NetIPAddress -IPAddress '192.168.137.1' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1
    $ip12 = Get-NetIPAddress -IPAddress '192.168.1.2' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1

    if (-not $hotspotOk -or -not $ip137 -or -not $ip12) {
        Write-Warn '热点或服务器地址未完全就绪；物理机器人可能连不上'
        Write-Warn '若仍失败，先关掉 Clash/Mihomo TUN，或手动在设置里开移动热点后重跑'
    }
    elseif ($ip12.InterfaceIndex -ne $ip137.InterfaceIndex) {
        Write-Warn "192.168.1.2 不在热点网卡上（在 $($ip12.InterfaceAlias)），机器人登录回包会被 NAT 丢掉"
        Write-Warn '请重跑一次；或手动把 192.168.1.2/24 挪到热点网卡后让机器人重连'
    }
    else {
        Write-Ok "热点就绪：$($ip137.IPAddress) 与 192.168.1.2/24 都在 $($ip137.InterfaceAlias)"
    }

    # 地址从虚拟网卡挪走后，引擎的 S1 客户端会重连一次
    $link = Wait-EngineS1Link 30
    if ($link) { Write-Ok "引擎 S1 客户端已重连 192.168.1.2:64998（来源 $($link.LocalAddress)）" }
    else { Write-Warn '引擎 -> 192.168.1.2:64998 还没重连上，稍后看状态汇总' }
}
else {
    Write-Ok '按参数不启动热点；192.168.1.2/1.3 留在虚拟网卡上'
}

# 5) 日志端兜底 + 等待 Online
$deadline = (Get-Date).AddSeconds(30)
do {
    $logProc = Get-Process -Name RMServerLogClient -ErrorAction SilentlyContinue
    if ($logProc -and $logProc.MainWindowTitle -notmatch '\[offline\]') { break }
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

# 6) 状态汇总
Show-Status

if ($WithClients) {
    [void](Start-Clients)
    Show-Status
}

Write-Host ''
if ($WithClients) {
    Write-Host '完整链路已启动：赛事服务 + 裁判系统 + 官方选手端 + 自定义客户端。' -ForegroundColor Green
}
else {
    Write-Host '本机模拟器已启动（仅赛事服务/裁判系统）。' -ForegroundColor Green
}
Write-Host ''
Write-Host '判据：AdapterSvr 日志出现 S0Robot[1]；日志端标题不带 [offline]；3333 有 MQTT 连接。'
Write-Host '物理机器人连 Local 后，若是在热点/栈重启前就连着的，断开重连一次更稳。'
exit 0
