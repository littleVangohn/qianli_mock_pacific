# ============================================================================
# 建立/恢复 Windows 移动热点 Local，并把服务器地址放到热点网卡上。
#
# 关键点（2026-11-19 实测）：
#   Windows 热点（ICS）会把客户端发往 192.168.137.0/24 以外的流量做 SNAT。
#   机器人主控按官方地址发 192.168.1.2:62101 时，如果 192.168.1.2 不在热点
#   网卡上，服务端看到的来源会变成主机物理 WLAN 地址，回包到不了机器人。
#   所以热点一起来就必须把 192.168.1.2/24 挪到热点网卡（本脚本负责）。
#
# 参数：
#   -Ssid / -Passphrase   热点名称和密码（默认 Local / 12345678）
#   -SkipServerAddress    只开热点，不动 192.168.1.2（排障用）
# ============================================================================

param(
    [string]$Ssid = 'Local',
    [string]$Passphrase = '12345678',
    [switch]$SkipServerAddress
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime

function Wait-WinRtAction($operation) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    $task = $method.Invoke($null, @($operation))
    $task.Wait()
}

function Wait-WinRtResult($operation, [Type]$resultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    $task = $method.MakeGenericMethod($resultType).Invoke($null, @($operation))
    $task.Wait()
    return $task.Result
}

function Get-ShareableProfile {
    # 优先真实 WLAN 上网 profile；没有 WLAN 时退到以太网等；
    # 排除 Clash/Mihomo 的 TUN 虚拟 profile（拿它开热点会失败）。
    $profiles = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]::GetConnectionProfiles()
    $valid = @($profiles | Where-Object {
        $null -ne $_ -and
        $_.GetNetworkConnectivityLevel() -eq 'InternetAccess' -and
        $_.ProfileName -notmatch '^(Meta|Clash|Mihomo|TUN)'
    })
    $wlan = $valid | Where-Object { $_.IsWlanConnectionProfile } | Select-Object -First 1
    if ($null -ne $wlan) { return $wlan }
    return ($valid | Select-Object -First 1)
}

function Move-ServerAddressToHotspot([int]$HotspotInterfaceIndex) {
    # 把 192.168.1.2/24 挪到热点网卡：
    #   - 先删掉其它网卡上的同名地址（典型是 VMnet1 上的 /32）
    #   - 等旧地址真正消失（Windows 删除不是瞬时的，否则重加会报 object already exists）
    #   - 热点网卡上没有就加上（/24 + SkipAsSource，避免抢默认路由）
    #   - 等到 Preferred；Tentative 等 DAD，Duplicate 删掉重加
    $wanted = '192.168.1.2'

    Get-NetIPAddress -IPAddress $wanted -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceIndex -ne $HotspotInterfaceIndex } |
        ForEach-Object {
            Remove-NetIPAddress -IPAddress $wanted -InterfaceIndex $_.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
        }

    $deadline = (Get-Date).AddSeconds(5)
    do {
        $other = Get-NetIPAddress -IPAddress $wanted -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -ne $HotspotInterfaceIndex }
        if ($null -eq $other) { break }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)

    $lastError = ''
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $addr = Get-NetIPAddress -IPAddress $wanted -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq $HotspotInterfaceIndex } |
            Select-Object -First 1

        if ($null -ne $addr -and $addr.AddressState -eq 'Preferred') { return $true }

        if ($null -ne $addr -and $addr.AddressState -eq 'Tentative') {
            # DAD 还没完成，给它时间
            Start-Sleep -Seconds 1
            continue
        }

        if ($null -ne $addr) {
            # Duplicate 或其它异常状态：删掉重加
            Remove-NetIPAddress -IPAddress $wanted -InterfaceIndex $HotspotInterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            $addr = $null
        }

        if ($null -eq $addr) {
            try {
                New-NetIPAddress -InterfaceIndex $HotspotInterfaceIndex -IPAddress $wanted -PrefixLength 24 -SkipAsSource $true -ErrorAction Stop | Out-Null
                $lastError = ''
            }
            catch {
                $lastError = $_.Exception.Message
            }
        }

        Start-Sleep -Seconds 1
    }

    if ($lastError) { Write-Warning "Move-ServerAddressToHotspot: $lastError" }
    return $false
}

$profile = Get-ShareableProfile
if ($null -eq $profile) {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Seconds 1
        $profile = Get-ShareableProfile
    } while ($null -eq $profile -and (Get-Date) -lt $deadline)
}
if ($null -eq $profile) {
    throw '没有可共享的 Internet 连接（Wi-Fi/以太网都要先连上能上网的网络）。'
}

$managerType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
$manager = $managerType::CreateFromConnectionProfile($profile)
$capability = $managerType::GetTetheringCapabilityFromConnectionProfile($profile)
if ($capability -ne 'Enabled') {
    throw "当前网络无法开启移动热点: $capability"
}

$config = $manager.GetCurrentAccessPointConfiguration()
$config.Ssid = $Ssid
$config.Passphrase = $Passphrase
$config.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::TwoPointFourGigahertz
$config.AuthenticationKind = [Windows.Networking.NetworkOperators.TetheringWiFiAuthenticationKind, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::Wpa2
Wait-WinRtAction ($manager.ConfigureAccessPointAsync($config))

if ($manager.TetheringOperationalState -ne 'On') {
    $result = Wait-WinRtResult ($manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime])
    if ($result.Status -ne 'Success') {
        throw "移动热点启动失败: $($result.Status) $($result.AdditionalErrorMessage)"
    }
}

# 等热点网卡拿到 192.168.137.1
$hotspotAddress = $null
$deadline = (Get-Date).AddSeconds(15)
do {
    $hotspotAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq '192.168.137.1' -and $_.AddressState -eq 'Preferred' } |
        Select-Object -First 1
    if ($null -ne $hotspotAddress) { break }
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

if ($null -eq $hotspotAddress) {
    throw '热点已启动，但没有找到 192.168.137.1。'
}

$serverNote = 'skipped'
if (-not $SkipServerAddress) {
    $ok = Move-ServerAddressToHotspot $hotspotAddress.InterfaceIndex
    if (-not $ok) {
        $state = (Get-NetIPAddress -IPAddress '192.168.1.2' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.InterfaceAlias):$($_.AddressState)" }) -join ', '
        throw "192.168.1.2 没能挂到热点网卡（$($hotspotAddress.InterfaceAlias)）上；当前状态: $state"
    }
    $serverNote = 'on hotspot adapter'
}

Write-Output 'RoboMaster local LAN is running.'
Write-Output "SSID: $Ssid"
Write-Output "Password: $Passphrase"
Write-Output "Adapter: $($hotspotAddress.InterfaceAlias)"
Write-Output "Hotspot IP: $($hotspotAddress.IPAddress)"
if ($SkipServerAddress) {
    Write-Output 'RoboMaster Server IP: skipped (-SkipServerAddress)'
}
else {
    Write-Output 'RoboMaster Server IP: 192.168.1.2/24 on the hotspot adapter'
}
Write-Output "Connected clients: $($manager.ClientCount)"
