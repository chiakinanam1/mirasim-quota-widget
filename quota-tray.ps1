# Mirasim 额度托盘小工具 — 系统托盘图标(最紧窗口已用%) + 点击弹出水墨原生面板(5h / 7d / 7d Fable)
# 完全自包含:进程内直接探测 Mirasim 路由端口 GET /v1/limits(绝对 used/budget/reset_at),
# 不注入、不依赖 Chrome、不受 Mirasim 更新影响。仅本机回环读取,零额度消耗。
# 启动: powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File quota-tray.ps1
#   -Panel  启动后立即显示面板(调试用)
param([switch]$Panel)

$ErrorActionPreference = 'Stop'
try {

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationFramework, PresentationCore, WindowsBase

# ---- 单实例 ----
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'MirasimQuotaTrayMutex', [ref]$created)
if (-not $created) { exit }

# ---- Win32 ----
Add-Type @'
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int L; public int R; public int T; public int B; }
public class W32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cy, uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
}
'@
[W32]::SetProcessDPIAware() | Out-Null

$WIN_LEN = @{ '5h' = 18000L; '7d' = 604800L; '7d_fable' = 604800L }
$LABEL   = @{ '5h' = '5 小时'; '7d' = '7 天'; '7d_fable' = '7 天 Fable' }
$BARW = 284.0
$cachePath = Join-Path $env:LOCALAPPDATA 'mirasim-quota-tray-cache.json'

# ---- 共享状态(轮询 runspace ←→ UI) ----
$state = [hashtable]::Synchronized(@{ json = $null; at = 0L; ok = $false; rev = 0; port = 0; kick = $false })
if (Test-Path $cachePath) {
  try { $c = (Get-Content $cachePath -Raw) | ConvertFrom-Json; $state.json = [string]$c.body; $state.at = [long]$c.at; $state.port = [int]$c.port; $state.rev = 1 } catch {}
}

# ---- 后台轮询:枚举 Mirasim 监听端口 → GET /v1/limits(端口随服务端重启漂移,缓存+重枚举) ----
$pollScript = {
  param($state, $cachePath)
  while ($true) {
    $ports = @(); if ($state.port -gt 0) { $ports += [int]$state.port }
    try {
      $mp = @((Get-Process Mirasim -ErrorAction SilentlyContinue).Id)
      if ($mp.Count -gt 0) {
        $more = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
          Where-Object { $mp -contains $_.OwningProcess -and $_.LocalAddress -eq '127.0.0.1' } |
          Select-Object -ExpandProperty LocalPort -Unique
        foreach ($p in $more) { if ($ports -notcontains [int]$p) { $ports += [int]$p } }
      }
    } catch {}
    $hit = $false
    foreach ($p in $ports) {
      try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$p/v1/limits" -TimeoutSec 2 -UseBasicParsing
        if ($resp.StatusCode -eq 200 -and $resp.Content -match '"budget"') {
          $state.json = [string]$resp.Content; $state.at = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
          $state.port = $p; $state.ok = $true; $state.rev++
          try { @{ at = $state.at; port = $p; body = $state.json } | ConvertTo-Json -Compress | Set-Content -Path $cachePath -Encoding ASCII } catch {}
          $hit = $true; break
        }
      } catch {}
    }
    if (-not $hit -and $state.ok) { $state.ok = $false; $state.rev++ }
    for ($i = 0; $i -lt 50; $i++) { if ($state.kick) { $state.kick = $false; break }; Start-Sleep -Milliseconds 500 }
  }
}
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
$poller = [powershell]::Create(); $poller.Runspace = $rs
[void]$poller.AddScript($pollScript).AddArgument($state).AddArgument($cachePath); [void]$poller.BeginInvoke()

# ---- 主题 ----
function Test-LightApps  { try { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -EA Stop).AppsUseLightTheme -eq 1 } catch { $false } }
function Test-LightTray  { try { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -EA Stop).SystemUsesLightTheme -eq 1 } catch { $false } }
function New-Brush([string]$argb) { $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($argb)); $b.Freeze(); $b }

# ---- WPF 面板 ----
$rowTpl = @'
      <StackPanel x:Name="Row__X__" Margin="14,9,14,0">
        <Grid>
          <TextBlock x:Name="Top__X__" VerticalAlignment="Bottom"/>
          <TextBlock x:Name="Pct__X__" HorizontalAlignment="Right" VerticalAlignment="Bottom" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,1"/>
        </Grid>
        <Grid Height="15" Margin="0,6,0,0">
          <Border x:Name="Track__X__" Height="6" CornerRadius="3" VerticalAlignment="Center"/>
          <Border x:Name="Fill__X__" Height="6" CornerRadius="3" VerticalAlignment="Center" HorizontalAlignment="Left" Width="0"/>
          <Grid x:Name="Pace__X__" Width="9" HorizontalAlignment="Left" IsHitTestVisible="False">
            <Rectangle x:Name="PL__X__" Width="1.5" HorizontalAlignment="Center"/>
            <Polygon x:Name="PT__X__" Points="0.5,0 8.5,0 4.5,4.8" VerticalAlignment="Top" HorizontalAlignment="Center"/>
          </Grid>
        </Grid>
        <Grid Margin="0,4,0,0">
          <TextBlock x:Name="Meta__X__" FontSize="10.5"/>
          <TextBlock x:Name="Eta__X__" HorizontalAlignment="Right" FontSize="10.5"/>
        </Grid>
      </StackPanel>
'@
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mirasim 额度" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        Topmost="True" ShowActivated="True" SizeToContent="Height" Width="312"
        Background="Transparent" FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"
        TextOptions.TextFormattingMode="Display">
  <Border x:Name="Root" BorderThickness="1" CornerRadius="8">
    <StackPanel>
      <Grid Margin="14,11,14,2">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="Dot" Width="6" Height="6" Margin="0,1,7,0" VerticalAlignment="Center" StrokeThickness="1"/>
          <TextBlock x:Name="HdTitle" Text="额度" FontSize="13" FontWeight="SemiBold"/>
        </StackPanel>
        <TextBlock x:Name="Asof" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="10.5"/>
      </Grid>
      <Border x:Name="Banner" Visibility="Collapsed" CornerRadius="6" Margin="14,7,14,0" Padding="9,4">
        <TextBlock x:Name="BannerTxt" FontSize="10.5"/>
      </Border>
      <!--ROWS-->
      <Border x:Name="Hair" Height="0.8" Margin="0,11,0,0"/>
      <Grid Margin="14,8,14,10">
        <TextBlock x:Name="St" FontSize="10.5" VerticalAlignment="Center"/>
        <Border x:Name="BtnRf" HorizontalAlignment="Right" CornerRadius="7" Padding="11,3.5" Cursor="Hand" BorderThickness="0.8">
          <TextBlock x:Name="BtnRfTxt" Text="刷新" FontSize="11" FontWeight="SemiBold"/>
        </Border>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@
$rows = ''
foreach ($x in '5', '7', 'F') { $rows += $rowTpl.Replace('__X__', $x) }
$win = [Windows.Markup.XamlReader]::Parse($xaml.Replace('<!--ROWS-->', $rows))
$el = @{}
$names = @('Root', 'Dot', 'HdTitle', 'Asof', 'Banner', 'BannerTxt', 'Hair', 'St', 'BtnRf', 'BtnRfTxt')
foreach ($x in '5', '7', 'F') { $names += @("Row$x", "Top$x", "Pct$x", "Track$x", "Fill$x", "Pace$x", "PL$x", "PT$x", "Meta$x", "Eta$x") }
foreach ($n in $names) { $el[$n] = $win.FindName($n) }

# DWM: 圆角 + 深色 + 亚克力背材(失败则退纯色)
$helper = New-Object Windows.Interop.WindowInteropHelper $win
$hwnd = $helper.EnsureHandle()
$src = [Windows.Interop.HwndSource]::FromHwnd($hwnd)
$src.CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
$v = 2; [W32]::DwmSetWindowAttribute($hwnd, 33, [ref]$v, 4) | Out-Null   # DWMWA_WINDOW_CORNER_PREFERENCE = ROUND
$m = New-Object MARGINS; $m.L = -1; $m.R = -1; $m.T = -1; $m.B = -1
[W32]::DwmExtendFrameIntoClientArea($hwnd, [ref]$m) | Out-Null
$v = 3; $script:acrylicOk = ([W32]::DwmSetWindowAttribute($hwnd, 38, [ref]$v, 4) -eq 0)  # DWMWA_SYSTEMBACKDROP_TYPE = TRANSIENT(acrylic)

# ---- 水墨调色板(跟随应用明暗) ----
$script:P = $null
$script:isLight = $null
function Apply-Theme {
  $light = Test-LightApps
  if ($script:isLight -eq $light -and $script:P) { return }
  $script:isLight = $light
  $v = 0; if (-not $light) { $v = 1 }
  [W32]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4) | Out-Null            # 亚克力深浅
  if ($light) {
    $bg = '#CCF5F5F4'; if (-not $script:acrylicOk) { $bg = '#FFF5F5F4' }
    $script:P = @{
      ink = New-Brush '#E0000000'; ink2 = New-Brush '#85000000'; ink3 = New-Brush '#57000000'
      track = New-Brush '#1A000000'; hair = New-Brush '#14000000'; btn = New-Brush '#0D000000'
      bg = New-Brush $bg; bd = New-Brush '#1F000000'; none = New-Brush '#00000000'
    }
  } else {
    $bg = '#D11C1C1E'; if (-not $script:acrylicOk) { $bg = '#FF1F1F22' }
    $script:P = @{
      ink = New-Brush '#E6FFFFFF'; ink2 = New-Brush '#8CFFFFFF'; ink3 = New-Brush '#57FFFFFF'
      track = New-Brush '#24FFFFFF'; hair = New-Brush '#17FFFFFF'; btn = New-Brush '#14FFFFFF'
      bg = New-Brush $bg; bd = New-Brush '#1FFFFFFF'; none = New-Brush '#00FFFFFF'
    }
  }
  $P = $script:P
  $el.Root.Background = $P.bg; $el.Root.BorderBrush = $P.bd
  $el.HdTitle.Foreground = $P.ink; $el.Asof.Foreground = $P.ink3
  $el.Banner.Background = $P.btn; $el.BannerTxt.Foreground = $P.ink2
  $el.Hair.Background = $P.hair
  $el.St.Foreground = $P.ink3
  $el.BtnRf.Background = $P.btn; $el.BtnRf.BorderBrush = $P.hair; $el.BtnRfTxt.Foreground = $P.ink
  foreach ($x in '5', '7', 'F') {
    $el["Track$x"].Background = $P.track; $el["Fill$x"].Background = $P.ink
    $el["PL$x"].Fill = $P.ink; $el["PT$x"].Fill = $P.ink
    $el["Pct$x"].Foreground = $P.ink2; $el["Eta$x"].Foreground = $P.ink3; $el["Meta$x"].Foreground = $P.ink3
  }
  Render-All
}

# ---- 数据模型 ----
$script:model = $null      # @{ wins = name→win; flags; atMs }
$script:seenRev = -1
function Parse-State {
  $script:model = $null
  if (-not $state.json) { return }
  try {
    $doc = $state.json | ConvertFrom-Json
    $wins = @{}
    foreach ($w in $doc.windows) { $wins[[string]$w.name] = $w }
    $script:model = @{ wins = $wins; flags = $doc; atMs = [long]$state.at }
  } catch {}
}

function Fmt-Cred([double]$v, [double]$total) {
  if ($total -ge 1000) { [Math]::Round($v).ToString('N0') } else { $v.ToString('0.0') }
}
function Fmt-Eta([long]$resetAt) {
  $s = $resetAt - [DateTimeOffset]::Now.ToUnixTimeSeconds()
  if ($s -le 0) { return '即将重置' }
  $d = [Math]::Floor($s / 86400); $h = [Math]::Floor($s % 86400 / 3600); $mi = [Math]::Floor($s % 3600 / 60); $ss = $s % 60
  if ($d -gt 0) { return "$d 天 $h 小时后重置" }
  if ($h -gt 0) { return "{0}:{1:00}:{2:00} 后重置" -f $h, $mi, $ss }
  return "{0}:{1:00} 后重置" -f $mi, $ss
}
function Get-Pace([string]$name, [long]$resetAt) {
  $len = $WIN_LEN[$name]; if (-not $len) { return $null }
  $remain = $resetAt - [DateTimeOffset]::Now.ToUnixTimeSeconds()
  [Math]::Max(0.0, [Math]::Min(100.0, (1.0 - $remain / [double]$len) * 100.0))
}

# ---- 渲染 ----
function Set-TopRuns([string]$x, [string]$label, [string]$used, [string]$total) {
  $tb = $el["Top$x"]; $tb.Inlines.Clear(); $P = $script:P
  $r = New-Object Windows.Documents.Run ($label + '  '); $r.FontSize = 12; $r.Foreground = $P.ink2; $tb.Inlines.Add($r)
  $r = New-Object Windows.Documents.Run $used; $r.FontSize = 19; $r.FontWeight = [Windows.FontWeights]::SemiBold; $r.Foreground = $P.ink; $tb.Inlines.Add($r)
  if ($total) { $r = New-Object Windows.Documents.Run (' / ' + $total); $r.FontSize = 12; $r.Foreground = $P.ink3; $tb.Inlines.Add($r) }
}
function Set-MetaRuns([string]$x, [double]$pace, [double]$diff) {
  $tb = $el["Meta$x"]; $tb.Inlines.Clear(); $P = $script:P
  $r = New-Object Windows.Documents.Run ("均速 {0:0}% · " -f $pace); $r.Foreground = $P.ink3; $tb.Inlines.Add($r)
  $t = "低于均速 {0:0.0}%" -f (- $diff); if ($diff -gt 0) { $t = "超出均速 {0:0.0}%" -f $diff }
  $r = New-Object Windows.Documents.Run $t; $r.Foreground = $P.ink2; $r.FontWeight = [Windows.FontWeights]::SemiBold; $tb.Inlines.Add($r)
}
function Update-Row([string]$x, [string]$name) {
  $w = $null; if ($script:model) { $w = $script:model.wins[$name] }
  if ($name -eq '7d_fable') {
    $vis = [Windows.Visibility]::Visible; if (-not $w) { $vis = [Windows.Visibility]::Collapsed }
    $el["Row$x"].Visibility = $vis
  }
  if (-not $w) {
    Set-TopRuns $x $LABEL[$name] '—' ''
    $el["Pct$x"].Text = ''; $el["Fill$x"].Width = 0
    $el["Pace$x"].Visibility = [Windows.Visibility]::Collapsed
    $el["Meta$x"].Inlines.Clear(); $el["Eta$x"].Text = ''
    return
  }
  $used = [double]$w.used; $budget = [double]$w.budget; $reset = [long]$w.reset_at
  $pct = 0.0; if ($budget -gt 0) { $pct = $used / $budget * 100.0 }
  Set-TopRuns $x $LABEL[$name] (Fmt-Cred ($used / 100) ($budget / 100)) (Fmt-Cred ($budget / 100) ($budget / 100))
  $el["Pct$x"].Text = ('{0:0.0}%' -f $pct)
  $el["Fill$x"].Width = [Math]::Max(0.0, [Math]::Min(1.0, $pct / 100.0)) * $BARW
  $pace = Get-Pace $name $reset
  if ($null -ne $pace) {
    $el["Pace$x"].Visibility = [Windows.Visibility]::Visible
    $px = $pace / 100.0 * $BARW
    $el["Pace$x"].Margin = [Windows.Thickness]::new([Math]::Max(0.0, [Math]::Min($BARW - 9.0, $px - 4.5)), 0, 0, 0)
    Set-MetaRuns $x $pace ($pct - $pace)
  } else { $el["Pace$x"].Visibility = [Windows.Visibility]::Collapsed; $el["Meta$x"].Inlines.Clear() }
  $el["Eta$x"].Text = Fmt-Eta $reset
}
function Render-All {
  if (-not $script:P) { return }
  $P = $script:P
  Update-Row '5' '5h'; Update-Row '7' '7d'; Update-Row 'F' '7d_fable'
  # 状态点:实心=在线,空心=断开
  if ($state.ok) { $el.Dot.Fill = $P.ink; $el.Dot.Stroke = $P.none }
  else { $el.Dot.Fill = $P.none; $el.Dot.Stroke = $P.ink3 }
  # 顶部时间 + 底部状态
  if ($script:model) {
    $t = [DateTimeOffset]::FromUnixTimeMilliseconds($script:model.atMs).ToLocalTime()
    $el.Asof.Text = $t.ToString('HH:mm:ss') + ' 更新'
  } else { $el.Asof.Text = '' }
  if ($state.ok) { $el.St.Text = '已连接 · 端口 ' + $state.port }
  elseif ($script:model) {
    $t = [DateTimeOffset]::FromUnixTimeMilliseconds($script:model.atMs).ToLocalTime()
    $el.St.Text = '未连接 · 显示 ' + $t.ToString('HH:mm') + ' 数据'
  } else { $el.St.Text = '未连接 · 等待 Mirasim…' }
  # 状态位横幅
  $msgs = @()
  if ($script:model) {
    $f = $script:model.flags
    if ($f.suspended) { $msgs += '账户已暂停' }
    if ($f.degraded) { $msgs += '服务降级中' }
    if ($f.unmetered) { $msgs += '当前不计量' }
  }
  if ($msgs.Count -gt 0) { $el.BannerTxt.Text = ($msgs -join ' · '); $el.Banner.Visibility = [Windows.Visibility]::Visible }
  else { $el.Banner.Visibility = [Windows.Visibility]::Collapsed }
}
# 每秒轻量项:倒计时 + 均速标随时间移动
function Update-Dynamic {
  if (-not $script:model -or -not $script:P) { return }
  foreach ($pair in @(@('5', '5h'), @('7', '7d'), @('F', '7d_fable'))) {
    $x = $pair[0]; $name = $pair[1]
    $w = $script:model.wins[$name]; if (-not $w) { continue }
    $reset = [long]$w.reset_at
    $el["Eta$x"].Text = Fmt-Eta $reset
    $pace = Get-Pace $name $reset
    if ($null -ne $pace) {
      $px = $pace / 100.0 * $BARW
      $el["Pace$x"].Margin = [Windows.Thickness]::new([Math]::Max(0.0, [Math]::Min($BARW - 9.0, $px - 4.5)), 0, 0, 0)
      $used = [double]$w.used; $budget = [double]$w.budget
      $pct = 0.0; if ($budget -gt 0) { $pct = $used / $budget * 100.0 }
      Set-MetaRuns $x $pace ($pct - $pace)
    }
  }
}

# ---- 托盘图标(水墨单色圆环 + 最紧窗口已用%) ----
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'Mirasim 额度'; $notify.Visible = $true
$script:curIcon = $null
function New-TrayIcon([object]$pct, [bool]$blackInk) {
  $ink = [System.Drawing.Color]::White; if ($blackInk) { $ink = [System.Drawing.Color]::Black }
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  $track = [System.Drawing.Color]::FromArgb(64, $ink)
  $g.DrawEllipse((New-Object System.Drawing.Pen $track, 3.4), 3, 3, 25, 25)
  if ($null -ne $pct) {
    $sw = [Math]::Max(0.0, [Math]::Min(360.0, 360.0 * [double]$pct / 100.0))
    if ($sw -gt 0) { $g.DrawArc((New-Object System.Drawing.Pen $ink, 3.4), 3, 3, 25, 25, -90, $sw) }
  }
  $txt = '--'; if ($null -ne $pct) { $txt = [Math]::Round([double]$pct).ToString() }
  $fs = 13; if ($txt.Length -ge 3) { $fs = 9 }
  $font = New-Object System.Drawing.Font 'Segoe UI', $fs, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString($txt, $font, (New-Object System.Drawing.SolidBrush $ink), (New-Object System.Drawing.RectangleF 0, 1, 32, 32), $sf)
  $g.Dispose()
  $h = $bmp.GetHicon(); $ico = [System.Drawing.Icon]::FromHandle($h)
  @{ icon = $ico; handle = $h; bmp = $bmp }
}
function Update-Tray {
  $pct = $null; $tips = @()
  if ($script:model) {
    foreach ($pair in @(@('5h', '5h'), @('7d', '7d'), @('7d_fable', 'Fb'))) {
      $w = $script:model.wins[$pair[0]]; if (-not $w) { continue }
      $p = 0.0; if ([double]$w.budget -gt 0) { $p = [double]$w.used / [double]$w.budget * 100.0 }
      if ($null -eq $pct -or $p -gt $pct) { $pct = $p }
      $tips += ('{0} {1:0}%' -f $pair[1], $p)
    }
  }
  $old = $script:curIcon
  $script:curIcon = New-TrayIcon $pct (Test-LightTray)
  $notify.Icon = $script:curIcon.icon
  if ($old) { try { [W32]::DestroyIcon($old.handle) | Out-Null; $old.bmp.Dispose() } catch {} }
  $tip = 'Mirasim 额度(连接中…)'
  if ($tips.Count -gt 0) {
    $tip = '额度 ' + ($tips -join ' · '); if (-not $state.ok) { $tip += ' (未连接)' }
  }
  if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
  $notify.Text = $tip
}

# ---- 面板显示/隐藏 ----
$script:lastHide = 0
function Show-Panel {
  Apply-Theme
  Render-All
  $win.Opacity = 0; $win.Show(); $win.UpdateLayout()
  $scale = [W32]::GetDpiForWindow($hwnd) / 96.0
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $pw = [int]([Math]::Ceiling($win.ActualWidth * $scale)); $ph = [int]([Math]::Ceiling($win.ActualHeight * $scale))
  [W32]::SetWindowPos($hwnd, [IntPtr]::Zero, $wa.Right - $pw - 10, $wa.Bottom - $ph - 10, 0, 0, 0x0015) | Out-Null  # NOSIZE|NOZORDER|NOACTIVATE
  $win.Opacity = 1; $win.Activate() | Out-Null
}
function Hide-Panel { $win.Hide(); $script:lastHide = [Environment]::TickCount }
$win.Add_Deactivated({ if ($win.IsVisible) { Hide-Panel } })
$win.Add_Closing({ param($s, $e) if (-not $script:closing) { $e.Cancel = $true; Hide-Panel } })
$win.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Hide-Panel } })
$el.BtnRf.Add_MouseLeftButtonUp({ $el.St.Text = '刷新中…'; $state.kick = $true })

$notify.Add_MouseClick({ param($s, $e)
    if ($e.Button -eq 'Left') {
      if ($win.IsVisible) { Hide-Panel }
      elseif (([Environment]::TickCount - $script:lastHide) -gt 300) { Show-Panel }
    }
  })

# ---- 托盘右键菜单 ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('打开面板').Add_Click({ Show-Panel })
[void]$menu.Items.Add('刷新').Add_Click({ $state.kick = $true })
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$selfCmd = "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
$miAuto = $menu.Items.Add('开机自启')
$miAuto.Checked = ((Get-ItemProperty $runKey -Name 'MirasimQuotaTray' -EA SilentlyContinue).MirasimQuotaTray -eq $selfCmd)
$miAuto.Add_Click({
    if ($miAuto.Checked) { Remove-ItemProperty $runKey -Name 'MirasimQuotaTray' -EA SilentlyContinue; $miAuto.Checked = $false }
    else { Set-ItemProperty $runKey -Name 'MirasimQuotaTray' -Value $selfCmd; $miAuto.Checked = $true }
  })
[void]$menu.Items.Add('退出').Add_Click({
    $script:closing = $true
    $notify.Visible = $false; $notify.Dispose()
    try { $poller.Stop() } catch {}
    try { $win.Close() } catch {}
    [System.Windows.Forms.Application]::Exit()
  })
$notify.ContextMenuStrip = $menu

# ---- 心跳:1s 界面刷新,数据变更时重渲染 ----
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
$timer.Add_Tick({
    if ($state.rev -ne $script:seenRev) {
      $script:seenRev = $state.rev
      Parse-State
      Update-Tray
      if ($win.IsVisible) { Apply-Theme; Render-All }
    } elseif ($win.IsVisible) { Update-Dynamic }
  })
$timer.Start()

Apply-Theme
Parse-State
Update-Tray
if ($Panel) {
  $t2 = New-Object System.Windows.Forms.Timer; $t2.Interval = 600
  $t2.Add_Tick({ $t2.Stop(); Show-Panel })
  $t2.Start()
}
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))

} catch {
  try { ($_ | Out-String) + "`n" + $_.ScriptStackTrace | Set-Content -Path (Join-Path $env:TEMP 'mqw-tray-err.log') -Encoding UTF8 } catch {}
  throw
}
