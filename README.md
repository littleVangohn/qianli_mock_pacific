# cquqianli_mock

RoboMaster 2026 自定义客户端（Qt 6 / C++17 / QML），运行在上位机 NUC 的 WSL Ubuntu 22.04。
数据来自官方选手端的 MQTT broker（:3333），图传来自官方选手端的 UDP（:3334）。
下位机电控的状态经 `0x0310` → 图传链路 → MQTT `CustomByteBlock` 进入客户端；
键鼠控制沿反方向经 MQTT `KeyboardMouseControl` → 图传 → 21 字节遥控帧下发到下位机电控。

## 快速开始

完整链路还依赖两套官方程序（本仓库不包含，需要自行下载安装）：

1. **官方赛事服务器**（RoboMasterEngine / 裁判系统栈）—— 提供比赛数据。
2. **官方选手端 RoboMasterClient** —— 同时充当 MQTT broker（`:3333`），并把图传和
   `CustomByteBlock` 转发给自定义客户端。

先按官方文档把赛事服务器和官方选手端启动起来，然后：

```bash
# 构建（产物固定为 ~/rm26-build/RoboMasterClient2025）
bash run.sh --build

# 启动自定义客户端（自动复用已在运行的 broker / daemon）
bash run.sh

# 一次性授权，之后启动官方选手端不再弹 UAC
bash run.sh --fix-acl
```

官方选手端已在运行时，`run.sh` 会直接复用它的 3333 端口和已启动的图传 daemon，
只补启自定义客户端；官方选手端没起时，`run.sh` 会尝试拉起它。

构建依赖：CMake ≥ 3.21、Ninja、GCC、Qt 6（Core/Gui/Widgets/Quick/QuickControls2/
Multimedia/SerialPort/Svg）、protobuf、FFmpeg（avcodec/avformat/avutil/swscale）、
paho-mqtt3c、abseil。

## 文件树

```text
cquqianli_mock/
├── README.md                 本文件
├── run.sh                    一键启动 / 构建 / 授权
├── docs/
│   └── 机械臂通信协议.md      给电控的机械臂下行接口说明
└── upstream/
    ├── CMakeLists.txt        客户端构建入口
    ├── config.example.json   配置模板（首次运行复制为 config.json）
    ├── cmake/                CMake 辅助模块
    ├── resources/            图标、图片、模型、音效、样式（QRC 资源）
    ├── resources.qrc         资源清单
    └── src/
        ├── main.cpp
        ├── config/           配置读取（支持 RM_MQTT_* 环境变量覆盖）
        ├── core/             比赛数据、协议结构、装甲日志监听
        ├── network/          MQTT / protobuf / CustomByteBlock / 图传接收
        ├── ui/               主窗口、面板、快捷键与输入转发
        ├── widgets/          自定义控件
        ├── qml/              QML 界面（CustomUI、Tactical）
        ├── simulator/        无实车时的模拟数据源
        └── devhooks/         开发调试钩子
```

`upstream/config.json` 是本机现场配置（IP / 机器人编号），已被 `.gitignore`
忽略；首次运行 `run.sh` 会从 `config.example.json` 自动生成。

## 数据来源

自定义客户端不直接连下位机电控，也不直接连赛事服务器，比赛数据和视频都经过官方选手端：

```text
比赛数据：裁判系统栈 ──► 官方选手端 ──MQTT :3333──► 自定义客户端
视频：    图传接收端   ──► 官方选手端 ──UDP :3334───► 自定义客户端
```

官方选手端自己就是 MQTT broker。它不在，自定义客户端连 3333 都连不上；
图传 daemon 晚于官方选手端启动时，共享内存对不上，需要重启官方选手端。

## 两条链路（下位机电控 ↔ 上位机 NUC）

规则里自定义控制器与自定义客户端已经合并成一套，所以整条自定义链路只有两条，
都是上位机 NUC（运行自定义客户端）与下位机电控之间的上下行，以图传模块为中转：

- 链路 A（上行）：下位机电控 → 图传 → 上位机 NUC，`0x0310` 状态包。
- 链路 B（下行）：上位机 NUC → 图传 → 下位机电控，键鼠控制。

官方选手端也跑在上位机 NUC 上（Windows 侧），自定义客户端在它的 WSL 里，两者通过本机 MQTT 连接。

### 链路 A（上行）：下位机电控 → 图传 → 上位机 NUC（0x0310）

```text
下位机电控
  └─ 图传 UART 921600 ── 0x0310（payload 定长 150/300 B，≤50 Hz）
       └─ 图传发射端 VT03/VT13
            └─ 图传无线链路
                 └─ 图传接收端 USB-C
                      └─ 上位机 NUC：官方选手端 RoboMasterClient.exe
                           └─ 内嵌 MQTT broker :3333
                                └─ topic CustomByteBlock
                                     └─ protobuf { bytes data = 1 }
                                          └─ data = 下位机原始字节
                                               └─ NetworkManager::parseCustomByteBlock
```

- 电控只往**图传发射端 UART** 写 `0x0310`（921600 8N1），不经过裁判系统主控 MC02；
  MC02 只负责供电、机器人 ID 和图传对频。
- `0x0310` 单帧 payload 定长 150 B（初始协议）或 300 B（V1.3），频率上限 50 Hz。
  我们的状态包只占 payload 开头的 11/12 字节，其余填充不影响识别。
- 官方选手端把车端自定义块桥接成 MQTT `CustomByteBlock`；protobuf 外壳只有
  `bytes data = 1`，客户端取出 `data` 后再解析状态包。
- 客户端分流规则：`data` 长度 ≥ 11 且首字节为 `0x5A` → 状态包；否则按 H.264 视频分片处理。
- 客户端按 `seq` 去重，重复包和乱序旧包直接丢弃；连续 300 ms 没有新 `seq` 判定失联，
  UI 保留最后值并灰显。

### 电控状态包（链路 A 的 payload）

经 MQTT 主题 `CustomByteBlock` 传输，小端序、紧凑排列，无保留字节。
v1 为 11 字节，v2 为 12 字节（多一个模块状态字节），两种都接受。

| 字节 | 类型 | 字段 | 说明 |
| --- | --- | --- | --- |
| 0 | uint8 | magic | 固定 `0x5A`，用于和同通道视频分片区分 |
| 1 | uint8 | version | `1` 或 `2` |
| 2 | uint8 | friction_status | bit0 摩擦轮就绪，bit1 拨弹轮动作，bit2 允许发射，bit3 自动吊射启用，bit4 电控故障，bit5 姿态可信，bit6 俯仰可信 |
| 3 | uint8 | chassis_status | bit0-2 底盘模式（0 正常 / 1 跟随 / 2 小陀螺 / 3 保护），bit3 底盘警告 |
| 4-5 | int16 | gimbal_chassis_angle | 云台相对底盘偏角，单位 0.0001 rad |
| 6-7 | int16 | gimbal_yaw | 云台世界角，单位 0.0001 rad，逆时针为正 |
| 8-9 | int16 | barrel_pitch | 炮管俯仰角，单位 0.0001 rad，抬炮为正 |
| 10 | uint8 | seq | 包序号，每包 +1，255 回绕；客户端用它去重和判断新鲜度 |
| 11 | uint8 | module_status | 仅 v2：bit0 底盘上电，bit1 云台上电，bit2 发射机构上电，bit3 RFID 读卡，bit4 遥控器在线 |

以上角度均为 `int16`，客户端按 `值 / 10000 * 180 / π` 转成角度。
底盘世界角不传，客户端用 `gimbal_yaw - gimbal_chassis_angle` 本地推导。

发送示例（Python）：

```python
import struct

# v1：11 字节，version=1
pkt = struct.pack('<BBBBhhhB',
                  0x5A, 1, friction_status, chassis_status,
                  gimbal_chassis_angle, gimbal_yaw, barrel_pitch, seq)

# v2：12 字节，version=2，末尾补模块状态
pkt = struct.pack('<BBBBhhhBB',
                  0x5A, 2, friction_status, chassis_status,
                  gimbal_chassis_angle, gimbal_yaw, barrel_pitch, seq,
                  module_status)
```

注意：状态包必须至少 11 字节，且首字节为 `0x5A`；否则会被当作视频分片。
建议直接发 12 字节 v2，这样模块灯也有数据。

### 链路 B（下行）：上位机 NUC → 图传 → 下位机电控（键盘/鼠标）

```text
上位机 NUC：自定义客户端捕获键鼠
  └─ MQTT KeyboardMouseControl（protobuf，QoS 1，不等 ACK）
       └─ 官方选手端 RoboMasterClient.exe
            └─ 图传接收端 USB-C
                 └─ 图传无线链路
                      └─ 图传发射端 VT03/VT13
                           └─ 图传 UART 921600 ── 21 字节遥控帧
                                └─ 下位机电控
```

- 客户端只发 MQTT protobuf，不拼 21 字节帧；帧由官方选手端/图传发射端生成。
  键鼠控制走官方 21 字节遥控帧；机械臂姿态走 `0x0311`（见下）。
- protobuf 字段：`mouse_x/y/z`、`left/right/mid_button_down`、`keyboard_value`。
- 21 字节帧：921600 8N1，帧头 `A9 53`，CRC-16/CCITT-FALSE；客户端只提供
  `mouse_x/y/z`、鼠标按键状态和 `keyboard_value`，不参与拼帧。
- 发射端约每 14 ms 输出一帧（约 71 Hz），空闲也发；与链路 A 的 `0x0310` 全双工，
  两个方向互不排队。
- 客户端有活动时按 13 ms 最小间隔冲刷（约 75 Hz），静止不发；松手或打开面板时
  先发一帧全零（中性帧），面板打开期间暂停。
- QoS 1，但不等 ACK、不重传。链路抖动会静默丢帧，电控必须自己做失联保护。
- 左键是电平开火请求（按住 = 持续请求），电控按热量/弹量/摩擦轮闭锁，并通过链路 A
  的 `fire_permitted` 回传。
- 鼠标量是单帧增量，客户端发送前已乘好灵敏度；电控不要再乘系数，也不要跨帧累加。
- 客户端只在已登录、非战术模式、无阻挡面板时捕获键鼠；其他情况不发，并补一帧全零。

### 键位设置（链路 B 的 keyboard_value）

客户端只负责把键位打包成 16 位掩码，**电平/上升沿语义由电控实现**。
`keyboard_value` 为 `uint16` 小端：

| bit | 键 | 我们的用途 | 电控处理 |
| --- | --- | --- | --- |
| 0 | W | 前进 | 电平，按住前进 |
| 1 | S | 后退 | 电平，按住后退 |
| 2 | A | 左移 | 电平，按住左移 |
| 3 | D | 右移 | 电平，按住右移 |
| 4 | Shift | 加速（左右 Shift 同一位） | 电平；操作手只用左 Shift |
| 5 | Ctrl | 客户端快捷键修饰键 | 忽略 |
| 6 | Q | 客户端本地调试 | 忽略 |
| 7 | E | 自动吊射开关 | 上升沿切换 |
| 8 | R | 制动 | 电平，按住刹车；与 W/S/A/D 同按时制动优先 |
| 9 | F | 本地飞镖面板 | 忽略 |
| 10 | G | 跟随 ↔ 小陀螺 | 上升沿切换，切换时清掉自旋状态 |
| 11 | Z | 机械臂自定义控制 ↔ 视觉自动控制切换 | 可忽略；机械臂模式以 `0x0311` 的 `relative_time` 为准 |
| 12 | X | 换弹种 17 ↔ 42 | 上升沿切换 |
| 13 | C | 小陀螺左旋 | 上升沿启停；仅在底盘模式 2 下有效 |
| 14 | V | 小陀螺右旋 | 上升沿启停；仅在底盘模式 2 下有效 |
| 15 | B | 大地图本地标记 | 忽略 |

鼠标字段：

| 输入 | protobuf 字段 | 语义 | 电控处理 |
| --- | --- | --- | --- |
| 左键 | `left_button_down` | 按住 = 持续开火请求 | 按热量/弹量/摩擦轮闭锁 |
| 右键 | `right_button_down` | 当前未分配用途 | 忽略 |
| 中键 | `mid_button_down` | 共享标点 | 可忽略 |
| 水平移动 | `mouse_x` | 单帧增量，右正 | 单帧消费，不累加 |
| 垂直移动 | `mouse_y` | 单帧增量，上/前正 | 单帧消费，不累加 |
| 滚轮 | `mouse_z` | 单帧增量，上正 | 本键位不用 |

本地快捷键（不进 `keyboard_value`）：`1/2/3`（视角）、`P`（设置/登录）、`Tab`、
`~`（伤害面板）、`M`、`O`、`I`、`K`、`H`、`F12`、`Esc`。

- 电平键：W/S/A/D/Shift/R，按住为 1，松开为 0。
- 上升沿键：E/X/G/C/V，只在 0 → 1 的那一帧触发一次，不要按“这一帧是 1”反复触发。
- G 在底盘模式 `1=跟随` 和 `2=小陀螺` 之间切换；保护模式 `3` 下忽略 G/C/V。
- 相比旧键位：制动由 Space 改为 R，自动吊射由 T 改为 E，换弹由右 Shift 改为 X；
  ↑/↓ 已取消，炮管俯仰只用鼠标 Y。
- 右 Shift 与左 Shift 共用 bit4，会被当成加速，换弹只用 X。
- 客户端重启后 E/X 状态会与车端不一致，操作手各按一次对齐；失联保护触发时，
  电控应复位为自动吊射关、17 mm 弹。

### 机械臂（0x0311）

给电控的完整接口说明见 [docs/机械臂通信协议.md](docs/机械臂通信协议.md)（解析示例、失联保护、
待确认事项都在里面）。要点：

机械臂姿态为 18 字节紧凑结构，packed、小端，客户端按 **50 Hz 持续发送**：

| 偏移 | 字段 | 类型 | 说明 |
| --- | --- | --- | --- |
| 0–13 | `joint_angle[7]` | uint16 × 7 | 7 个关节角，客户端原样透传，不解释单位 |
| 14–17 | `relative_time` | uint32 | `0` = 自定义控制；`INT_MAX` = 视觉自动控制 |

- 视觉自动控制：持续发关节角全 0、`relative_time = 0x7FFFFFFF` 的状态帧。
- 自定义控制：把 RS-232 收到的最新 position 按 50 Hz 持续转发，`relative_time` 由
  自定义控制器填写；串口 300 ms 没有新帧时继续重发最后一帧并打
  `RM26_ARM_POSITION_STALE`，所以 `relative_time` 不再推进，主控要据此做失联保护。
- Z 是**点击切换**，不是按住。切换时立即发一帧模式帧（`0` 或 `INT_MAX`，
  角度全 0，主控只按 `relative_time` 切状态），随后由 50 Hz 持续发送维持。
- 自定义控制器经 **USB-RS232 直连上位机**（全双工点对点），34 字节定长帧：16 字节通信头
  （客户端接收忽略、发送填 0）+ `position[16:34)`。端口/波特率用
  `RM_ARM_SERIAL_PORT` / `RM_ARM_SERIAL_BAUD` 配置，默认 115200 8N1。
- 切换帧同时写回自定义控制器（RS-232 连写 3 帧）；客户端只在已登录、非战术模式、
  MQTT 已连接时响应 Z。
- `0x0311` 单条上限 30 字节、75 Hz，每辆车链路独立；18 字节裸载荷与前哨站 10 字节
  消息按长度区分（18 = 机械臂，10 = 前哨站）。前哨站 10 Hz + 机械臂 50 Hz = 60 Hz。

## 功能

- 官方 UI 布局还原：按官方客户端导出的坐标树排布，不目测手排。
- 自定义 HUD：准心区只保留必要数字；模块灯、伤害方向、能量机关等叠加件保持细、淡、冷色。
- 图传：H.265 走 UDP 3334 硬解；H.264 工业相机走 MQTT `CustomByteBlock` 分片。
- 数据：MQTT 3333 接收比赛数据、机器人状态、`CustomByteBlock`。
- 装甲日志：`RM_ENGINE_ARMOR_LOG_DIR` 指向引擎日志目录，用于受击方向。
- 输入：键鼠按 16 位掩码打包，经 `KeyboardMouseControl` 下发（详见「键位设置」）。
- 模拟器：`src/simulator` 可在没有实车时提供模拟数据。

常用环境变量：

| 变量 | 作用 |
| --- | --- |
| `RM_MQTT_BROKER` | 覆盖 MQTT broker 地址 |
| `RM_MQTT_PORT` | 覆盖 MQTT 端口（默认配置 3333） |
| `RM_ENGINE_ARMOR_LOG_DIR` | 引擎装甲日志目录 |
| `RM_CLIENT_ROBOT_ID` | 覆盖机器人编号 |
| `RM_ARM_SERIAL_PORT` | 自定义控制器 RS-232 串口（如 `/dev/ttyUSB0`、`COM5`）；不设则关闭机械臂串口输入 |
| `RM_ARM_SERIAL_BAUD` | RS-232 波特率，默认 115200 |
| `RM_ARM_SERIAL_MAGIC` | 帧头魔数（如 `0xA5`），用于串口重新同步；不设则按 34 字节固定切帧 |
| `RM26_BUILD_DIR` | 构建目录（默认 `~/rm26-build`） |

## 排障

- **3333 连不上**：官方选手端没起，或停在登录界面。它是 broker，不是普通客户端。
- **CONNACK(2) Identifier rejected**：同一个 ClientId 已有连接。`run.sh` 会清理残留进程。
- **没有图传**：daemon 必须先于官方选手端启动；看
  `RMClientDaemon/realtimelog_SerialPort/*.txt` 里有没有 `video2015` 和 `cuda`。
- **图传周期性卡顿**：WSL 内核 UDP 接收缓冲太小，执行
  `sudo sysctl -w net.core.rmem_max=16777216`。
- **机器人不注册 / 日志 offline**：裁判系统栈没起，或热点 ICS 占用了 UDP 端口段。
- **自定义客户端起不来**：确认 `~/rm26-build/RoboMasterClient2025` 存在；
  外部启动脚本和 `run.sh` 都依赖这个固定路径和文件名。
