# Mirasim Quota Widget installer
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1
# Injects quota-widget.js into the active version's renderer and web UIs.
# Re-run after each mirasim self-update.

$ErrorActionPreference = 'Stop'
$appRoot = Join-Path $env:USERPROFILE '.mirasim\app'
$src = Join-Path $PSScriptRoot 'quota-widget.js'
if (-not (Test-Path $src)) { throw "missing $src" }

$state = Get-Content (Join-Path $appRoot 'state.json') -Raw | ConvertFrom-Json
$ver = $state.good
if (-not $ver) { throw 'cannot read active version from state.json' }
$verDir = Join-Path $appRoot $ver
Write-Host "target version: $ver ($verDir)"

$marker = 'quota-widget.js'
$tag = '    <script type="module" crossorigin src="./assets/quota-widget.js"></script><!-- mirasim-quota-widget -->'

foreach ($ui in @('renderer', 'web')) {
    $assets = Join-Path $verDir "$ui\assets"
    $html = Join-Path $verDir "$ui\index.html"
    if (-not (Test-Path $html)) { Write-Host "skip $ui (no index.html)"; continue }

    Copy-Item $src (Join-Path $assets 'quota-widget.js') -Force
    $doc = Get-Content $html -Raw
    if ($doc -notmatch [regex]::Escape($marker)) {
        $doc = $doc -replace '</head>', "$tag`r`n  </head>"
        [IO.File]::WriteAllText($html, $doc, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "$ui/index.html patched"
    } else {
        Write-Host "$ui/index.html already patched, js refreshed"
    }
}

# register maintenance task: re-injects after mirasim self-updates + budget calibration
$vbs = Join-Path $PSScriptRoot 'silent.vbs'
& schtasks /Create /TN 'MirasimQuotaBudget' /TR "wscript.exe `"$vbs`"" /SC MINUTE /MO 5 /F | Out-Null
Write-Host 'maintenance task MirasimQuotaBudget registered (every 5 min: auto re-inject + budget probe)'
# run one maintenance pass right now
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'probe-budget.ps1')
Write-Host 'maintenance pass executed'

Write-Host 'done. Press Ctrl+R in the Mirasim window to reload the UI (sessions are unaffected).'
