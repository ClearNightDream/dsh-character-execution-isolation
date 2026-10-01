param(
    [string]$DshRoot = $env:DSH_ROOT,
    [int]$Port = 3080
)

if (-not $DshRoot) {
    throw "DSH_ROOT is not set. Pass -DshRoot or set `$env:DSH_ROOT."
}

$DshHome = Join-Path $DshRoot "dsh-home"
$DshSource = Join-Path $DshRoot "deepseek-harness"
$WorkerHome = Join-Path $DshRoot "worker-home"
$CorepackHome = Join-Path $DshRoot ".corepack"
$CertPath = Join-Path $DshRoot "certs/proxy-ca.pem"

$env:DSH_HOME = $DshHome
$env:COREPACK_HOME = $CorepackHome

if (Test-Path -LiteralPath $CertPath) {
    $env:NODE_EXTRA_CA_CERTS = $CertPath
}

# Model traffic should not go through a development proxy.
Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:http_proxy -ErrorAction SilentlyContinue
Remove-Item Env:https_proxy -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath (Join-Path $WorkerHome "profiles\worker"))) {
    $savedDshHome = $env:DSH_HOME
    $env:DSH_HOME = $WorkerHome
    Push-Location $DshSource
    corepack pnpm dsh --profile worker --from-default-profile sdk --dump-config | Out-Null
    Pop-Location
    $env:DSH_HOME = $savedDshHome
}

Push-Location $DshSource
corepack pnpm dsh web --no-open --port $Port
Pop-Location
