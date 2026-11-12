# cquqianli_mock

RoboMaster 2026 自定义客户端，跑在 WSL Ubuntu 22.04。

## 数据管线

```text
裁判系统栈（已常开 24h）
  └─ 比赛数据 ──────────────────────────────┐
                                            │
电控 0x0310                                 │
  └─ 图传发射端 UART(921600)                │
       └─ 图传链路 ── 图传接收端 USB-C ─────┤
                                            ▼
                             官方选手端 RoboMasterClient.exe
                              ├─ MQTT :3333（比赛数据 + CustomByteBlock）
                              └─ UDP :3334（H.265 图传）
                                            │
                                            ▼
                             自定义客户端 RoboMasterClient2025
```

官方选手端自己就是 MQTT broker，不开它自定义客户端连 3333 都连不上。`run.sh` 会先起官方选手端，再起自定义客户端。

## 启动

裁判系统栈已常开，不用重复启动。WSL 里一条命令：

```bash
bash /mnt/d/Pacific_doorlock/cquqianli_mock/run.sh
```

`run.sh` 会自动把 config 指向当前 Windows 主机、拉起官方选手端（已在运行则跳过）、等 3333 就绪，然后启动自定义客户端。`Ctrl+C` 退出。

首次部署、免 UAC、排障见 `run.sh` 头部注释和 `test/`；电控 0x0310 联调见 `docs/real_vehicle_integration/电控组最小数据对接文档.md` 和 `test/custom_status_cases.md`。
