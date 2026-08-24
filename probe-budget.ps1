# Mirasim quota widget maintenance (runs from scheduled task MirasimQuotaBudget)
# 1. Re-injects quota-widget.js into EVERY payload version dir (incl. freshly
#    downloaded, not-yet-active ones) so the widget survives mirasim self-updates.
# 2. Probes the hub port for /v1/limits raw numbers and writes quota-budget.json
#    into every web dir for the widget's total-budget auto-calibration.

$ErrorActionPreference = 'SilentlyContinue'
$appRoot = Join-Path $env:USERPROFILE '.mirasim\app'
$src = Join-Path $PSScriptRoot 'quota-widget.js'
if (-not (Test-Path $src) -or -not (Test-Path $appRoot)) { exit 0 }

$marker = 'quota-widget.js'
$tag = '    <script type="module" crossorigin src="./assets/quota-widget.js"></script><!-- mirasim-quota-widget -->'

# ---- 1) injection maintenance across all version dirs ----
foreach ($verDir in Get-ChildItem $appRoot -Directory) {
    foreach ($ui in @('renderer', 'web')) {
        $html = Join-Path $verDir.FullName "$ui\index.html"
        $assets = Join-Path $verDir.FullName "$ui\assets"
        if (-not (Test-Path $html) -or -not (Test-Path $assets)) { continue }
        $dst = Join-Path $assets 'quota-widget.js'
        $needCopy = -not (Test-Path $dst)
        if (-not $needCopy) {
            $needCopy = (Get-Item $src).LastWriteTimeUtc -gt (Get-Item $dst).LastWriteTimeUtc
        }
        if ($needCopy) { Copy-Item $src $dst -Force }
        $doc = Get-Content $html -Raw
        if ($doc -notmatch [regex]::Escape($marker)) {
            $doc = $doc -replace '</head>', "$tag`r`n  </head>"
            [IO.File]::WriteAllText($html, $doc, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}

# ---- 2) budget probe ----
$pids = (Get-Process Mirasim -ErrorAction SilentlyContinue).Id
if (-not $pids) { exit 0 }
$ports = Get-NetTCPConnection -State Listen |
    Where-Object { $pids -contains $_.OwningProcess -and ($_.LocalAddress -eq '127.0.0.1') } |
    Select-Object -ExpandProperty LocalPort -Unique

$doc = $null
foreach ($port in $ports) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/v1/limits" -TimeoutSec 3 -UseBasicParsing
        if ($resp.StatusCode -ne 200) { continue }
        $j = $resp.Content | ConvertFrom-Json
        if ($j.windows -and $j.windows[0].budget) { $doc = $j; break }
    } catch {}
}
if (-not $doc) { exit 0 }

$out = [ordered]@{ asOf = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); windows = [ordered]@{} }
foreach ($w in $doc.windows) {
    $out.windows[$w.name] = [ordered]@{ used = $w.used; budget = $w.budget; reset_at = $w.reset_at }
}
$json = $out | ConvertTo-Json -Depth 5 -Compress

foreach ($verDir in Get-ChildItem $appRoot -Directory) {
    $webDir = Join-Path $verDir.FullName 'web'
    if (Test-Path $webDir) {
        [IO.File]::WriteAllText((Join-Path $webDir 'quota-budget.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
}
