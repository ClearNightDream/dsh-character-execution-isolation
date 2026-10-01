param(
    [string]$WorkerHome = "$PSScriptRoot\worker-home",
    [string]$DshSource = "$PSScriptRoot\deepseek-harness"
)

# Initialize a clean worker profile for the dsh-sdk provider.
# The provider does not auto-create profiles, so this must run once.

if (-not (Test-Path -LiteralPath $DshSource)) {
    throw "DSH source directory not found: $DshSource"
}

$workerProfile = Join-Path $WorkerHome "profiles\worker"
if (Test-Path -LiteralPath $workerProfile) {
    Write-Output "Worker profile already exists: $workerProfile"
    exit 0
}

New-Item -ItemType Directory -Path $WorkerHome -Force | Out-Null

$savedDshHome = $env:DSH_HOME
$savedCorepackHome = $env:COREPACK_HOME

try {
    $env:DSH_HOME = $WorkerHome
    if (-not $env:COREPACK_HOME) {
        $env:COREPACK_HOME = Join-Path (Split-Path $DshSource -Parent) ".corepack"
    }

    Push-Location $DshSource
    corepack pnpm dsh --profile worker --from-default-profile sdk --dump-config | Out-Null
    Pop-Location

    if (-not (Test-Path -LiteralPath $workerProfile)) {
        throw "Worker profile was not created: $workerProfile"
    }

    Write-Output "Worker profile created: $workerProfile"
}
finally {
    $env:DSH_HOME = $savedDshHome
    $env:COREPACK_HOME = $savedCorepackHome
}
