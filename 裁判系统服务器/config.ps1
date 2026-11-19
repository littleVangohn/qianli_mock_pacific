# ============================================================================
# 本机模拟器配置（被 scripts\start_local_sim.ps1 点引用）
#
# 路径规则：
#   - 留空 = 自动查找（vendor\、本目录同级、..\从零开始认识裁判系统\ 等）
#   - 相对路径 = 相对于本文件所在目录（即「裁判系统服务器」目录）
#   - 绝对路径 = 原样使用（不推荐，仓库要能放到任意位置）
# ============================================================================

$Config = @{
    # 官方赛事服务器目录（里面含 RoboMasterEngine.exe）
    EngineRoot       = ''

    # 官方选手端目录（里面含 RoboMasterClient.exe）
    ClientRoot       = ''

    # 自定义客户端启动方式：wsl / windows / none
    CustomClientMode = 'wsl'

    # WSL 模式：发行版、工作目录、可执行文件（相对工作目录）
    WslDistro        = 'Ubuntu-22.04'
    WslWorkDir       = '~/rm26-build'
    WslBinary        = './RoboMasterClient2025'

    # windows 模式：自定义客户端 exe（相对本目录）
    CustomClientExe  = ''

    # 热点参数（Windows 移动热点）
    HotspotSsid      = 'Local'
    HotspotPassword  = '12345678'

    # 默认是否开热点；命令行 -NoHotspot 可临时关掉
    StartHotspot     = $true
}
