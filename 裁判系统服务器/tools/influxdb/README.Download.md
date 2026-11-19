# InfluxDB 2.x（不放也能启动）

`influxd.exe` 不随仓库分发（约 110 MB，超过 GitHub 单文件上限）。

需要历史数据落库时，下载 InfluxDB 2.7.x OSS Windows 版，把 `influxd.exe`
放到本目录即可：

- 下载：https://dl.influxdata.com/influxdb/releases/influxdb2-2.7.11-windows.zip
- 本次验证版本：InfluxDB v2.7.11

不放也不会影响启动：裁判日志端仍可 `[Online]`，只是历史数据不落库。
