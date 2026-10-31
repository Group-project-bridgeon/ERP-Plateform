#Requires -Version 7.4
[CmdletBinding()]
param()

$platform = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path $platform -Parent
$localEnv = Join-Path $workspace "security-work\opening-stock-local\20261026-121217\local.env"

Write-Host "`n=== Starting Full ERP Stack (with Opening Stock TLS) ===" -ForegroundColor Cyan

# 1. Ensure PostgreSQL is running and healthy
$pgStatus = (docker inspect --format "{{.State.Status}}" erp-postgres 2>$null)
if ($pgStatus -ne 'running') {
    Write-Host "Starting erp-postgres..." -ForegroundColor Yellow
    docker start erp-postgres | Out-Null
    do {
        Start-Sleep -Seconds 2
        $health = (docker inspect --format "{{.State.Health.Status}}" erp-postgres 2>$null)
    } while ($health -ne 'healthy')
    Write-Host "PostgreSQL is healthy." -ForegroundColor Green
} else {
    Write-Host "PostgreSQL is already running." -ForegroundColor Green
}

# 2. Bring up all microservices and Kong gateway
Write-Host "Starting application services and Kong..." -ForegroundColor Yellow
& (Join-Path $PSScriptRoot "opening-local-compose.ps1") `
    -LocalEnvFile $localEnv `
    -Action Up `
    -Services @('auth-service', 'catalog-service', 'inventory-service', 'purchasing-service', 'kong')

# 3. Reload Kong DNS so it resolves all fresh container IPs
docker exec erp-kong kong reload 2>$null | Out-Null

Write-Host "`n=== All ERP Services Are LIVE on http://localhost:8000 ===" -ForegroundColor Green
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"