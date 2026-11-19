# AGENT.md — 裁判系统本地栈交接

> 更新时间：2026-10-18 20:05
> 目录已整理：根目录唯一入口 `start_local_sim.bat`；脚本在 `scripts/`，文档在 `docs/`，服务在 `services/`，InfluxDB 在 `tools/` + `data/`。
> 现状一句话：本机模拟器的正确启动顺序已固化为“停 ICS → 起引擎 → 恢复热点”，日志端 `[Online]`、`S0Robot[1]`、图传已正常出图。`[offline]` 的真实原因见 §11，不是 InfluxDB。
>
> **2026-10-21 起默认流程已改（重要）**：双击不再停 ICS/开热点，`192.168.1.2/1.3`
> 以 `/32` 挂在 VMnet1 上。只有物理机器人需要 `Local` 时才用 `-WithHotspot`。
> 下方“停 ICS → 起引擎 → 恢复热点”是旧流程，仅作排障/物理机器人参考。

---

## 1. 目标链路

```text
机器人主控（电控/裁判系统）
  └─ Wi-Fi 连到本机热点 Local（2.4GHz，密码 12345678）
       └─ UDP 发到 192.168.137.1:62101
            └─ AdapterSvrS0（本机，RMServer 的 GateSvr）
                 ├─ RMServer（赛事服务/GameSvr）
                 │    └─ RoboMasterEngine.exe（裁判端/引擎 UI）
                 └─ 官方选手端 RoboMasterClient.exe（15862）
                      ├─ MQTT broker :3333
                      └─ 图传接收端 USB-C → 视频
                           └─ cquqianli_mock 自定义客户端
```

关键点：

- 本地热点 `Local` 在 **WLAN 3** 上，热点 IP `192.168.137.1`，并额外挂了赛事引擎要求的 `192.168.1.2/24`。
- 手机热点在 **WLAN**（`172.20.10.3`），只负责上网，和本地栈不冲突。
- 机器人要连的是 `Local`，不是手机热点；机器人 IP 应为 `192.168.137.x`。
- 官方选手端的视频来自 **图传接收端 USB-C**，不经过电控 UART，也不经过 RMServer；但官方选手端要登录成功后才显示画面。
- 电控的 0x0310 自定义数据走 **图传发射端 UART → 图传链路 → 接收端 → 官方选手端 → MQTT**，不经过裁判系统主控 MC02。

---

## 2. 当前进程与端口（以 `Get-Process` / `netstat` 为准）

当前观察到的进程：

| 进程 | 作用 |
|---|---|
| `RoboMasterEngine.exe` | 裁判端/引擎 UI，自动拉起服务 |
| `RMServer.exe` | 赛事服务/游戏服务 |
| `AdapterSvrS0.exe` | 机器人/客户端接入适配层 |
| `RMServerLogClient.exe` | 日志系统窗口（标题 `[offline]` 是 UDP 62103 登录失败，见 §11） |
| `RoboMasterClient.exe` | 官方选手端 |
| `redis-server.exe` | RMServer 的 Redis |

端口：

| 端口 | 所属 | 用途 |
|---|---|---|
| `25862` TCP / `52102` UDP | RMServer | S0 GateSvr |
| `54998` TCP / `54999` UDP | RMServer | S1 GateSvr |
| `55000` HTTP | RMServer | HTTP |
| `15861` TCP | AdapterSvrS0 | S0 机器人 TCP |
| `15862` TCP / `15863` UDP | AdapterSvrS0 | S0 客户端（官方选手端） |
| `62101` UDP | AdapterSvrS0 | **机器人 Wi-Fi 数据入口** |
| `62102` UDP | AdapterSvrS0 | 机器人视频通道 |
| `64998` TCP / `64999` UDP | AdapterSvrS0 | S1 客户端（裁判端/引擎） |
| `6379` | Redis | RMServer 缓存 |
| `3333` | 官方选手端 | MQTT broker |

---

## 3. 启动顺序（重要，别照旧脚本硬跑）

### 最推荐：双击 `start_local_sim.bat`

根目录的 `start_local_sim.bat` 会自动提权，并按“停 ICS → 起引擎（引擎自己拉起服务）→ 恢复热点”的顺序执行，已包含端口自检和一次自动重试。**默认会继续启动图传 daemon、官方选手端和 WSL 自定义客户端**；只起服务用 `-ServicesOnly`。完整链路和本次成功记录见 `docs/重启链路.md`。手工排障时再按下面的步骤来。

### 手工：让引擎自己拉起服务

1. 确认本地 LAN 已就绪：`WLAN 3` 上有 `192.168.137.1` 和 `192.168.1.2/24`。
   - 如需重新建立：管理员 PowerShell 跑 `scripts\setup_local_lan.ps1`，**不要在引擎已经连上时跑**。
2. 直接启动：
   ```powershell
   & 'D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine.exe'
   ```
   引擎会自动拉起 `RMServer`、`AdapterSvrS0`、`RMServerLogClient`、`redis-server`。
3. 等 `15861/15862/64998` 监听，并确认引擎到 `192.168.1.2:64998` 是 `ESTABLISHED`。
4. 启动官方选手端：
   ```powershell
   & 'D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterClient 12.0.0.213_Student\RoboMasterClient 12.0.0.213_Student\RoboMasterClient\RoboMasterClient.exe'
   ```
   选 `R1 - Hero` 点登录，日志应出现 `Login : Success`。
5. 官方选手端登录成功后，再跑 `cquqianli_mock`：
   ```bash
   bash /mnt/d/Pacific_doorlock/cquqianli_mock/run.sh
   ```

### 为什么不能直接照 `start_referee_stack.ps1` 从头跑

- 脚本是 **先起 RMServer，再跑 `setup_local_lan.ps1`**。如果 `192.168.1.2` 还没就绪，RMServer 会启动后退出，AdapterSvr 跟着退出，结果就是 `=== result ===` 里两个 `NOT RUNNING`。
- 脚本最后会启动引擎；引擎自己也会拉起服务。**手动服务和引擎自动服务混在一起，会出现重复/互踢**，表现为“服务器时不时断联”。
- 当前这台机器上，最稳的方式是：**本地 LAN 先就绪 → 只启动引擎，让它自己管理服务**。

### 不要做的事

- 不要在引擎/机器人已经连上时跑 `scripts\setup_local_lan.ps1`、`scripts\legacy\start_referee_stack.ps1` 或 `scripts\hotspot_watchdog.ps1`：它们会重启热点/ICS，机器人会掉线。
- 不要同时开多个 `RMServer` / `AdapterSvrS0` / `RoboMasterEngine`。
- 不要杀掉 `cx2520`（ANSYS Fluent）等无关进程。

---

## 4. `S0Robot[0]`（2026-10-18 19:05 已解决，根因见 §11）

AdapterSvr 日志：

```text
D:\...\RoboMasterEngine 12.0.0.176_Student\...\RoboMasterEngine_Data\StreamingAssets\RMServer\AdapterSvr\logs\2026-10-18.log
```

当前一直是：

```text
Translator count 2 : S0Robot[0] S0Client[1] S1Client[1] UnKnown[0] Fps:66
```

含义：

- `S0Client[1]`：官方选手端已连上；
- `S1Client[1]`：裁判端/引擎已连上；
- `S0Robot[0]`：**没有收到机器人数据**。

17:54 的时候机器人是好的：

```text
[LOGIN][V1]: account:s0unit_robot_1_2, uid:654895545, ...
             ip:192.168.137.174 port:60000 key:udp_wifi
Translator count 4 : S0Robot[1] S0Client[2] S1Client[1]
```

但 18:07 本地服务重启后，机器人没有重新注册上来，日志里也没有新的 `[LOGIN]`。

### 排查顺序

1. 机器人 Wi-Fi 确实连的是 `Local`，IP 是 `192.168.137.x`。
   - 看 Windows 热点客户端列表/`Get-NetNeighbor`，确认不是连到手机热点。
2. AdapterSvr 确实在听 UDP 62101：
   ```powershell
   netstat -ano -p UDP | findstr 62101
   ```
   应属于 `AdapterSvrS0.exe`。
3. 抓 `192.168.137.1:62101` 的 UDP 包：如果完全没有机器人来的包，问题在机器人侧（服务器地址/端口配置、登录状态、Wi-Fi 重连），不在服务端。
4. 机器人主控/图传链路断电重连一次，等它重新登录 Local。
5. 确认机器人没有指向真实裁判系统/别的赛事服务器；本地栈只认发到 `192.168.137.1:62101` 的机器人。
6. 如果机器人有包但 `S0Robot` 仍为 0，看 AdapterSvr 日志里的 `[LOGIN]` / `loginAck`；17:54 曾出现 `loginAck:Nothing`，说明登录请求到了但 ack 没完成，可对比机器人侧日志。
7. 引擎操作面板里可以点 **“重置比赛”** / **“15s自检”**，把比赛状态从 `room` 拉起来；但这不会替代机器人注册。

**验收标志**：AdapterSvr 日志出现 `S0Robot[1]`，官方选手端顶部机器人槽不再是黑的，视频区才有内容。

---

## 5. 日志系统 `offline` 的真相（2026-10-18 修正：见 §11）

`RMServerLogClient` 标题栏 `[offline]` 不是数据链路故障。它要连：

- InfluxDB：`192.168.1.3:8086`
- MySQL 同步：`192.168.1.3:3306`

当前本机没有这两个服务，RMServer 的 stdout 里也能看到：

```text
InfluxDB 连接已断开或未初始化...
[MySqlSync] MySQL connection failed [192.168.1.3:3306/robomasterdb]...
```

它们只影响日志/数据同步，不影响 RMServer/AdapterSvr/机器人链路。要消除 `offline` 可以起 `D:\Pacific_doorlock\裁判系统服务器\influxdb` 里的 InfluxDB，并监听 `192.168.1.3:8086`，但这不是当前的阻塞项。

---

## 6. 官方选手端与视频

- 官方选手端日志：
  ```text
  C:\Users\ty\AppData\LocalLow\DJI\RoboMasterClient\Player.log
  ```
  当前已出现：
  ```text
  [Game] Login : Success
  ```
- 之前登录失败的原因是 `Login.bin` 目录 ACL 没给当前用户写权限；已用
  ```bash
  bash /mnt/d/Pacific_doorlock/cquqianli_mock/run.sh --fix-acl
  ```
  修复，`ty` 现在有 `(OI)(CI)(M)`，写测试 `WRITE OK`。
- 图传接收端已枚举：
  - `DJI USB VCOM For Protocol (COM5)`
  - `DJI USB VCOM For Debug (COM8)`
- 官方选手端启动时会起 `VideoSerialPortManager` / `Video Serial Port 2025`；VT 模块在赛事服务里显示正常。
- 现在视频区是灰的，优先原因是 `S0Robot[0]`（机器人没注册/比赛未起来），不是 VT 链路断了。等 `S0Robot[1]` 后再判断视频；如果那时还灰，再查 VT 相机/发送端和官方选手端视频端口。
- 图传视频走接收端 USB-C，不走电控 921600 UART；电控 UART 只跑 21B 遥控帧和 0x0310。

---

## 7. 自定义客户端（cquqianli_mock）

- 入口：`bash /mnt/d/Pacific_doorlock/cquqianli_mock/run.sh`
- 官方选手端必须已登录，否则它的 MQTT broker 会拒绝所有 ClientId（我们测过 1–7/101/102/随机 ID 全是 CONNACK 2）。
- `run.sh` 已导出 `RM_MQTT_BROKER` / `RM_MQTT_PORT`，避免构建目录里的旧 config 指错主机。
- 这台笔记本是 1440x900 + 200% 缩放，跑客户端时用 `RM_WINDOWED=1` 才能看到右侧 HUD。
- 电控联调文档：`cquqianli_mock/docs/real_vehicle_integration/电控组最小数据对接文档.md`
- 联调用例：`cquqianli_mock/test/custom_status_cases.md`

---

## 8. 关键路径速查

| 对象 | 路径 |
|---|---|
| 引擎 | `D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine 12.0.0.176_Student\RoboMasterEngine.exe` |
| RMServer | `<引擎>\RoboMasterEngine_Data\StreamingAssets\RMServer\Server\RMServer.exe` |
| AdapterSvr | `<引擎>\RoboMasterEngine_Data\StreamingAssets\RMServer\AdapterSvr\AdapterSvrS0.exe` |
| AdapterSvr 日志 | `<引擎>\RoboMasterEngine_Data\StreamingAssets\RMServer\AdapterSvr\logs\2026-10-18.log` |
| 引擎日志 | `C:\Users\ty\AppData\LocalLow\DJI\RoboMasterEngine\Player.log` |
| 官方选手端 | `D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterClient 12.0.0.213_Student\RoboMasterClient 12.0.0.213_Student\RoboMasterClient\RoboMasterClient.exe` |
| 官方选手端日志 | `C:\Users\ty\AppData\LocalLow\DJI\RoboMasterClient\Player.log` |
| 一键启动（双击） | `D:\Pacific_doorlock\裁判系统服务器\start_local_sim.bat` |
| 主启动脚本 | `D:\Pacific_doorlock\裁判系统服务器\scripts\start_local_sim.ps1` |
| 本地 LAN 脚本 | `D:\Pacific_doorlock\裁判系统服务器\scripts\setup_local_lan.ps1` |
| 旧手动栈脚本 | `D:\Pacific_doorlock\裁判系统服务器\scripts\legacy\start_referee_stack.ps1`（仅参考） |
| 本目录 README | `D:\Pacific_doorlock\裁判系统服务器\docs\README.md` |

---

## 9. 已确认/已修复

- RMServer 手动/引擎自动启动后都能 `GSGate Init Succ`，监听 `25862/52102/54998/54999/55000`。
- AdapterSvr 能监听 `15861/15862/15863/62101/62102/64998/64999`。
- 引擎到 `192.168.1.2:64998` 已 `ESTABLISHED`，日志里 `[JUDGE] 发送GM命令` 不再带“裁判端未登录”。
- 官方选手端 `Login : Success`；`Login.bin` ACL 已修。
- VT 接收端 COM5/COM8 已枚举，VT 模块在赛事服务里显示正常。
- 0x0310/图传路径、Byte 6–7 云台世界角等文档已修正（见 `cquqianli_mock/docs/real_vehicle_integration/`）。

## 10. 下一个接手的人先做这三件事

1. 看 AdapterSvr 日志最后几行，确认 `S0Robot[0]` 还是 `[1]`。
2. 确认机器人真的连在 `Local`（192.168.137.x）并往 `192.168.137.1:62101` 发包。
3. 不要在引擎已连上时重启热点/栈；先解决机器人注册，再谈视频。

---

## 11. 2026-10-18 19:00 复盘：`[offline]` 与 `S0Robot[0]` 的共同根因

### 结论

`RMServerLogClient` 标题里的 `[offline]` **不是 InfluxDB**，而是它向 `127.0.0.1:62103` 发
`ClientLoginReq` 失败（反编译 `MainWindow.LoadConfig` 确认：端口硬编码 `62103`，`userid=1` → `RMlogUserid=151`）。
同一时刻 AdapterSvr 的 UDP `62101`（机器人 Wi-Fi）/`62102`（视频）也没绑上，所以机器人注册不上。

根因：**Windows ICS（`SharedAccess`，本地热点 `Local` 依赖它）动态预留了约 `62050–64998` 整段端口**。
端口落在保留段内时 `bind` 直接返回 WSAEACCES；DotNetty 的 `BindAsync` 没有 await，
所以 RMServer 仍会打印 `S0 UDP LogSvr Listen in 62103`，但实际没有监听。

已排除：`winnat` 停启、`hns`/`vmcompute` 停启、`wsl --shutdown`、命令沙箱、
`netsh int ipv4 show excludedportrange`（列表里看不到这段）。
在 ICS 已运行时补 `netsh ... add excludedportrange ... 62101 3` **无效**（动态保留会覆盖）。

### 恢复顺序（必须按这个顺序）

```powershell
# 1) 关掉引擎和所有服务
Stop-Process -Name RoboMasterEngine -Force
Get-Process RoboMasterClient,RMClientDaemon,RMClientAssist_*,RMServerLogClient,AdapterSvrS0,RMServer,redis-server -EA SilentlyContinue | Stop-Process -Force

# 2) 停 ICS，等到 62103 能 bind
Stop-Service SharedAccess -Force

# 3) 起引擎（自动拉起 RMServer/AdapterSvr/日志端/Redis）
& '<引擎>\RoboMasterEngine.exe'

# 4) 确认 62101/62102 属 AdapterSvr、62103 属 RMServer
Get-NetUDPEndpoint | ? LocalPort -in 62101,62102,62103

# 5) 再恢复热点和 192.168.137.1
& 'D:\Pacific_doorlock\裁判系统服务器\scripts\setup_local_lan.ps1'
```

已绑定的 socket 不会被随后启动的 ICS 抢走。

### 验收

- `Get-Process RMServerLogClient | select MainWindowTitle` → 不带 `[offline]`。
- AdapterSvr 日志：`Translator count 3 : S0Robot[1] S0Client[1] S1Client[1]`。
- `[LOGIN][V1]: account:s0unit_robot_1_2 ... ip:192.168.137.125`。

### 图传

软件侧已就绪（daemon 硬解 cuda 成功、官方选手端已登录、自定义客户端已连 MQTT），
但 `Get-PnpDevice | ? InstanceId -match 'VID_2CA3'` 全部 `Present=False`，系统里没有 COM5/COM8；
daemon 日志只有 `video tick`，没有 `打开video2015串口:COM5` / `打开图传USB设备成功`。
2026-10-18 晚：接收端已插回（`VID_2CA3&PID_1020`，COM5/COM8），图传已正常出图。若再次无画面，先确认设备 `Present=True`，再按 daemon → 官方选手端 → 自定义客户端的顺序重启。
