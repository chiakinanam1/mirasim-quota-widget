# Mirasim 额度托盘小工具 — 托盘图标(7d 已用%)+ 点击弹出原样式水墨毛玻璃面板(Chrome --app 承载 panel.html)
# 启动:powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File quota-tray.ps1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dir = Split-Path -Parent $PSCommandPath
$html = Join-Path $dir 'panel.html'
$chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
$udd = Join-Path $env:TEMP 'mqw-panel-profile'
$WS = 'ws://127.0.0.1:4970/ws'
$BUDGET = @{ '5h' = 156800.0; '7d' = 560000.0; '7d_fable' = 296800.0 }
$state = [hashtable]::Synchronized(@{ windows = $null; connected = $false })

# Win32
Add-Type @'
using System; using System.Runtime.InteropServices;
public class U {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h,int i,int v);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int t,uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public delegate bool EnumProc(IntPtr h,IntPtr l);
  public static IntPtr Find(uint pid){ IntPtr r=IntPtr.Zero; EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h,out p); if(p==pid && IsWindowVisible(h)){ r=h; return false;} return true;}, IntPtr.Zero); return r; }
}
'@
[U]::SetProcessDPIAware() | Out-Null
$GWL_STYLE = -16; $WS_POPUP = -2147483648; $WS_VISIBLE = 0x10000000
$HWND_TOPMOST = [IntPtr]-1; $SWP_NOSIZE = 0x1; $SWP_NOMOVE = 0x2; $SWP_SHOW = 0x40; $SWP_FRAMECHANGED = 0x20

# ---- 后台 WebSocket(供托盘图标数字用)----
$wsScript = {
  param($state, $WS)
  while ($true) {
    try {
      $c = New-Object System.Net.WebSockets.ClientWebSocket
      $cts = New-Object System.Threading.CancellationTokenSource
      $c.ConnectAsync([Uri]$WS, $cts.Token).Wait(4000)
      if ($c.State -eq 'Open') {
        $state.connected = $true
        $req = [Text.Encoding]::UTF8.GetBytes('{"type":"getRelay"}'); $seg = New-Object System.ArraySegment[byte] (, $req)
        $buf = New-Object byte[] 65536; $last = 0
        while ($c.State -eq 'Open') {
          $now = [Environment]::TickCount
          if ($last -eq 0 -or $now - $last -ge 30000) { $c.SendAsync($seg, 'Text', $true, $cts.Token).Wait(4000); $last = $now }
          $r = $c.ReceiveAsync((New-Object System.ArraySegment[byte] (, $buf)), $cts.Token)
          if (-not $r.Wait(35000)) { break }
          $res = $r.Result; if ($res.MessageType -eq 'Close') { break }
          $s = [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
          while (-not $res.EndOfMessage) { $r2 = $c.ReceiveAsync((New-Object System.ArraySegment[byte] (, $buf)), $cts.Token); $r2.Wait(10000); $res = $r2.Result; $s += [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count) }
          if ($s.Contains('"type":"relay"')) { try { $m = $s | ConvertFrom-Json; if ($m.relay.usage.windows) { $state.windows = $m.relay.usage.windows } } catch {} }
        }
      }
    } catch {}
    $state.connected = $false; Start-Sleep -Seconds 3
  }
}
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
$psw = [powershell]::Create(); $psw.Runspace = $rs
[void]$psw.AddScript($wsScript).AddArgument($state).AddArgument($WS); [void]$psw.BeginInvoke()

function Get-W([string]$l) { if ($state.windows) { foreach ($w in $state.windows) { if ($w.label -eq $l) { return $w } } } return $null }
function Tone([double]$p) { if ($p -ge 85) { [System.Drawing.Color]::FromArgb(255, 69, 58) } elseif ($p -ge 60) { [System.Drawing.Color]::FromArgb(255, 159, 10) } else { [System.Drawing.Color]::FromArgb(48, 209, 88) } }

# ---- 托盘图标(圆环 + 7d 已用%)----
function New-Icon([object]$pct) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 255, 255, 255)), 3), 3, 3, 25, 25)
  if ($null -ne $pct) { $sw = [Math]::Max(0, [Math]::Min(360, 360 * $pct / 100)); if ($sw -gt 0) { $g.DrawArc((New-Object System.Drawing.Pen ((Tone $pct), 3)), 3, 3, 25, 25, -90, $sw) } }
  $txt = if ($null -eq $pct) { '--' } else { [Math]::Round($pct).ToString() }
  $fs = if ($txt.Length -ge 3) { 9 } else { 13 }
  $font = New-Object System.Drawing.Font 'Segoe UI', $fs, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString($txt, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 1, 32, 32), $sf)
  $g.Dispose()
  $h = $bmp.GetHicon(); $ico = [System.Drawing.Icon]::FromHandle($h)
  @{ icon = $ico; handle = $h; bmp = $bmp }
}
$notify = New-Object System.Windows.Forms.NotifyIcon; $notify.Text = 'Mirasim 额度'; $notify.Visible = $true
$script:cur = $null
function Set-Tray {
  $w7 = Get-W '7d'; $pct = if ($w7) { [double]$w7.usedPercent } else { $null }
  $old = $script:cur; $script:cur = New-Icon $pct; $notify.Icon = $script:cur.icon
  if ($old) { try { [U]::DestroyIcon($old.handle) | Out-Null; $old.bmp.Dispose() } catch {} }
  $notify.Text = if ($w7) { "Mirasim 7d 已用 $([Math]::Round($pct))%" } else { 'Mirasim 额度(连接中…)' }
}

# ---- 面板窗口(Chrome --app 承载 panel.html)----
$script:panelProc = $null
$script:panelHwnd = [IntPtr]::Zero
$PW = 272; $PH = 190
function Hide-Panel { if ($script:panelHwnd -ne [IntPtr]::Zero) { [U]::ShowWindow($script:panelHwnd, 0) | Out-Null } }
function Show-Panel {
  # 已有窗口则显示并置顶
  if ($script:panelProc -and -not $script:panelProc.HasExited -and $script:panelHwnd -ne [IntPtr]::Zero) {
    $sc = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $sc.Right - $PW - 12; $y = $sc.Bottom - $PH - 12
    [U]::SetWindowPos($script:panelHwnd, $HWND_TOPMOST, $x, $y, $PW, $PH, ($SWP_SHOW)) | Out-Null
    [U]::ShowWindow($script:panelHwnd, 5) | Out-Null
    return
  }
  # 启动 chrome --app
  $args = @("--app=file:///$($html -replace '\\','/')", "--user-data-dir=$udd", "--window-size=$PW,$PH",
    '--disable-features=Translate,msEdgeTranslate', '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--app-auto-launched', '--force-app-mode', '--default-background-color=00000000')
  $script:panelProc = Start-Process $chrome -ArgumentList $args -PassThru
  # 等窗口出现,去边框+置顶+定位
  $deadline = (Get-Date).AddSeconds(6); $hwnd = [IntPtr]::Zero
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $hwnd = [U]::Find([uint32]$script:panelProc.Id)
    if ($hwnd -ne [IntPtr]::Zero) { break }
  }
  if ($hwnd -ne [IntPtr]::Zero) {
    $script:panelHwnd = $hwnd
    $style = [U]::GetWindowLong($hwnd, $GWL_STYLE)
    [U]::SetWindowLong($hwnd, $GWL_STYLE, ($WS_POPUP -bor $WS_VISIBLE)) | Out-Null
    $sc = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $sc.Right - $PW - 12; $y = $sc.Bottom - $PH - 12
    [U]::SetWindowPos($hwnd, $HWND_TOPMOST, $x, $y, $PW, $PH, ($SWP_FRAMECHANGED -bor $SWP_SHOW)) | Out-Null
  }
}
$script:visible = $false
$notify.Add_MouseClick({ param($s, $e)
    if ($e.Button -eq 'Left') {
      if ($script:visible -and $script:panelHwnd -ne [IntPtr]::Zero) { Hide-Panel; $script:visible = $false }
      else { Show-Panel; $script:visible = $true }
    }
  })

# 右键菜单
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add('刷新').Add_Click({ Set-Tray })
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$selfCmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
$miAuto = $menu.Items.Add('开机自启')
$miAuto.Checked = ((Get-ItemProperty $runKey -Name 'MirasimQuotaTray' -EA SilentlyContinue).MirasimQuotaTray -eq $selfCmd)
$miAuto.Add_Click({ if ($miAuto.Checked) { Remove-ItemProperty $runKey -Name 'MirasimQuotaTray' -EA SilentlyContinue; $miAuto.Checked = $false } else { Set-ItemProperty $runKey -Name 'MirasimQuotaTray' -Value $selfCmd; $miAuto.Checked = $true } })
$menu.Items.Add('退出').Add_Click({ $notify.Visible = $false; try { if ($script:panelProc -and -not $script:panelProc.HasExited) { $script:panelProc.Kill() } } catch {}; try { $psw.Stop() } catch {}; [System.Windows.Forms.Application]::Exit() })
$notify.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000; $timer.Add_Tick({ Set-Tray }); $timer.Start()
Set-Tray
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
