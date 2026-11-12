# E1–E3 联调用例与步骤

协议以 `docs/real_vehicle_integration/电控组最小数据对接文档.md` 为准。
工具：`test/custom_status_tool.py`（`sim` 注入 / `watch` 解码）。

## 1. 本机跑通

```bash
# 终端 A：离线 broker，关闭内置 50 Hz 状态源
python3 test/jitter/mock_broker.py --port 13333 --out-dir /tmp/custom_status_broker \
  --duration 1800 --no-custom-block

# 终端 B：客户端
cd ~/rm26-build
RM_MQTT_BROKER=127.0.0.1 RM_MQTT_PORT=13333 RM_CLIENT_ROBOT_ID=1 ./RoboMasterClient2025

# 终端 C：20 Hz 正常态
python3 test/custom_status_tool.py sim --broker 127.0.0.1 --port 13333 --rate 20 \
  --yaw-deg 45 --offset-deg 30 --pitch-deg 12.3 --mode 2 \
  --fric --fire --pose-valid --pitch-valid --verbose

# 终端 D：独立解码 / seq / 超时观察
python3 test/custom_status_tool.py watch --broker 127.0.0.1 --port 13333 --duration 30
```

客户端里按 `Ctrl+G` 打开自定义叠加层：右上角是姿态盘，准心左侧是俯仰尺，瞄准框右侧是机构状态。

## 2. 验收用例

| # | 命令 / 操作 | 期望 |
|---|---|---|
| 1 | `sim --offset-deg 30 --yaw-deg 45` | 姿态盘车体向右（顺时针）偏 30°；`云台 +45.0°`；`底盘 +15.0°` |
| 2 | `--offset-deg -30` | 车体向左偏；`底盘 +75.0°` |
| 3 | `--offset-deg 90 --yaw-deg 179` | 车体右偏 90°；底盘 `+89.0°` |
| 4 | `--yaw-deg -179 --offset-deg -10` | 底盘 `-169.0°`（跨 ±180 回绕） |
| 5 | `--mode 0/1/2/3` | 正常/跟随/小陀螺/保护，颜色分别蓝/蓝/黄/红 |
| 6 | `--no-pose-valid` | 姿态盘图形和 yaw 读数变灰，显示“姿态无效”；模式文案仍有效 |
| 7 | `--pitch-deg -10/0/12.3/70` | 俯仰滑块在刻度对应位置；读数一致 |
| 8 | `--pitch-deg 100` | 滑块停在 70°，读数显示 `+70.0°` 并变红（超限） |
| 9 | `--no-pitch-valid` | 俯仰尺灰化，显示“俯仰无效”，保留最后值 |
| 10 | `--fric --rammer --fire --autolob` | 对应行 ON 绿；`--efault --warning` 对应行 ON 红 |
| 11 | 停掉 sim 0.5 s 以上 | 三个组件灰化并显示“失联”，保留最后值；恢复后 ≤150 ms 更新 |
| 12 | `--hold-seq` | 客户端只认第一包，300 ms 后失联（重复 seq 不续命） |
| 13 | `--duplicate` | 同 seq 重复包被丢弃，UI 不闪 |
| 14 | `--seq-start 250 --duration 1` | seq 255→0 回绕，UI 持续更新 |
| 15 | `--seq-step -1` | 递减 seq 被当旧包丢弃，300 ms 后失联 |
| 16 | `--version 2` | 客户端限频告警并丢弃，300 ms 后失联；改回 1 恢复 |
| 17 | `--pad-bytes 150` / `300` | 仍按前 11 字节解析，UI 正常更新，不落视频通路 |
| 18 | `Ctrl+G` 两次 | 叠加层隐藏/显示；重新显示后 150 ms 内恢复轮询 |

客户端日志检查：

```bash
LATEST=$(ls -td ~/rm26-build/tmp/runtime_* | head -1)
grep -E "\[custombyte\]|Parsed custom data|drop custom status" "$LATEST/runtime.log" | tail
```

期望能看到 `version= 1 ... offset= ... gimbalYaw= ... chassisYaw= ... pitch= ...`。

## 3. 实车联调步骤

1. **裁判系统栈**（管理员 PowerShell）：
   `D:\Pacific_doorlock\裁判系统服务器\start_referee_stack.ps1`，四个组件都 RUN。
   注意：0x0310 本身走**图传发射端 UART → 图传链路**，不经过 MC02；裁判栈是为了比赛数据、机器人 ID 和视频链路。
2. **官方选手端**：提权登录，确认图传画面正常。图传没画面，0x0310 也过不来。
3. **自定义客户端**：WSL 里 `run.sh`，`client_robot_id` 改成现场机器人 ID（红 1–7 / 蓝 101–107）。
4. **电控**：0x0310，20 Hz，应用负载 11 字节，小端，seq 递增。
5. **按层设卡**：
   - 图传画面正常；
   - `watch --broker <WINIP> --port 3333 --duration 60` 能看到 `CustomByteBlock`；
   - `data[0] == 0x5A`、`data.size() >= 11`、version=1；
   - 客户端日志出现 `Parsed custom data`；
   - 右侧姿态盘/俯仰尺/机构状态与电控 HMI 一致。
6. **现场必须和电控确认**：
   - Byte 6–7 是云台世界角（文档表格）还是底盘角（文档示例的“底盘 45°”）。客户端当前按云台世界角实现，底盘角 = 云台角 − 偏角。
   - 0x0310 的 data 首字节是否就是 `0x5A`，还是前置了 mode 字节 / 补齐到 150/300。客户端只认首字节 `0x5A`；前置字节会导致整包被当视频分片。
   - 电控重启后 seq 归零会被客户端当旧包丢弃（最坏约 128 个包，20 Hz 下约 6.4 s）。需要约定重启后 seq 从当前值继续，或接受这段恢复时间。

## 4. 现象定位

| 现象 | 先查 |
|---|---|
| `watch` 完全没包 | 图传链路/官方选手端是否通；VT 是否已对频；电控是否在发 0x0310 |
| 有包但 `not status` | data 首字节不是 0x5A；看 `watch` 打印的 raw |
| 客户端无 `Parsed custom data` | 客户端没连上 broker、robotId=0、版本不符；看 runtime.log |
| UI 一直“等待数据” | 包没到客户端；看 `CustomByteBlock` 是否被 MQTT 订阅到 |
| UI 很快“失联” | seq 重复/旧包被丢；用 `watch` 看 DUP/OLD/GAP |
| 角度方向反了 | 用 `--offset-deg 30` 对照：车体应向右摆；若不是，查 Byte 4–5 符号约定 |
| 底盘 yaw 差一个偏角 | Byte 6–7 实际发的是底盘角而不是云台世界角；和电控确认 |
