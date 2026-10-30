[CmdletBinding()]
param(
    [string]$InstallDir = $(if ($env:TORBOX_INSTALL_DIR) { $env:TORBOX_INSTALL_DIR } else { Join-Path $PSScriptRoot 'torbox-media-server' })
)

$ErrorActionPreference = 'Stop'
$sourceCompose = Join-Path $PSScriptRoot 'docker-compose.yml'
$sourceDockerfile = Join-Path $PSScriptRoot 'Dockerfile.decypharr'
$envFile = Join-Path $InstallDir '.env'
$composeFile = Join-Path $InstallDir 'docker-compose.yml'
$dockerfile = Join-Path $InstallDir 'Dockerfile.decypharr'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

if (-not (Test-Path $envFile)) { Fail "No .env file found at $envFile. Run .\setup.ps1 first." }
if (-not (Test-Path $sourceCompose) -or -not (Test-Path $sourceDockerfile)) {
    Fail 'The repository is missing docker-compose.yml or Dockerfile.decypharr.'
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker is not installed or is not on PATH.' }
docker compose version *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker Compose v2 is required.' }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$backup = Join-Path $InstallDir ("backup-before-repair-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
if (Test-Path $composeFile) { Copy-Item $composeFile $backup -Force }
if (Test-Path $dockerfile) { Copy-Item $dockerfile $backup -Force }
Copy-Item $sourceCompose $composeFile -Force
Copy-Item $sourceDockerfile $dockerfile -Force

Push-Location $InstallDir
try {
    docker compose --env-file .env config -q
    if ($LASTEXITCODE -ne 0) { Fail "The refreshed Compose configuration is invalid. Original files are in $backup." }
    Write-Host "Rebuilding Decypharr and starting the stack..." -ForegroundColor Cyan
    docker compose --env-file .env up -d --build --remove-orphans
    if ($LASTEXITCODE -ne 0) { Fail 'Docker Compose could not start the stack.' }
    Write-Host "Repair complete. Backup: $backup" -ForegroundColor Green
}
finally {
    Pop-Location
}
