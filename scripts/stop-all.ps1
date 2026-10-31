#Requires -Version 7.4
[CmdletBinding()]
param()

Write-Host "`n=== Gracefully Stopping ERP Stack ===" -ForegroundColor Yellow
$containers = @(
    'erp-platform-catalog-service-1',
    'erp-platform-inventory-service-1',
    'erp-platform-auth-service-1',
    'erp-platform-purchasing-service-1',
    'erp-kong',
    'erp-postgres'
)
foreach ($c in $containers) {
    $status = (docker inspect --format "{{.State.Status}}" $c 2>$null)
    if ($status -eq 'running') {
        Write-Host "Stopping $c..."
        docker stop $c | Out-Null
    }
}
Write-Host "All ERP containers stopped." -ForegroundColor Green