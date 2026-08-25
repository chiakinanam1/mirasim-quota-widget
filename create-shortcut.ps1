# 生成托盘专属图标(多尺寸 .ico)并在桌面创建快捷方式
# 用法: powershell -ExecutionPolicy Bypass -File create-shortcut.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$dir = $PSScriptRoot
$vbs = Join-Path $dir 'launch-tray.vbs'
$icoPath = Join-Path $dir 'assets\quota-tray.ico'
if (-not (Test-Path $vbs)) { throw '缺少 launch-tray.vbs' }

# ---- 圆环图标: 小尺寸单环, 128/256 用并排三环(与托盘一致) ----
function New-RoundRect([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
  $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
  $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
  $p.CloseFigure()
  $p
}
function Draw-Ring([System.Drawing.Graphics]$g, [double]$cx, [double]$cy, [double]$d, [double]$pen, [double]$frac) {
  $x = $cx - $d / 2; $y = $cy - $d / 2
  $pt = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 122, 122, 126)), ([float]$pen)
  $g.DrawEllipse($pt, [float]$x, [float]$y, [float]$d, [float]$d); $pt.Dispose()
  if ($frac -le 0) { return }
  $pa = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 245, 245, 247)), ([float]$pen)
  $pa.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pa.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawArc($pa, [float]$x, [float]$y, [float]$d, [float]$d, -90, [float](360 * $frac)); $pa.Dispose()
}
function New-Frame([int]$n) {
  $bmp = New-Object System.Drawing.Bitmap $n, $n
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  # 深色圆角底(任何壁纸上都立得住,与面板同色系)
  $path = New-RoundRect 0 0 $n $n ($n * 0.22)
  $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 29, 29, 32))
  $g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
  if ($n -ge 128) {
    $d = $n * 0.235; $pen = $n * 0.045; $gap = $n * 0.05
    $x0 = ($n - (3 * $d + 2 * $gap)) / 2 + $d / 2
    $fr = @(0.62, 0.90, 0.28)
    for ($i = 0; $i -lt 3; $i++) {
      Draw-Ring $g ($x0 + $i * ($d + $gap)) ($n / 2) $d $pen $fr[$i]
    }
  } else {
    Draw-Ring $g ($n / 2) ($n / 2) ($n * 0.58) ($n * 0.105) 0.72
  }
  $g.Dispose()
  $bmp
}
$sizes = @(16, 20, 24, 32, 48, 64, 128, 256)
# 帧数据用 32 位 DIB(通用兼容;PNG 压缩帧 .NET Icon 类解不了)
$frames = @()
foreach ($s in $sizes) {
  $bmp = New-Frame $s
  $rect = New-Object System.Drawing.Rectangle 0, 0, $s, $s
  $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $bd.Stride
  $px = New-Object byte[] ($stride * $s)
  [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $px, 0, $px.Length)
  $bmp.UnlockBits($bd); $bmp.Dispose()
  $maskRow = [Math]::Floor(($s + 31) / 32) * 4
  $buf = New-Object byte[] (40 + $s * $s * 4 + $maskRow * $s)
  $ms = New-Object System.IO.MemoryStream ($buf, $true)
  $bw2 = New-Object System.IO.BinaryWriter $ms
  $bw2.Write([uint32]40); $bw2.Write([int32]$s); $bw2.Write([int32]($s * 2))
  $bw2.Write([uint16]1); $bw2.Write([uint16]32); $bw2.Write([uint32]0)
  $bw2.Write([uint32]($s * $s * 4)); $bw2.Write([int32]0); $bw2.Write([int32]0)
  $bw2.Write([uint32]0); $bw2.Write([uint32]0)
  for ($y = $s - 1; $y -ge 0; $y--) { $bw2.Write($px, $y * $stride, $s * 4) }   # DIB 自下而上
  $bw2.Write((New-Object byte[] ($maskRow * $s)))                              # AND 掩码全 0,透明由 alpha 决定
  $bw2.Flush()
  $frames += , @{ size = $s; bytes = $ms.ToArray() }
  $bw2.Close(); $ms.Dispose()
}
New-Item -ItemType Directory -Force (Split-Path $icoPath) | Out-Null
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
  $dim = $f.size; if ($dim -ge 256) { $dim = 0 }
  $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32)
  $bw.Write([uint32]$f.bytes.Length); $bw.Write([uint32]$offset)
  $offset += $f.bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.bytes) }
$bw.Flush(); $bw.Close(); $fs.Close()
Write-Host "图标已生成: $icoPath"

# ---- 桌面快捷方式 ----
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Mirasim 额度.lnk'
$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($lnk)
$sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $dir
$sc.IconLocation = $icoPath + ',0'
$sc.Description = 'Mirasim 额度监视器 — 托盘三窗口(5h/7d/Fable)+ 水墨面板'
$sc.WindowStyle = 1
$sc.Save()
[Runtime.InteropServices.Marshal]::ReleaseComObject($sh) | Out-Null
Write-Host "桌面快捷方式已创建: $lnk"
Write-Host '双击即静默启动托盘(已在运行则自动忽略,不会重复开)。'
