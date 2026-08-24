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
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
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
    for ($i = 0; $i -lt 20; $i++) { if ($state.kick) { $state.kick = $false; break }; Start-Sleep -Milliseconds 500 }
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
        Topmost="True" ShowActivated="True" SizeToContent="Height" Width="344"
        AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"
        TextOptions.TextFormattingMode="Display">
  <Border x:Name="Root" BorderThickness="1" CornerRadius="8" Margin="16" RenderTransformOrigin="0.85,1">
    <Border.RenderTransform><ScaleTransform x:Name="RootScale"/></Border.RenderTransform>
    <Border.Effect><DropShadowEffect x:Name="RootShadow" Color="#000000" BlurRadius="22" ShadowDepth="5" Direction="270" Opacity="0.5"/></Border.Effect>
    <StackPanel>
      <Grid Margin="14,10,10,2">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="Dot" Width="6" Height="6" Margin="0,1,7,0" VerticalAlignment="Center" StrokeThickness="1"/>
          <TextBlock x:Name="HdTitle" Text="额度" FontSize="13" FontWeight="SemiBold"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="Asof" VerticalAlignment="Center" FontSize="10.5"/>
          <Border x:Name="BtnPin" Width="21" Height="21" CornerRadius="5" Margin="7,0,0,0" Cursor="Hand" Background="Transparent">
            <TextBlock x:Name="BtnPinTxt" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center" Text="&#xE718;"/>
          </Border>
        </StackPanel>
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
$names = @('Root', 'Dot', 'HdTitle', 'Asof', 'Banner', 'BannerTxt', 'Hair', 'St', 'BtnRf', 'BtnRfTxt', 'BtnPin', 'BtnPinTxt')
foreach ($x in '5', '7', 'F') { $names += @("Row$x", "Top$x", "Pct$x", "Track$x", "Fill$x", "Pace$x", "PL$x", "PT$x", "Meta$x", "Eta$x") }
foreach ($n in $names) { $el[$n] = $win.FindName($n) }
$scaleT = $win.FindName('RootScale')
$shadowFx = $win.FindName('RootShadow')

# 逐像素透明窗:圆角/阴影全由 WPF 绘制,缩放淡入淡出时整体一起显隐(不用 DWM 背材,避免动画后方残留灰板)
$helper = New-Object Windows.Interop.WindowInteropHelper $win
$hwnd = $helper.EnsureHandle()

# ---- 水墨调色板(跟随应用明暗) ----
$script:P = $null
$script:isLight = $null
function Apply-Theme {
  $light = Test-LightApps
  if ($script:isLight -eq $light -and $script:P) { return }
  $script:isLight = $light
  if ($light) {
    $bg = '#F5F7F7F6'
    $script:P = @{
      ink = New-Brush '#E0000000'; ink2 = New-Brush '#85000000'; ink3 = New-Brush '#57000000'
      track = New-Brush '#1A000000'; hair = New-Brush '#14000000'; btn = New-Brush '#0D000000'
      bg = New-Brush $bg; bd = New-Brush '#1F000000'; none = New-Brush '#00000000'
    }
  } else {
    $bg = '#F51D1D20'
    $script:P = @{
      ink = New-Brush '#E6FFFFFF'; ink2 = New-Brush '#8CFFFFFF'; ink3 = New-Brush '#57FFFFFF'
      track = New-Brush '#24FFFFFF'; hair = New-Brush '#17FFFFFF'; btn = New-Brush '#14FFFFFF'
      bg = New-Brush $bg; bd = New-Brush '#1FFFFFFF'; none = New-Brush '#00FFFFFF'
    }
  }
  $P = $script:P
  $sop = 0.5; if ($light) { $sop = 0.28 }
  $shadowFx.Opacity = $sop
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
  Update-PinVisual
  Render-All
}

# ---- 置顶固定(图钉) ----
$script:pinned = $false
function Update-PinVisual {
  if (-not $script:P) { return }
  if ($script:pinned) {
    $el.BtnPin.Background = $script:P.btn; $el.BtnPinTxt.Foreground = $script:P.ink
    $el.BtnPinTxt.Text = [string][char]0xE77A   # Unpin
  } else {
    $el.BtnPin.Background = $script:P.none; $el.BtnPinTxt.Foreground = $script:P.ink3
    $el.BtnPinTxt.Text = [string][char]0xE718   # Pin
  }
  if ($script:miPin) { $script:miPin.Checked = $script:pinned }
}
function Set-Pinned([bool]$v) { $script:pinned = $v; Update-PinVisual }

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

# ---- 托盘图标(三枚独立图标:5h / 7d / 7d Fable,各一枚正常大小圆环+中央数字) ----
# 创建顺序 Fable→7d→5h:Windows 新图标插在托盘左端,最终视觉左→右 = 5h / 7d / Fable
$notifyF = New-Object System.Windows.Forms.NotifyIcon; $notifyF.Text = '额度 7d Fable'; $notifyF.Visible = $true
$notify7 = New-Object System.Windows.Forms.NotifyIcon; $notify7.Text = '额度 7d'; $notify7.Visible = $true
$notify5 = New-Object System.Windows.Forms.NotifyIcon; $notify5.Text = '额度 5h'; $notify5.Visible = $true
$trayIcons = @{ '5' = $notify5; '7' = $notify7; 'F' = $notifyF }
$script:curIcon = @{}
$script:trayKey = @{}
function New-WinIcon([object]$pct, [bool]$blackInk) {
  $ink = [System.Drawing.Color]::White; if ($blackInk) { $ink = [System.Drawing.Color]::Black }
  # 按托盘真实图标尺寸原生绘制(SM_CXSMICON),避免缩放发糊
  $n = [W32]::GetSystemMetrics(49); if ($n -lt 16) { $n = 16 }
  $s = $n / 32.0
  $bmp = New-Object System.Drawing.Bitmap $n, $n
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  $pt = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, $ink)), (3.3 * $s)
  $g.DrawEllipse($pt, (2.5 * $s), (2.5 * $s), (27.0 * $s), (27.0 * $s)); $pt.Dispose()
  if ($null -ne $pct) {
    # 阈值变色:≥70 黄,≥90 红,其余水墨
    $arc = $ink
    if ([double]$pct -ge 90) { $arc = [System.Drawing.Color]::FromArgb(255, 69, 58) }
    elseif ([double]$pct -ge 70) { $arc = [System.Drawing.Color]::FromArgb(255, 159, 10) }
    $sw = [Math]::Max(0.0, [Math]::Min(360.0, 360.0 * [double]$pct / 100.0))
    if ($sw -gt 0) {
      $pa = New-Object System.Drawing.Pen $arc, (3.3 * $s)
      $pa.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pa.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
      $g.DrawArc($pa, (2.5 * $s), (2.5 * $s), (27.0 * $s), (27.0 * $s), -90, [float]$sw); $pa.Dispose()
    }
  }
  $txt = '--'; if ($null -ne $pct) { $txt = [Math]::Round([double]$pct).ToString() }
  $fs = 13.5 * $s; if ($txt.Length -ge 3) { $fs = 9.5 * $s }
  $font = New-Object System.Drawing.Font 'Segoe UI', $fs, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $br = New-Object System.Drawing.SolidBrush $ink
  $g.DrawString($txt, $font, $br, (New-Object System.Drawing.RectangleF 0, (1 * $s), $n, $n), $sf)
  $br.Dispose(); $font.Dispose(); $g.Dispose()
  $h = $bmp.GetHicon(); $ico = [System.Drawing.Icon]::FromHandle($h)
  @{ icon = $ico; handle = $h; bmp = $bmp }
}
function Set-OneTray([string]$k, [object]$pct, [string]$tip, [bool]$blackInk) {
  $ni = $trayIcons[$k]
  if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
  $pctR = -1; if ($null -ne $pct) { $pctR = [Math]::Round([double]$pct, 0) }
  $key = '{0}|{1}|{2}' -f $pctR, $blackInk, $tip
  if ($key -eq $script:trayKey[$k]) { return }
  $script:trayKey[$k] = $key
  $old = $script:curIcon[$k]
  $script:curIcon[$k] = New-WinIcon $pct $blackInk
  $ni.Icon = $script:curIcon[$k].icon
  if ($old) { try { [W32]::DestroyIcon($old.handle) | Out-Null; $old.bmp.Dispose() } catch {} }
  $ni.Text = $tip
}
function Update-Tray {
  $blackInk = Test-LightTray
  $sfx = ''; if (-not $state.ok) { $sfx = ' (未连接)' }
  foreach ($row in @(@('5', '5h', '5 小时'), @('7', '7d', '7 天'), @('F', '7d_fable', '7 天 Fable'))) {
    $k = $row[0]; $name = $row[1]; $label = $row[2]
    $w = $null; if ($script:model) { $w = $script:model.wins[$name] }
    if ($k -eq 'F') {
      # Fable 池缺席(降级)时隐藏第三枚图标
      $trayIcons['F'].Visible = [bool]$w
      if (-not $w) { continue }
    }
    if ($w) {
      $p = 0.0; if ([double]$w.budget -gt 0) { $p = [double]$w.used / [double]$w.budget * 100.0 }
      $tip = '{0} 已用 {1:0.0}%{2}' -f $label, $p, $sfx
      Set-OneTray $k $p $tip $blackInk
    } else {
      Set-OneTray $k $null ($label + ' 连接中…') $blackInk
    }
  }
}

# ---- 面板显示/隐藏(快速小幅缩放 + 淡入淡出) ----
$script:lastHide = 0
$script:animSeq = 0
function New-Anim([double]$to, [int]$ms) {
  $a = New-Object Windows.Media.Animation.DoubleAnimation
  $a.To = $to; $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms))
  $e = New-Object Windows.Media.Animation.CubicEase; $e.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
  $a.EasingFunction = $e; $a
}
function Clear-Anim {
  $el.Root.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
  $scaleT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $null)
  $scaleT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $null)
}
# 动画收尾定时器(顶层单实例:清除动画钟、钉住终值/真正隐藏)
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Add_Tick({
    $animTimer.Stop()
    if ($script:animSeq -ne $script:animGoal) { return }
    Clear-Anim
    if ($script:animMode -eq 'open') { $el.Root.Opacity = 1; $scaleT.ScaleX = 1; $scaleT.ScaleY = 1 }
    else { $win.Hide() }
  })
function Start-AnimEnd([string]$mode, [int]$ms) {
  $script:animMode = $mode; $script:animGoal = $script:animSeq
  $animTimer.Stop(); $animTimer.Interval = $ms; $animTimer.Start()
}
function Show-Panel {
  $script:animSeq++
  $state.kick = $true                    # 打开即拉最新数据
  Apply-Theme
  Render-All
  Clear-Anim
  $el.Root.Opacity = 0; $scaleT.ScaleX = 0.96; $scaleT.ScaleY = 0.96
  $win.Show(); $win.UpdateLayout()
  $scale = [W32]::GetDpiForWindow($hwnd) / 96.0
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $pw = [int]([Math]::Ceiling($win.ActualWidth * $scale)); $ph = [int]([Math]::Ceiling($win.ActualHeight * $scale))
  # 窗口含 16 DIP 阴影边距,面板可见边缘距屏幕边 10 DIP → 窗口边整体外扩 6 DIP
  $inset = [int](6 * $scale)
  [W32]::SetWindowPos($hwnd, [IntPtr]::Zero, $wa.Right - $pw + $inset, $wa.Bottom - $ph + $inset, 0, 0, 0x0015) | Out-Null  # NOSIZE|NOZORDER|NOACTIVATE
  $el.Root.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 1.0 150))
  $scaleT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-Anim 1.0 150))
  $scaleT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-Anim 1.0 150))
  $win.Activate() | Out-Null
  Start-AnimEnd 'open' 260
}
function Hide-Panel {
  if (-not $win.IsVisible) { return }
  $script:animSeq++
  $script:lastHide = [Environment]::TickCount
  $el.Root.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0.0 110))
  $scaleT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-Anim 0.97 110))
  $scaleT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-Anim 0.97 110))
  Start-AnimEnd 'close' 140
}
$win.Add_Deactivated({ if (-not $script:pinned -and $win.IsVisible) { Hide-Panel } })
$win.Add_Closing({ param($s, $e) if (-not $script:closing) { $e.Cancel = $true; Hide-Panel } })
$win.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Hide-Panel } })
$el.BtnRf.Add_MouseLeftButtonUp({ $el.St.Text = '刷新中…'; $state.kick = $true })
$el.BtnPin.Add_MouseLeftButtonUp({ Set-Pinned (-not $script:pinned) })

$trayClick = { param($s, $e)
  if ($e.Button -eq 'Left') {
    if ($win.IsVisible) { Hide-Panel }
    elseif (([Environment]::TickCount - $script:lastHide) -gt 300) { Show-Panel }
  }
}
foreach ($ni in @($notify5, $notify7, $notifyF)) { $ni.Add_MouseClick($trayClick) }

# ---- 托盘右键菜单 ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('打开面板').Add_Click({ Show-Panel })
$script:miPin = $menu.Items.Add('置顶固定')
$script:miPin.Add_Click({ Set-Pinned (-not $script:pinned) })
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
    foreach ($ni in @($notify5, $notify7, $notifyF)) { try { $ni.Visible = $false; $ni.Dispose() } catch {} }
    try { $poller.Stop() } catch {}
    try { $win.Close() } catch {}
    [System.Windows.Forms.Application]::Exit()
  })
foreach ($ni in @($notify5, $notify7, $notifyF)) { $ni.ContextMenuStrip = $menu }

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
