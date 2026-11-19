# AGENT.md — 当前交接

> 2026-11-19 整理。唯一入口：`start_local_sim.bat`。详细说明见 `README.md`。

## 现状

- 一键入口 `start_local_sim.bat` 默认全起：InfluxDB → 引擎/服务 → 热点 → 图传 daemon →
  官方选手端 → 自定义客户端。
- 配置在 `config.ps1`，全部相对本目录；`EngineRoot` / `ClientRoot` 留空会自动查找
  `vendor\`、上一级或 `..\从零开始认识裁判系统\`。
- 热点默认开；`-NoHotspot` 关；`-ServicesOnly` 只起服务；`-DryRun` 只检查。

## 关键坑（2026-11-19 验证）

- Windows 热点（ICS）会把客户端发往 `192.168.137.0/24` 以外地址的流量做 SNAT。
  机器人按官方地址发 `192.168.1.2:62101` 时，如果 `192.168.1.2` 不在热点网卡上，
  服务端看到的登录来源会被改写成主机物理 WLAN 地址，`LOGIN_ACK` 回不去，
  AdapterSvr 日志里 `S0Robot[0]/[1]` 每秒交替、`[LOGIN]` 一秒好几条。
- 正确顺序：热点起来后立刻把 `192.168.1.2/24` 挪到热点网卡（`setup_local_lan.ps1`
  已自动做）；机器人若在换地址前就连着，需要断开重连一次，旧的 NAT 映射才不会继续生效。
- ICS 预留 62050-64998：热点开着时新进程 bind `62101-62103` 会 `WSAEACCES`。
  默认流程先停 ICS，再起引擎占住端口，最后开热点。不要在 ICS 起来后重启 AdapterSvr。
- 不要改回“192.168.1.2 只挂 VMnet1、热点只负责 137.1”的旧流程，物理机器人会登录抖动。

## 常用判据

- 机器人注册：AdapterSvr 日志最后一行 `Translator count ... S0Robot[1]`
  （`<引擎>\...\RMServer\AdapterSvr\logs\当天.log`）。
- 登录来源应该是 `192.168.137.x:60000`，不是 `172.x` / `10.x`。
- 日志端：`RMServerLogClient` 窗口标题不带 `[offline]`（看 UDP `62103`）。
- 官方选手端：`Player.log` 出现 `Login : Success`，`3333` 监听。
- 自定义客户端：WSL 里进程名截断为 `RoboMasterClien`，看 `/tmp/cquqianli_client.log`。

## 历史

旧交接 / 排障文档在 `docs\legacy\`。
