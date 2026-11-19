# RoboMaster 本机模拟器（赛事服务 + 裁判系统）

一键启动整套链路：

```bat
start_local_sim.bat
```

双击即可（会自动请求管理员）。默认依次启动：

1. InfluxDB（`127.0.0.1:8086`，没有也能跑）
2. 官方赛事引擎 `RoboMasterEngine`（自动拉起 `RMServer` / `AdapterSvrS0` / `RMServerLogClient` / `redis-server`）
3. 局域网热点 `Local`（2.4 GHz / WPA2），并把 `192.168.1.2/24` 放到热点网卡上
4. 图传 daemon `RMClientDaemon`
5. 官方选手端 `RoboMasterClient`（MQTT broker `:3333`，需要登录 R1-Hero）
6. 自定义客户端（默认 WSL：`~/rm26-build/RoboMasterClient2025`）

## 1. 三个程序放哪

仓库不包含官方二进制。推荐把官方程序放在本目录的 `vendor\` 下（已被 `.gitignore`），
或者放在本目录的上一级（与仓库同级），脚本会自动查找。

```text
任意目录\
├── qianli_mock_pacific\                  <- 本仓库（start_all_local 分支）
│   ├── run.sh                            <- 自定义客户端构建/启动
│   ├── upstream\                         <- 自定义客户端源码
│   └── 裁判系统服务器\                     <- 本目录
│       ├── start_local_sim.bat           <- 唯一入口
│       ├── config.ps1                    <- 路径/热点/WSL 配置
│       ├── scripts\
│       ├── services\                     <- 串口诊断（备用，不在主链路）
│       ├── tools\influxdb\               <- 放 influxd.exe（可选）
│       └── vendor\                       <- 官方程序放这里（.gitignore）
│           ├── RoboMasterEngine 12.0.0.176_Student\
│           └── RoboMasterClient 12.0.0.213_Student\
└── ...
```

自动查找规则（对 `RoboMasterEngine*` / `RoboMasterClient*` 文件夹，最多往下 4 层）：

- `<本目录>\vendor\`
- `<本目录>\`
- `<本目录>\..\vendor\`
- `<本目录>\..\`
- `<本目录>\..\从零开始认识裁判系统\`（旧布局）

找不到时在 `config.ps1` 里显式写（相对本目录）：

```powershell
EngineRoot = 'vendor\RoboMasterEngine 12.0.0.176_Student'
ClientRoot = 'vendor\RoboMasterClient 12.0.0.213_Student\RoboMasterClient'
```

### 自定义客户端

默认从 WSL 启动，构建方法见仓库根目录 `README.md`：

```bash
bash run.sh --build    # 产物固定 ~/rm26-build/RoboMasterClient2025
```

`config.ps1` 里可以改：

```powershell
CustomClientMode = 'wsl'          # wsl / windows / none
WslDistro        = 'Ubuntu-22.04'
WslWorkDir       = '~/rm26-build'
WslBinary        = './RoboMasterClient2025'
# windows 模式：
# CustomClientExe = 'vendor\my_client\client.exe'
```

服务端会按顺序：等官方选手端 `Login : Success`、MQTT `:3333` 监听，
再拉自定义客户端，并做一次 MQTT 连接检查。

## 2. 启动参数

```bat
start_local_sim.bat                 默认全起（含热点）
start_local_sim.bat -NoHotspot      不开热点（兼容 -SkipHotspot）
start_local_sim.bat -ServicesOnly   只起服务，不起客户端
start_local_sim.bat -DryRun         只打印解析结果和状态，不改任何东西
start_local_sim.bat -SkipInflux     不起 InfluxDB
start_local_sim.bat -WslDistro Ubuntu-22.04
```

也可以用 PowerShell 直接跑：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_local_sim.ps1 -NoHotspot
```

## 3. 网络与机器人（重要）

本机模拟器同时用两套地址：

| 地址 | 用途 | 通常在哪 |
|---|---|---|
| `192.168.1.2` | 官方赛事服务器（引擎/选手端/机器人） | 开热点时在热点网卡上；不开时在 VMware VMnet1 |
| `192.168.1.3` | 日志/辅助地址 | VMware VMnet1 |
| `192.168.137.1` | 热点网关，机器人从这里拿 DHCP | 热点网卡 `WLAN 3` |
| `192.168.137.x` | 机器人自己拿到的地址 | 热点 |

**Windows 热点（ICS）会把热点客户端发往 `192.168.137.0/24` 以外的流量做 SNAT。**
所以脚本开热点后会把 `192.168.1.2/24` 挪到热点网卡上，机器人按官方地址
`192.168.1.2:62101` 发就能直达，来源保持不变。

注意：

- 如果机器人在热点/栈重启前就已经连着，建议断开重连一次；否则旧的 NAT 映射可能还在，
  服务端会看到 `172.x.x.x` 这种被改写过的来源，回包到不了机器人。
- 需要 VMware 的 VMnet1/VMnet8 或其它已启用的非 Wi-Fi 虚拟网卡来承载 `192.168.1.2/3`。
- 开/关热点会瞬断 Wi-Fi（热点和上网共用同一块无线网卡）；有 Clash/Mihomo TUN 时建议先关掉。
- 用外部 `cpxt` 裁判系统时不要启动本模拟器（会抢 `192.168.1.2`）。

## 4. 验证清单

1. AdapterSvr 日志出现 `S0Robot[1]`（脚本状态汇总会打印最后一行）：
   `<引擎目录>\RoboMasterEngine_Data\StreamingAssets\RMServer\AdapterSvr\logs\当天.log`
2. 机器人登录来源应该是 `192.168.137.x:60000`，不是 `172.x` / `10.x`。
3. 日志端窗口标题不带 `[offline]`（它要 UDP `62103`）。
4. `3333` 有 MQTT 连接；官方选手端 `Login : Success`。
5. 自定义客户端进程存在（WSL 里名字会被截断成 `RoboMasterClien`）。

## 5. 常见问题

| 现象 | 先看什么 |
|---|---|
| `S0Robot[0]` | 机器人是否连的是 `Local`；是否往 `192.168.1.2:62101` 发；登录来源是否被 NAT 改写 |
| 日志端 `[offline]` | UDP `62103` 是否由 `RMServer` 持有（不是 InfluxDB 的问题） |
| 官方选手端没画面 | 图传接收端 `VID_2CA3`、`RMClientDaemon` 是否先起、daemon 日志 |
| `3333` 没监听 | 官方选手端是否登录；是否以管理员运行 |
| 自定义客户端起不来 | 先 `bash run.sh --build`；看 `/tmp/cquqianli_client.log` |
| 端口被占 / 绑定失败 | 热点/ICS 还在；脚本默认会先停 ICS，`-NoHotspot` 模式不会 |
| 启动后 Wi-Fi 断一下 | 正常，热点切换共用射频；等它自己恢复 |

## 6. 目录结构

```text
start_local_sim.bat     唯一入口
config.ps1              路径 / 热点 / WSL 配置
README.md               本文件
scripts\
  start_local_sim.ps1   主逻辑
  setup_local_lan.ps1   建热点 + 把 192.168.1.2 放到热点网卡
  hotspot_watchdog.ps1  可选：每 5 秒检查并恢复热点
  start_diagnostics.ps1 可选：串口诊断 Web（:8765）
  legacy\               旧手动脚本 / 历史备份（仅参考）
services\               串口裁判协议解析（备用，不在主链路）
tools\influxdb\         influxd.exe（自行下载，见目录内 README.Download.md）
data\                   InfluxDB 数据（运行时生成）
logs\                   启动日志（运行时生成）
vendor\                 官方程序放这里（运行时自行放置，不提交）
```

## 7. 上传到 GitHub

仓库：`git@github.com:littleVangohn/qianli_mock_pacific.git`，分支 `start_all_local`。

首次上传或更新：

```bash
# 第一次
git clone -b start_all_local git@github.com:littleVangohn/qianli_mock_pacific.git
# 把「裁判系统服务器」整个文件夹放进仓库根目录
cd qianli_mock_pacific
git add .
git commit -m "Update local simulator"
git push origin start_all_local
```

如果仓库已经在本地，直接把本目录复制进去，再 `git add / commit / push` 即可。
`vendor\`、`tools\influxdb\influxd.exe`、`data\`、`logs\` 都已被忽略，不会上传。
