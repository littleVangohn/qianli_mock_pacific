# cquqianli_mock

RoboMaster 2026 自定义客户端（Qt 6 / C++17 / QML），运行在 WSL Ubuntu 22.04。
数据来自官方选手端的 MQTT broker（:3333），图传来自官方选手端的 UDP（:3334），
电控状态经 0x0310 → 图传链路 → `CustomByteBlock` 进入客户端。

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

## 数据链路

```text
裁判系统栈
  └─ 比赛数据 ───────────────────────────────┐
                                             │
电控 0x0310                                  │
  └─ 图传发射端 UART                         │
       └─ 图传链路 ── 图传接收端 USB-C ──────┤
                                             ▼
                              官方选手端 RoboMasterClient.exe
                               ├─ MQTT :3333（比赛数据 + CustomByteBlock）
                               └─ UDP :3334（H.265 图传）
                                             │
                                             ▼
                              自定义客户端 RoboMasterClient2025
```

官方选手端自己就是 MQTT broker。它不在，自定义客户端连 3333 都连不上；
图传 daemon 晚于官方选手端启动时，共享内存对不上，需要重启官方选手端。

## 电控状态包

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

# v1：11 字节
pkt = struct.pack('<BBBBhhhB',
                  0x5A, 1, friction_status, chassis_status,
                  gimbal_chassis_angle, gimbal_yaw, barrel_pitch, seq)
# v2：再补 1 字节模块状态
pkt += bytes([module_status])
```

注意：状态包必须至少 11 字节，且首字节为 `0x5A`；否则会被当作视频分片。
建议直接发 12 字节 v2，这样模块灯也有数据。

## 功能

- 官方 UI 布局还原：按官方客户端导出的坐标树排布，不目测手排。
- 自定义 HUD：准心区只保留必要数字；模块灯、伤害方向、能量机关等叠加件保持细、淡、冷色。
- 图传：H.265 走 UDP 3334 硬解；H.264 工业相机走 MQTT `CustomByteBlock` 分片。
- 数据：MQTT 3333 接收比赛数据、机器人状态、`CustomByteBlock`。
- 装甲日志：`RM_ENGINE_ARMOR_LOG_DIR` 指向引擎日志目录，用于受击方向。
- 输入：键盘/鼠标按键按位打包转发（W/S/A/D、Shift、Ctrl、Q/E/R/F/G/Z/X/C/V/B）。
- 模拟器：`src/simulator` 可在没有实车时提供模拟数据。

常用环境变量：

| 变量 | 作用 |
| --- | --- |
| `RM_MQTT_BROKER` | 覆盖 MQTT broker 地址 |
| `RM_MQTT_PORT` | 覆盖 MQTT 端口（默认配置 3333） |
| `RM_ENGINE_ARMOR_LOG_DIR` | 引擎装甲日志目录 |
| `RM_CLIENT_ROBOT_ID` | 覆盖机器人编号 |
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

## 来源与许可

客户端基于复旦大学星云 EGA 战队的 RM26_Client 修改而来，原项目采用 MIT 许可。
按本仓库精简要求未保留独立的 LICENSE 文件，MIT 许可声明全文如下：

```text
MIT License

Copyright (c) 2025-2026 Fudan University EGA Team (复旦大学星云 EGA 机器人战队)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
