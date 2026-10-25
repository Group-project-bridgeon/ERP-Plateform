#Requires -Version 7.4
[CmdletBinding()]
param([switch]$ConfigurationOnly)
$ErrorActionPreference = 'Stop'
$platform = Split-Path $PSScriptRoot -Parent
$inventory = Join-Path (Split-Path $platform -Parent) 'Inventory-Service'
$project = 'inventory-gateway-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$temporary = Join-Path ([IO.Path]::GetTempPath()) $project
$names = @('SECURITY_TEST_DB_PASSWORD','SECURITY_TEST_KEY_DIR','INVENTORY_FIXTURE_PASSWORD','INVENTORY_DB_PASSWORD','INVENTORY_FIXTURE_IMAGE','WAREHOUSE_GATEWAY_ISOLATED','WAREHOUSE_AUTH_DATABASE_URL','WAREHOUSE_INVENTORY_DATABASE_URL','WAREHOUSE_AUTH_URL','WAREHOUSE_INVENTORY_URL','WAREHOUSE_PUBLIC_KEY','WAREHOUSE_NEGATIVE_PRIVATE_KEY','STOCK_GATEWAY_RUN_ID','STOCK_GATEWAY_ISOLATED')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
$compose = @('compose','--project-name',$project,'--env-file',(Join-Path $temporary 'empty.env'),'-f',(Join-Path $platform 'docker-compose.security-test.yml'),'-f',(Join-Path $platform 'docker-compose.inventory-test.yml'))
$started = $false
$imageWorkStarted = $false
$contextImage = "erp/inventory-context-test:$project"
$cleanupFailures = [Collections.Generic.List[string]]::new()
function ContainerSnapshot {
    $ids=@(Invoke-Docker @('ps','-aq','--no-trunc'))
    $snapshot=@{}
    foreach($container in $ids){if($container){$snapshot[$container]=([string](Invoke-Docker @('inspect','--format','{{.Id}}|{{.State.StartedAt}}|{{.State.Running}}|{{.RestartCount}}',$container))).Trim()}}
    return $snapshot
}
function Invoke-Docker([string[]]$DockerArgs) {
    # Keep stderr (including interpolation warnings) out of JSON stdout.
    # Never render raw diagnostics, which can include environment values.
    $output = & docker @DockerArgs 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker fixture operation failed ($($DockerArgs[0])); raw output suppressed." }
    return $output
}
function Fixture([string[]]$FixtureArgs) { Invoke-Docker ($compose + $FixtureArgs) }
function CheckSQL([string]$Database,[string]$Query,[string]$Expected,[string]$Label) {
    $output = Fixture @('exec','-T','postgres','psql','-X','-t','-A','-v','ON_ERROR_STOP=1','-U','security_test','-d',$Database,'-c',$Query)
    if (([string]::Join('',[string[]]@($output))).Trim() -ne $Expected) { throw "Database assertion failed: $Label" }
    Write-Host "PASS: $Label = $Expected"
}
try {
    $normalBefore=ContainerSnapshot
    New-Item -ItemType Directory -Path $temporary | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporary 'empty.env'),'')
    $random = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $env:SECURITY_TEST_DB_PASSWORD = [Convert]::ToHexString($random).ToLowerInvariant()
    $env:STOCK_GATEWAY_RUN_ID=$project
    # Exercise URI-reserved characters through raw PGPASSWORD.
    $env:INVENTORY_FIXTURE_PASSWORD = $env:SECURITY_TEST_DB_PASSWORD + '@:/?#%+$ space'
    $env:INVENTORY_DB_PASSWORD = $env:INVENTORY_FIXTURE_PASSWORD
    $env:INVENTORY_FIXTURE_IMAGE = "erp/inventory-fixture:$project"
    $env:SECURITY_TEST_KEY_DIR = $temporary.Replace('\','/')
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        [IO.File]::WriteAllText((Join-Path $temporary 'private.pem'),$rsa.ExportRSAPrivateKeyPem())
        [IO.File]::WriteAllText((Join-Path $temporary 'public.pem'),$rsa.ExportSubjectPublicKeyInfoPem())
    } finally { $rsa.Dispose() }
    # Validate normal configuration with placeholders, never regular .env.
    $normal = @('compose','--project-name',$project,'--env-file',(Join-Path $platform '.env.example'),'-f',(Join-Path $platform 'docker-compose.yml'))
    Invoke-Docker ($normal + @('config','--quiet')) | Out-Null
    $normalModel = ([string]::Join("`n",[string[]]@(Invoke-Docker ($normal + @('config','--format','json'))))) | ConvertFrom-Json
    if ($normalModel.services.'inventory-service'.ports) { throw 'Inventory must have no default host binding' }
    if ($normalModel.services.'inventory-service'.depends_on.'auth-service') { throw 'Inventory must not depend on Auth runtime' }
    $normalInventory = $normalModel.services.'inventory-service'
    $keyMount = @($normalInventory.volumes | Where-Object { $_.target -eq '/run/secrets/auth-jwt-public.pem' })
    if ($keyMount.Count -ne 1 -or !$keyMount[0].read_only -or $keyMount[0].bind.create_host_path -ne $false) { throw 'Normal public-key mount must fail closed and be read-only' }
    $migrationMount = $normalModel.services.'inventory-migrate'.volumes[0]
    if (!$migrationMount.read_only -or $migrationMount.bind.create_host_path -ne $false) { throw 'Migration mount must fail when source is missing' }
    Write-Host 'PASS: normal Compose validates; Inventory has no host port or Auth runtime dependency.'
    Fixture @('config','--quiet') | Out-Null
    $fixtureModel = ([string]::Join("`n",[string[]]@(Fixture @('config','--format','json')))) | ConvertFrom-Json
    $fixtureKey = @($fixtureModel.services.'inventory-service'.volumes | Where-Object { $_.target -eq '/run/secrets/auth-jwt-public.pem' })
    if ($fixtureKey.Count -ne 1 -or !([IO.Path]::GetFullPath($fixtureKey[0].source)).StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture must replace the regular deployment key' }
    if ($fixtureModel.services.'inventory-service'.ports) { throw 'Fixture Inventory must remain internal' }
    foreach ($service in $fixtureModel.services.PSObject.Properties.Value) {
        if (@($service.volumes | Where-Object { $_.type -eq 'volume' }).Count) { throw 'Fixture must not use named database volumes' }
    }
    Write-Host 'PASS: fixture model uses temporary key, internal Inventory and no named volumes.'
    if ($ConfigurationOnly) { Write-Host 'Configuration-only run: image, Kong parser and runtime checks NOT VERIFIED.'; return }
    $engine = ([string](Invoke-Docker @('info','--format','{{.OSType}}'))).Trim()
    if ($engine -ne 'linux') { throw 'Linux Docker engine required' }
    Invoke-Docker @('run','--rm','-e','KONG_DATABASE=off','-v',"$platform/infrastructure/kong/kong.yml:/kong.yml:ro",'kong:3.9.3','kong','config','parse','/kong.yml') | Out-Null
    Write-Host 'PASS: Kong 3.9.3 declarative parser.'
    # Build from the effective filtered context, not just inspect ignore rules.
    $contextDockerfile = Join-Path $temporary 'Dockerfile.context'
    [IO.File]::WriteAllText($contextDockerfile,@'
FROM alpine:3.22
COPY . /context
RUN test ! -e /context/.env && test ! -d /context/keys && test ! -d /context/.git && test ! -d /context/scripts && test ! -d /context/db && test -z "$(find /context -type f \( -name '*.pem' -o -name '*.key' -o -name '*.zip' -o -name '*_test.go' \) -print)"
'@)
    $imageWorkStarted = $true
    Invoke-Docker @('build','--quiet','-t',$contextImage,'-f',$contextDockerfile,$inventory) | Out-Null
    Write-Host 'PASS: effective build context excludes env, keys, Git, archives and test fixtures.'
    foreach ($service in @('auth-service','catalog-service','inventory-service')) {
        Write-Host "Building disposable $service image."
        Fixture @('build','--quiet',$service) | Out-Null
    }
    $started = $true
    Fixture @('up','--detach','--wait','--wait-timeout','240') | Out-Null
    foreach ($service in @('auth-service','catalog-service','inventory-service')) {
        $uid = ([string]::Join('',[string[]]@(Fixture @('exec','-T',$service,'id','-u')))).Trim()
        if (!$uid -or $uid -eq '0') { throw "$service must run as non-root" }
        Write-Host "PASS: $service runtime UID=$uid"
    }
    Fixture @('exec','-T','inventory-service','test','-r','/run/secrets/auth-jwt-public.pem') | Out-Null
    Fixture @('exec','-T','inventory-service','sh','-c','test ! -e /app/.env && test ! -e /run/secrets/private.pem && test ! -d /app/internal && test -x /app/inventory-service') | Out-Null
    $id = ([string](Fixture @('ps','--quiet','inventory-service'))).Trim()
    $bindings = ([string](Invoke-Docker @('inspect','--format','{{len .HostConfig.PortBindings}}',$id))).Trim()
    if ($bindings -ne '0') { throw 'Disposable Inventory unexpectedly publishes a host port' }
    Write-Host 'PASS: runtime key readable, private key absent, binary-only app, no Inventory host binding.'
    foreach ($probe in @('health','ready')) {
        Fixture @('exec','-T','inventory-service','wget','-qO-',"http://inventory-service:8082/$probe") | Out-Null
        Write-Host "PASS: internal Inventory /$probe HTTP 200"
    }
    $internal = & docker @compose exec -T inventory-service wget -S -O /dev/null http://inventory-service:8082/api/v1/inventory/warehouses 2>&1
    $internalExit = $LASTEXITCODE
    if ($internalExit -eq 0 -or ([string]::Join("`n",[string[]]@($internal))) -notmatch 'HTTP/1\.[01] 401') { throw 'Direct internal unauthenticated request did not return 401' }
    Write-Host 'PASS: direct internal warehouse request HTTP 401.'
    CheckSQL 'inventory_db' "SELECT version::text || ':' || dirty::text FROM schema_migrations" '3:false' 'Inventory migration'
    CheckSQL 'auth_security_test' "SELECT version::text || ':' || dirty::text FROM schema_migrations" '8:false' 'Auth migration dependency'
    CheckSQL 'catalog_security_test' "SELECT version::text || ':' || dirty::text FROM schema_migrations" '3:false' 'Catalog routing fixture migrations'
    CheckSQL 'auth_security_test' "SELECT count(*) FROM identity_permissions WHERE action='read' AND resource IN ('inventory.stock-balances','inventory.stock-movements')" '2' 'Stock read definitions'
    CheckSQL 'inventory_db' "SELECT rolsuper::int+rolcreatedb::int+rolcreaterole::int FROM pg_roles WHERE rolname='inventory_service'" '0' 'Inventory role restricted'
    $dbAddress = ([string](Fixture @('port','postgres','5432'))).Trim()
    $gatewayAddress = ([string](Fixture @('port','kong','8000'))).Trim()
    $env:WAREHOUSE_GATEWAY_ISOLATED = '1'
    $env:WAREHOUSE_AUTH_DATABASE_URL = "postgres://security_test:$($env:SECURITY_TEST_DB_PASSWORD)@${dbAddress}/auth_security_test?sslmode=disable"
    $escapedPassword = [Uri]::EscapeDataString($env:INVENTORY_FIXTURE_PASSWORD)
    $env:WAREHOUSE_INVENTORY_DATABASE_URL = "postgres://inventory_service:${escapedPassword}@${dbAddress}/inventory_db?sslmode=disable"
    $env:WAREHOUSE_AUTH_URL = "http://$gatewayAddress"
    $env:WAREHOUSE_INVENTORY_URL = $env:WAREHOUSE_AUTH_URL
    $env:WAREHOUSE_PUBLIC_KEY = Join-Path $temporary 'public.pem'
    $env:WAREHOUSE_NEGATIVE_PRIVATE_KEY = Join-Path $temporary 'private.pem'
    & go -C $inventory test -count=1 -v ./internal/integration -run '^TestIsolatedAuthInventoryGateway$'
    if ($LASTEXITCODE -ne 0) { throw 'Kong warehouse integration failed' }
    CheckSQL 'inventory_db' 'SELECT count(*) FROM warehouses' '2' 'Persisted warehouse rows'
    CheckSQL 'inventory_db' 'SELECT count(*) FROM warehouses WHERE is_default AND is_active' '1' 'Persisted active default'
    # Preserve the existing warehouse test unchanged, then run independent stock
    # fixtures. Catalog is deliberately unavailable during all stock read requests.
    Fixture @('stop','catalog-service') | Out-Null
    $env:STOCK_GATEWAY_ISOLATED='1'
    & go -C $inventory test -count=1 -timeout=240s -v ./internal/integration -run '^TestStockReadGateway$'
    if($LASTEXITCODE -ne 0){throw 'Kong stock read integration failed'}
    CheckSQL 'inventory_db' 'SELECT count(*) FROM warehouses' '5' 'Warehouse fixture rows after stock setup'
    Fixture @('stop','inventory-service') | Out-Null
    $exitCode = ([string](Invoke-Docker @('inspect','--format','{{.State.ExitCode}}',$id))).Trim()
    if ($exitCode -ne '0') { throw 'Inventory did not shut down gracefully' }
    Write-Host 'PASS: Inventory SIGTERM shutdown exit 0.'
    Write-Host 'PASS: isolated Docker/Kong warehouse verification completed.'
} finally {
    if ($started) {
        try {
            Fixture @('down','--remove-orphans','--rmi','local') | Out-Null
            $remaining = Invoke-Docker @('ps','-a','--filter',"label=com.docker.compose.project=$project",'--format','{{.Names}}')
            if ($remaining) { throw 'fixture containers remain' }
            $networks = Invoke-Docker @('network','ls','--filter',"label=com.docker.compose.project=$project",'--format','{{.Name}}')
            if ($networks) { throw 'fixture network remains' }
            Write-Host 'PASS: only disposable project containers/network removed; tmpfs fixture data removed.'
        } catch { $cleanupFailures.Add("Disposable project cleanup failed: $project") }
    }
    # Also clean project-named build images if a later build fails before up.
    if ($imageWorkStarted) { foreach ($tag in @($contextImage,$env:INVENTORY_FIXTURE_IMAGE,"$project-auth-service","$project-catalog-service")) {
        if ($tag) {
            & docker image inspect --format '{{.Id}}' $tag *> $null
            if ($LASTEXITCODE -eq 0) { & docker image rm $tag *> $null; if ($LASTEXITCODE -ne 0) { $cleanupFailures.Add('Fixture image cleanup failed') } }
        }
    } }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
    $resolved = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -ne $project) { throw 'Refusing temporary cleanup outside generated directory' }
    try { if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force } } catch { $cleanupFailures.Add('Temporary fixture file cleanup failed') }
    if ($cleanupFailures.Count) { throw ($cleanupFailures -join '; ') }
    if($null -ne $normalBefore){foreach($container in $normalBefore.Keys){$after=([string](Invoke-Docker @('inspect','--format','{{.Id}}|{{.State.StartedAt}}|{{.State.Running}}|{{.RestartCount}}',$container))).Trim();if($after -ne $normalBefore[$container]){throw 'A pre-existing container identity/start/state changed during verification'}};Write-Host "PASS: $($normalBefore.Count) pre-existing containers retained IDs/start times/states/restart counts."}
    Write-Host 'PASS: generated fixture artifacts cleaned; previous environment restored.'
}
