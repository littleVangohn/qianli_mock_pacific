$ErrorActionPreference = 'Stop'

$python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $python) {
    throw '未找到 python.exe，请先安装 Python 并把它加入 PATH。'
}

$services = Join-Path (Split-Path -Parent $PSScriptRoot) 'services'
if (-not (Test-Path -LiteralPath $services)) {
    throw "找不到 services 目录：$services"
}

Set-Location -LiteralPath $services
& $python '.\referee_server.py' --port auto --host 127.0.0.1 --http-port 8765
