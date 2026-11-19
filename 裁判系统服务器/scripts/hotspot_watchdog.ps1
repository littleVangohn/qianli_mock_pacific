$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptDir
$setupScript = Join-Path $scriptDir 'setup_local_lan.ps1'
$logPath = Join-Path $repoRoot 'logs\hotspot_watchdog.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null

# 读取 config.ps1 里的热点参数（相对路径）
$ssid = 'Local'
$passphrase = '12345678'
$configFile = Join-Path $repoRoot 'config.ps1'
if (Test-Path -LiteralPath $configFile) {
    $Config = $null
    . $configFile
    if ($Config -is [hashtable]) {
        if ($Config.HotspotSsid) { $ssid = [string]$Config.HotspotSsid }
        if ($Config.HotspotPassword) { $passphrase = [string]$Config.HotspotPassword }
    }
}

$lastStatus = ''
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$managerType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]

while ($true) {
    try {
        $profiles = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]::GetConnectionProfiles()
        $profile = $profiles |
            Where-Object { $_.GetNetworkConnectivityLevel() -eq 'InternetAccess' -and $_.ProfileName -notmatch '^(Meta|Clash|Mihomo|TUN)' } |
            Select-Object -First 1
        if ($null -eq $profile) {
            throw 'No active Internet profile.'
        }

        $manager = $managerType::CreateFromConnectionProfile($profile)
        if ($manager.TetheringOperationalState -eq 'Off') {
            & $setupScript -Ssid $ssid -Passphrase $passphrase 2>&1 | Out-Null
            $status = 'RECOVERED'
        }
        else {
            $hotspotIf = (Get-NetIPAddress -IPAddress '192.168.137.1' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1).InterfaceIndex
            $serverAddress = $null
            if ($hotspotIf) {
                $serverAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -eq '192.168.1.2' -and $_.InterfaceIndex -eq $hotspotIf -and $_.AddressState -eq 'Preferred' } |
                    Select-Object -First 1
            }
            if ($null -eq $serverAddress) {
                & $setupScript -Ssid $ssid -Passphrase $passphrase 2>&1 | Out-Null
                $status = 'REPAIRED_IP'
            }
            else {
                $status = "ON clients=$($manager.ClientCount)"
            }
        }
        if ($status -ne $lastStatus) {
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value "$(Get-Date -Format o) hotspot=$status"
            $lastStatus = $status
        }
    }
    catch {
        $status = "ERROR $($_.Exception.Message)"
        if ($status -ne $lastStatus) {
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value "$(Get-Date -Format o) hotspot=$status"
            $lastStatus = $status
        }
    }
    Start-Sleep -Seconds 5
}
