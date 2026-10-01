param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('readonly', 'autonomous', 'open')]
    [string]$Mode,

    [string]$DshRoot = $env:DSH_ROOT
)

if (-not $DshRoot) {
    throw "DSH_ROOT is not set. Pass -DshRoot or set `$env:DSH_ROOT."
}

$source = Join-Path $DshRoot "worker-$Mode.patch.yml"
$target = Join-Path $DshRoot "worker-profile.patch.yml"
$start = Join-Path $PSScriptRoot "start-web.ps1"

if (-not (Test-Path -LiteralPath $source)) {
    throw "patch template not found: $source"
}

Copy-Item -LiteralPath $source -Destination $target -Force
Write-Output "Switched to $Mode. Restart the web host to apply the worker profile."
Write-Output "Launcher: $start"
