# AGENT.md — 交接：RoboMaster 本机模拟器（赛事服务 + 裁判系统）

> 写入时间：2026-10-20 01:45
> 位置：`D:\Pacific_doorlock\裁判系统服务器\AGENT.md`（项目根目录）
> 给下一个 Agent：先读这一份，再按需翻 `docs/` 里的细节文档。

---

## 0. 一句话现状

**根目录 `start_local_sim.bat` 双击即可启动整套链路**（赛事服务 + 裁判系统 + 图传 + 官方选手端 + 自定义客户端）。2026-10-20 00:29 实测全链路跑通：日志端 `[Online]`、`S0Robot[1]`、视频出图、MQTT 连接、电控 0x0310 以 50 Hz、300 字节 payload 正常到达并被自定义客户端解析。

**注意：本文写入时（01:43）所有进程都已停止**（用户手动关的）。需要时重新双击 bat。

> **2026-10-21 修正（重要）**：双击默认**不再停 ICS、不再开热点**。旧流程让 5 GHz
> Wi-Fi 上网和 2.4 GHz `Local` 热点共用同一块 Intel BE201；实测启动后 WLAN 反复
> 断开重连，最后“停止承载网络失败”，只能整机重启。现在把 `192.168.1.2/32` 和
> `192.168.1.3/32` 挂到 VMware VMnet1 上，引擎、InfluxDB、官方选手端照常工作。
> 只有物理机器人需要连 `Local` 时才加 `-WithHotspot`（会短暂断 Wi-Fi）。

---

## 1. 目录结构

```text
D:\Pacific_doorlock\裁判系统服务器\
  start_local_sim.bat        ← 根目录唯一文件，双击入口（自动提权）
  AGENT.md                   ← 本文件
  scripts\
    start_local_sim.ps1      主逻辑：停 ICS → 起引擎 → 恢复热点 → 起客户端
    setup_local_lan.ps1      只建热点 Local / 192.168.137.1 / 192.168.1.2
    hotspot_watchdog.ps1     热点守护（每 5 秒检查恢复）
    start_diagnostics.ps1    串口诊断 Web (:8765)
    legacy\                  旧手动脚本，仅参考，别用
  docs\
    AGENT.md                 旧版交接文档（2026-10-18，细节更全）
    README.md                项目说明
    重启链路.md              可复现的启动链路 + 成功记录
  services\
    referee_server.py        串口裁判协议解析服务（备用，不是主链路）
    index.html               诊断页
    tests\                   unittest
  tools\influxdb\influxd.exe
  data\influxdb\
  logs\
```

---

## 2. 双击 bat 会做什么（顺序不能改）

```text
1. 停掉旧的 Engine / RMServer / AdapterSvrS0 / 日志端 / Redis
2. 启动 InfluxDB（127.0.0.1:8086，复用已有实例）
3. 检查 UDP 62101/62102/62103 是否可绑定；可绑定就直接起引擎。
   默认不停 ICS/热点；只有 -WithHotspot 且端口被占用时才停 ICS。
4. 确保 192.168.1.2/32 和 192.168.1.3/32 挂在已启用的虚拟网卡
   （优先 VMware VMnet1；不动 WLAN）
5. 启动 RoboMasterEngine.exe（引擎自己拉起 RMServer / AdapterSvrS0 /
   RMServerLogClient / redis-server）
6. 等 TCP 15861/15862/64998/25862 监听，并确认 UDP 62101/62102/62103
   已被服务持有（端口没占住会自动重试一次）
7. 只有 -WithHotspot 才启动 Local 热点（192.168.137.1）；热点不再加
   192.168.1.2，避免同一个 IP 出现在两块网卡上
8. 起 RMClientDaemon（图传 COM5 + 图传 USB，cuda 硬解）
9. 起官方选手端 RoboMasterClient.exe，等 MQTT 3333 监听 + Login : Success
10. 起 WSL 自定义客户端（直接拉 ~/rm26-build/RoboMasterClient2025，
    不经过 run.sh，原因见 §6）
11. 打印进程 / 端口 / 引擎连接 / 日志端标题 / MQTT 连接
```

参数：

```bat
start_local_sim.bat -ServicesOnly   只起服务，不起任何客户端
start_local_sim.bat -DryRun         只检查不修改
start_local_sim.bat -WithHotspot    物理机器人需要 Local 时才加（会短暂断 Wi-Fi）
start_local_sim.bat -SkipHotspot    兼容旧参数，等同于默认行为
```

---

## 3. 为什么必须先停 ICS 再起引擎（最重要的坑）

Windows ICS（`SharedAccess`，本地热点 `Local` 依赖它）每次启动会**动态预留 62050–64998 整段 UDP/TCP**。

- 62101/62102 被 AdapterSvrS0 用来收机器人 Wi-Fi / 视频；62103 被 RMServer 用来给日志端的 UDP 登录。
- 端口被 ICS 占住时 `bind` 返回 WSAEACCES，但 DotNetty 的 `BindAsync` 没 await，**失败被静默吞掉**：进程在、TCP 通，但机器人永远 `S0Robot[0]`、日志端永远 `[offline]`。
- 已排除：`winnat` 停启、HNS/vmcompute 停启、`wsl --shutdown`、`netsh add excludedportrange`（动态预留会覆盖）。
- 已绑定的 socket 不会被随后启动的 ICS 抢走。默认流程**只检查端口，不主动停 ICS**：
  端口被占用时直接报错，让你先关热点；只有显式 `-WithHotspot` 才会停 ICS/开热点。
- 默认的 `192.168.1.2/1.3` 以 `/32` 挂在 VMnet1 上，不依赖热点。已验证
  `http://192.168.1.3:8086/health` 返回 200，访问外网仍走 WLAN/Meta。
  不要给这两个地址加 `-SkipAsSource`：实测会导致本机 ping/TCP 超时。

---

## 4. 关键端口

| 端口 | 所属 | 用途 | 正常判据 |
|---|---|---|---|
| UDP 62101 | AdapterSvrS0 | 机器人 Wi-Fi 数据入口 | `Get-NetUDPEndpoint` 能看到 |
| UDP 62102 | AdapterSvrS0 | 视频通道 | 同上 |
| UDP 62103 | RMServer | 日志端 UDP 登录 | 日志窗口标题不带 `[offline]` |
| TCP 15861/15862 | AdapterSvrS0 | 机器人 / 官方选手端 | 监听中 |
| TCP 64998 | AdapterSvrS0 | 引擎 S1 客户端 | 引擎→`192.168.1.2:64998` ESTABLISHED |
| TCP 25862 | RMServer | S0 GateSvr | 监听中 |
| TCP 3333 | 官方选手端 | **MQTT broker** | 监听中 |
| TCP 8086 | InfluxDB | HMS 数据 | `/health` 返回 200 |

日志端 `[offline]` **不是 InfluxDB 的问题**，是 62103 没绑上。InfluxDB 只是另一条告警。

---

## 5. 图传链路

```text
图传模块 → 接收端 USB-C（VID_2CA3&PID_1020，COM5/COM8 + libusb Vision）
        → RMClientDaemon（打开 video2015 串口 COM5 + 图传 USB，cuda 硬解）
        → 共享内存 → 官方选手端窗口
```

- **daemon 必须在官方选手端之前起**。daemon 不在，官方选手端只显示"图传未接入"，不报错。
- 判死活看 `RMClientDaemon\realtimelog_SerialPort\` 有没有**当天**文件，以及是否出现：
  `初始化图传解码dll成功 → 硬件解码器初始化成功: cuda → 打开video2015串口:COM5 → 打开图传USB设备成功`
- 接收端没插：无 `VID_2CA3`，daemon 只打 `video tick`。
- 接收端插好但没射频：daemon 每 5 秒打 `读取数据超时`，查发射端/信道/对频。
- 视频和 0x0310 走同一条射频链路但不同通道；视频正常不代表 0x0310 正常。

---

## 6. 自定义客户端（cquqianli_mock）

- 入口：WSL 里 `~/rm26-build/RoboMasterClient2025`（不在仓库里，构建产物）。
- **不要用 `run.sh` 起**：它第 3 步会在 WSL 里调 PowerShell 查 PnP 设备，实测会挂住，
  导致客户端永远起不来。`start_local_sim.ps1` 已改为直接拉起二进制。
- 需要的环境变量（bat 已自动设置）：
  - `RM_MQTT_BROKER=<WSL 默认网关>`（就是 Windows 主机，通常是 172.28.48.1）
  - `RM_MQTT_PORT=3333`
  - `RM_ENGINE_ARMOR_LOG_DIR=<引擎的 RM裁判系统日志文件夹3.0>`
- 进程名会被 Linux 截断成 `RoboMasterClien`（15 字符），`pkill -x` 要用这个短名。
- 官方选手端**必须已登录**，它的 MQTT broker 才会放行 ClientId `1`，否则返回
  `CONNACK(2) Identifier rejected`，日志原文是 `[MQTT] 选手端未登录服务器`。

---

## 7. 电控 0x0310 联调（2026-10-19～20 的主线）

### 7.1 协议

- 走**图传发射端 UART（921600 8N1）**，不经过裁判系统主控 MC02。
- 帧格式与 RoboMaster 串口协议一致：

```text
SOF 0xA5 | data_length(2B 小端) | seq | CRC8 | cmd_id 0x0310(2B 小端) | data | CRC16(2B 小端)
CRC8 : poly 0x31, init 0xFF, 覆盖前 4 字节
CRC16: CCITT-FALSE, poly 0x1021, init 0xFFFF, 覆盖 SOF..data
data : 定长 150 或 300 字节，前 11 字节是业务包，其余补 0
```

- 300 字节 payload → `data_length = 302 = 0x012E`，整帧 **309 字节**。
- data 前 11 字节布局（详见 `cquqianli_mock/docs/real_vehicle_integration/电控组最小数据对接文档.md`）：

| Byte | 内容 |
|---|---|
| 0 | `0x5A` 魔数 |
| 1 | `0x01` 版本 |
| 2 | 位域：bit0 摩擦轮、bit1 拨弹、bit2 允许发射、bit3 自动吊射、bit4 故障、**bit5 pose_valid**、**bit6 pitch_valid** |
| 3 | bit0-2 底盘模式（0 正常 / 1 跟随 / 2 小陀螺 / 3 保护），bit3 警告 |
| 4-5 | 云台相对底盘角 int16 小端，0.0001 rad |
| 6-7 | 云台世界角 int16 小端 |
| 8-9 | 炮管俯仰角 int16 小端 |
| 10 | seq 0-255 |

### 7.2 踩过的坑

1. **payload 只有 11 字节** → 图传模块直接丢，`st_uart_cmd_0x0310_cnt` 恒为 0。必须补到 150/300。
2. 电控工具截图里的线上字节是 `… 03 10 0B 5A 01 …`（大端命令 + 单字节长度），
   和标准帧不一致。用 `test_diankong/verify_frame.py --scan` 打印真实帧头对照。
3. `st_uart_cmd_0x0310_cnt` 是**图传模块固件自己的计数器**，比 PC 上任何软件都靠前。
   它等于 0 = 图传模块根本没收到合法帧，不是客户端解析问题。
4. 只看到视频正常、RC 数据在涨，不能推出 0x0310 正常——它们是同一射频链路的不同通道。

### 7.3 已验证成功（2026-10-20 00:34）

抓到的 300 字节 payload 开头：

```text
5a 01 60 08 22 f7 2f 04 04 f6 d9
      │  │  └─┬─┘ └─┬─┘ └─┬─┘
      │  │ -13.0°  6.14° -14.64°
      │  └ mode=0（正常）+ 警告位
      └ 0x60 = pose_valid=1, pitch_valid=1
```

seq 逐帧递增，daemon 日志 `recv 0x0310 length:300！` 持续 50 Hz。
VT 计数器 `st_uart_cmd_0x0310_cnt` 从 0 涨到 3 万+。

### 7.4 联调工具包

`D:\Pacific_doorlock\test_diankong\`（给电控用，独立于本项目）：

| 文件 | 作用 |
|---|---|
| `README.md` | 接线、三步调试流程、帧格式、排障表 |
| `rm_frame.py` | CRC8/CRC16、组帧/解帧、payload 编解码 |
| `send_0x0310.py` | PC + USB-TTL 直接往图传发射端 UART 发 0x0310 |
| `verify_frame.py` | 监听电控板实际输出，逐帧校验；`--scan` 打印自定义帧头 |
| `gen_payload.py` | 生成 300/150 字节 payload 的 hex + C 数组 |
| `watch_vt.py` | 在官方选手端电脑上实时看 `st_uart_cmd_0x0310_cnt` |
| `frame_sample_300.txt` | 一帧标准参考帧（309 字节） |

---

## 8. 常用排查命令

```powershell
# 全栈状态
Get-Process RoboMasterEngine,RMServer,AdapterSvrS0,RMServerLogClient,RoboMasterClient,RMClientDaemon,redis-server,influxd -EA SilentlyContinue | ft ProcessName,Id
Get-NetTCPConnection -State Listen | ? LocalPort -in 15861,15862,64998,25862,3333
Get-NetUDPEndpoint | ? LocalPort -in 62101,62102,62103
Get-Process RMServerLogClient | select MainWindowTitle      # 看 [Online]/[offline]

# 机器人是否注册
Select-String -Path "D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine_Data\StreamingAssets\RMServer\AdapterSvr\logs\2026-10-20.log" -Pattern 'Translator count' -Tail 1

# 图传 daemon 是否正常
Get-ChildItem "...\RMClientDaemon\realtimelog_SerialPort" | sort LastWriteTime -desc | select -first 1
# 里面应有：打开video2015串口:COM5 / 打开图传USB设备成功

# 0x0310 是否到达
Get-Content "$env:USERPROFILE\AppData\LocalLow\DJI\RoboMasterClient\Player.log" -Tail 10 | Select-String '0x0310_cnt'
```

---

## 9. 已知问题 / 未完成

1. **`start_local_sim.ps1` 里 WSL 客户端的启动**：从 PowerShell 调用 `wsl.exe` 时，命令行里的
   中文路径可能按控制台代码页转换出错导致命令静默失败；当前实现带重试，并且已把
   `$ErrorActionPreference` 局部改成 `Continue`（wsl.exe 会往 stderr 打 localhost 代理提示）。
   如果下次仍起不来，检查 `tmp` 下是否有旧的 launcher 脚本干扰，或直接在 WSL 里手动执行
   `start_local_sim.ps1` 里拼接的那条 `bash -lc` 命令验证。
2. `scripts/legacy/start_referee_stack.ps1` 是旧流程（先起服务再建热点），**会失败**，不要用。
3. 根目录新旧两份 AGENT：`docs/AGENT.md` 是 10-18 的历史细节（端口表、S0Robot 排查法仍然有效），
   本文件是 10-20 的当前状态。以本文件为准。
4. `services/referee_server.py` 是早期串口直连方案，不在当前主链路上，别误以为它在跑。

---

## 10. 绝对不要做的事

- 不要在引擎/机器人已连上时重启热点或重复跑 `setup_local_lan.ps1`（机器人会掉线）。
- 不要同时开两份 RMServer / AdapterSvrS0 / 引擎。
- 不要删用户目录；不确定就问（历史教训：删过一次用户正在克隆的仓库）。
- 不要修改 `cquqianli_mock` 的源码（用户明确要求）；只允许改 `run.sh` 或本项目脚本。
- 不要把 `[offline]` 当成 InfluxDB 问题去修——先查 UDP 62103。

---

## 11. 相关记忆（memory 目录）

- `ics-reserves-rm-udp-ports` — 本文 §3 的根因与顺序
- `rm-log-offline-is-udp-62103` — `[offline]` 的真相
- `rm-video-daemon-must-start-first` — daemon 必须先起
- `official-client-is-mqtt-broker` — 3333 是官方选手端自己
- `official-client-needs-elevation` — 官方选手端要提权（Login.bin ACL）
- `vt-video-diagnosis-logs` — 图传排查看哪两个日志
- `referee-loopback-port-hijack` — 54998/64998 在动态端口区间
- `cquqianli-mock-renamed` — 仓库改名历史
