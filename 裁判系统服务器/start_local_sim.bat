@echo off
setlocal

rem ---------------------------------------------------------------
rem  RoboMaster local simulator - double-click entry point
rem
rem  Default (no args) starts EVERYTHING:
rem    1. InfluxDB
rem    2. RoboMasterEngine (it starts RMServer / AdapterSvr /
rem       RMServerLogClient / Redis)
rem    3. Local hotspot + 192.168.1.2/24 on the hotspot adapter
rem       (so physical robots can use the official 192.168.1.2)
rem    4. RMClientDaemon (video: COM5 + VT USB)
rem    5. Official client RoboMasterClient.exe (MQTT broker :3333)
rem    6. Custom client (WSL build by default, see config.ps1)
rem
rem  Where to put the official programs:
rem    <this folder>\vendor\RoboMasterEngine ...\
rem    <this folder>\vendor\RoboMasterClient ...\
rem  or as siblings of this folder. See README.md. No drive letters
rem  are hard-coded.
rem
rem  Optional args:
rem    -NoHotspot      do not start the Local hotspot (or -SkipHotspot)
rem    -ServicesOnly   services only, no clients
rem    -DryRun         check only, change nothing
rem    -SkipInflux     do not start InfluxDB
rem    -WslDistro X    override the WSL distro from config.ps1
rem ---------------------------------------------------------------

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_local_sim.ps1" %*
set "RC=%errorlevel%"

echo.
if not "%RC%"=="0" echo [ERROR] start_local_sim.ps1 exited with code %RC%
pause
exit /b %RC%
