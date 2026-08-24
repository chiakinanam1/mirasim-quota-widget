# Mirasim 额度托盘小工具 — 安装/启动
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1
# 启动系统托盘图标(7d 已用%),点击弹出原样式水墨毛玻璃额度面板。
# 完全独立于 Mirasim,不注入、不受其更新影响。

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$tray = Join-Path $dir 'quota-tray.ps1'
$html = Join-Path $dir 'panel.html'
$chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"

if (-not (Test-Path $tray)) { throw "缺少 quota-tray.ps1" }
if (-not (Test-Path $html)) { throw "缺少 panel.html" }
if (-not (Test-Path $chrome)) { Write-Host "警告: 未找到 Chrome ($chrome)。面板需要 Chrome 渲染,请先安装 Google Chrome。" }

# 确保 quota-tray.ps1 是 UTF8-BOM(PowerShell 5.1 正确读中文)
$raw = [IO.File]::ReadAllText($tray, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($tray, $raw, (New-Object Text.UTF8Encoding $true))

# 停掉可能已在运行的旧实例
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object {
  try { $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine; if ($cl -match 'quota-tray') { Stop-Process -Id $_.Id -Force } } catch {}
}
Start-Sleep -Milliseconds 500

# 启动托盘(隐藏窗口)
Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $tray -WindowStyle Hidden
Start-Sleep -Seconds 3
$n = (Get-Process powershell -EA SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match 'quota-tray' } catch { $false } } | Measure-Object).Count
if ($n -ge 1) { Write-Host "托盘已启动 ✓" } else { Write-Host "启动可能失败,请手动运行 quota-tray.ps1" }

Write-Host ""
Write-Host "图标出现在任务栏系统托盘(可能在'隐藏图标'溢出区 —— 点向上箭头展开,可把图标拖到常驻区)。"
Write-Host "左键点击图标 = 弹出/收起额度面板;右键 = 刷新 / 开机自启 / 退出。"
