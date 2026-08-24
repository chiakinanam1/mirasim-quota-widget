# Mirasim 额度托盘小工具 — 安装/启动
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1
# 系统托盘图标(最紧窗口已用%),左键弹出/收起水墨额度面板(5h / 7d / 7d Fable)。
# 完全独立于 Mirasim:不注入、不依赖 Chrome、不受其更新影响。

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$tray = Join-Path $dir 'quota-tray.ps1'
if (-not (Test-Path $tray)) { throw '缺少 quota-tray.ps1' }

# 确保 quota-tray.ps1 为 UTF8-BOM(PowerShell 5.1 无 BOM 会按 ANSI 读坏中文)
$raw = [IO.File]::ReadAllText($tray, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($tray, $raw, (New-Object Text.UTF8Encoding $true))

# 停掉可能已在运行的旧实例(排除自身)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'quota-tray\.ps1' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -Confirm:$false } catch {} }
Start-Sleep -Milliseconds 400

# 开机自启(HKCU Run;托盘右键菜单可随时取消)
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$tray`""
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MirasimQuotaTray' -Value $cmd

# 启动托盘(隐藏窗口;WPF 需要 -STA)
Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $tray -WindowStyle Hidden
Start-Sleep -Seconds 3
$n = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'quota-tray\.ps1' } | Measure-Object).Count
if ($n -ge 1) { Write-Host '托盘已启动,开机自启已注册 ✓' } else { Write-Host '启动可能失败,请查看 %TEMP%\mqw-tray-err.log' }

Write-Host ''
Write-Host '图标出现在任务栏系统托盘(可能在"隐藏图标"溢出区 —— 点向上箭头展开,可把图标拖到常驻区)。'
Write-Host '左键点击图标 = 弹出/收起额度面板;右键 = 打开面板 / 刷新 / 开机自启 / 退出。'
