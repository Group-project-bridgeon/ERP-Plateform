#Requires -Version 7.4
[CmdletBinding()]
param([switch]$ConfigurationOnly,[switch]$OpeningStock,[switch]$StockAdjustments,[switch]$Reservations,[switch]$Fulfillment)
if ($Fulfillment) { $Reservations=$true }
if ($Reservations) { $StockAdjustments=$true }
if ($StockAdjustments) { $OpeningStock=$true }
$ErrorActionPreference = 'Stop'
$platform = Split-Path $PSScriptRoot -Parent
$inventory = Join-Path (Split-Path $platform -Parent) 'Inventory-Service'
$project = 'inventory-gateway-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$temporary = Join-Path ([IO.Path]::GetTempPath()) $project
$names = @('SECURITY_TEST_DB_PASSWORD','SECURITY_TEST_KEY_DIR','INVENTORY_FIXTURE_PASSWORD','INVENTORY_DB_PASSWORD','INVENTORY_FIXTURE_IMAGE','WAREHOUSE_GATEWAY_ISOLATED','WAREHOUSE_AUTH_DATABASE_URL','WAREHOUSE_INVENTORY_DATABASE_URL','WAREHOUSE_AUTH_URL','WAREHOUSE_INVENTORY_URL','WAREHOUSE_PUBLIC_KEY','WAREHOUSE_NEGATIVE_PRIVATE_KEY','STOCK_GATEWAY_RUN_ID','STOCK_GATEWAY_ISOLATED')
 $names += @('RESERVATION_GATEWAY_ISOLATED','RESERVATION_OUTAGE_ISOLATED','RESERVATION_TLS_GATEWAY_URL','RESERVATION_GATEWAY_CA_FILE','RESERVATION_SALES_CREDENTIAL_FILE','RESERVATION_OTHER_CREDENTIAL_FILE','RESERVATION_FIXTURE_STATE_FILE','GOMAXPROCS')
$names += @('FULFILLMENT_GATEWAY_ISOLATED','FULFILLMENT_OUTAGE_ISOLATED','FULFILLMENT_STATE_FILE','FULFILLMENT_HUMAN_FILE')
$names += @('ADJUSTMENT_GATEWAY_ISOLATED','OPENING_FIXTURE_MACHINE_ID','OPENING_GATEWAY_ISOLATED','OPENING_CATALOG_DATABASE_URL')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
$compose = @('compose','--project-name',$project,'--env-file',(Join-Path $temporary 'empty.env'),'-f',(Join-Path $platform 'docker-compose.security-test.yml'),'-f',(Join-Path $platform 'docker-compose.inventory-test.yml'))
if ($OpeningStock) { $compose += @('-f',(Join-Path $platform 'docker-compose.opening-test.yml')) }
if ($StockAdjustments) { $compose += @('-f',(Join-Path $platform 'docker-compose.adjustment-test.yml')) }
if ($Reservations) { $compose += @('-f',(Join-Path $platform 'docker-compose.reservation-test.yml')) }
if ($Fulfillment) { $compose += @('-f',(Join-Path $platform 'docker-compose.fulfillment-test.yml')) }
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
function AuthMigrate([string[]]$Operations) {
    Fixture (@('run','--rm','--no-deps','auth-migrate','-path=/migrations',"-database=postgres://security_test:$($env:SECURITY_TEST_DB_PASSWORD)@postgres:5432/auth_security_test?sslmode=disable")+$Operations)|Out-Null
}
function CheckSQL([string]$Database,[string]$Query,[string]$Expected,[string]$Label) {
    $output = Fixture @('exec','-T','postgres','psql','-X','-t','-A','-v','ON_ERROR_STOP=1','-U','security_test','-d',$Database,'-c',$Query)
    if (([string]::Join('',[string[]]@($output))).Trim() -ne $Expected) { throw "Database assertion failed: $Label" }
    Write-Host "PASS: $Label = $Expected"
}
try {
    $env:GOMAXPROCS='2'
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
    if ($OpeningStock) {
        $env:OPENING_FIXTURE_MACHINE_ID=[guid]::NewGuid().ToString()
        $credentialID=[guid]::NewGuid().ToString()
        $secretBytes=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($secretBytes)
        $secret=[Convert]::ToBase64String($secretBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
        $secretHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($secretBytes)).ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $temporary 'credential.json'),(@{credential_id=$credentialID;secret=$secret}|ConvertTo-Json -Compress))
        $tlsKey=[Security.Cryptography.RSA]::Create(2048)
        try {
            $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=isolated-opening-fixture',$tlsKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('auth-service');$san.AddDnsName('catalog-service');$san.AddDnsName('localhost');$req.CertificateExtensions.Add($san.Build())
            $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
            $cert=$req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddHours(2))
            $pem=$cert.ExportCertificatePem()
            [IO.File]::WriteAllText((Join-Path $temporary 'server.pem'),$pem)
            [IO.File]::WriteAllText((Join-Path $temporary 'server-key.pem'),$tlsKey.ExportPkcs8PrivateKeyPem())
            $caID=[guid]::NewGuid().ToString()
            $kong=Get-Content -LiteralPath (Join-Path $platform 'infrastructure/kong/kong.yml') -Raw
            $kong=$kong.Replace('url: http://auth-service:8080',"url: https://auth-service:8080`n    tls_verify: true`n    ca_certificates: [$caID]").Replace('url: http://catalog-service:8081',"url: https://catalog-service:8081`n    tls_verify: true`n    ca_certificates: [$caID]")
            $kong += "`nca_certificates:`n  - id: $caID`n    cert: |`n" + (($pem -split '\r?\n' | ForEach-Object { '      '+$_ }) -join "`n") + "`n"
            [IO.File]::WriteAllText((Join-Path $temporary 'kong.yml'),$kong)
            $cert.Dispose()
        } finally {$tlsKey.Dispose()}
    }
    $salesClients=@()
    if ($Reservations) {
        foreach($label in @('sales','other')) {
            $salesMachine=[guid]::NewGuid().ToString();$salesCredential=[guid]::NewGuid().ToString()
            $salesBytes=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($salesBytes)
            $salesSecret=[Convert]::ToBase64String($salesBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
            $salesHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($salesBytes)).ToLowerInvariant()
            $salesFile=Join-Path $temporary "$label-credential.json"
            [IO.File]::WriteAllText($salesFile,(@{client_id=$salesMachine;credential_id=$salesCredential;secret=$salesSecret}|ConvertTo-Json -Compress))
            $salesClients+=@{ID=$salesMachine;Credential=$salesCredential;Hash=$salesHash;File=$salesFile}
        }
        $env:RESERVATION_SALES_CREDENTIAL_FILE=$salesClients[0].File
        $env:RESERVATION_OTHER_CREDENTIAL_FILE=$salesClients[1].File
        $env:RESERVATION_GATEWAY_CA_FILE=Join-Path $temporary 'server.pem'
        $env:RESERVATION_FIXTURE_STATE_FILE=Join-Path $temporary 'reservation-state.json'
        $env:FULFILLMENT_STATE_FILE=Join-Path $temporary 'fulfillment-state.json'
        $env:FULFILLMENT_HUMAN_FILE=Join-Path $temporary 'fulfillment-human.json'
    }
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
    CheckSQL 'inventory_db' "SELECT version::text || ':' || dirty::text FROM schema_migrations" '7:false' 'Inventory migration'
    CheckSQL 'auth_security_test' "SELECT version::text || ':' || dirty::text FROM schema_migrations" '12:false' 'Auth migration dependency'
    if ($Reservations) {
        AuthMigrate @('down','1')
        CheckSQL 'auth_security_test' "SELECT version::text||':'||dirty::text FROM schema_migrations" '11:false' 'empty fulfillment authority downgrade'
        AuthMigrate @('up','1')
        CheckSQL 'auth_security_test' "SELECT version::text||':'||dirty::text FROM schema_migrations" '12:false' 'fulfillment authority reapply'
        CheckSQL 'auth_security_test' "SELECT count(*) FROM identity_permissions WHERE resource='inventory.reservations'" '0' 'no human reservation permission definitions'
    }
    CheckSQL 'catalog_security_test' "SELECT version::text || ':' || dirty::text FROM schema_migrations" '3:false' 'Catalog routing fixture migrations'
    CheckSQL 'auth_security_test' "SELECT count(*) FROM identity_permissions WHERE action='read' AND resource IN ('inventory.stock-balances','inventory.stock-movements')" '2' 'Stock read definitions'
    CheckSQL 'inventory_db' "SELECT rolsuper::int+rolcreatedb::int+rolcreaterole::int FROM pg_roles WHERE rolname='inventory_service'" '0' 'Inventory role restricted'
    $dbAddress = ([string](Fixture @('port','postgres','5432'))).Trim()
    $gatewayAddress = ([string](Fixture @('port','kong','8000'))).Trim()
    if ($Reservations) {
        $tlsAddress=([string](Fixture @('port','kong','8443'))).Trim()
        if($tlsAddress -notmatch '^127\.0\.0\.1:(\d+)$'){throw 'Unexpected reservation TLS gateway binding'}
        $env:RESERVATION_TLS_GATEWAY_URL="https://localhost:$($Matches[1])"
    }
    $env:WAREHOUSE_GATEWAY_ISOLATED = '1'
    $env:WAREHOUSE_AUTH_DATABASE_URL = "postgres://security_test:$($env:SECURITY_TEST_DB_PASSWORD)@${dbAddress}/auth_security_test?sslmode=disable"
    $escapedPassword = [Uri]::EscapeDataString($env:INVENTORY_FIXTURE_PASSWORD)
    $env:WAREHOUSE_INVENTORY_DATABASE_URL = "postgres://inventory_service:${escapedPassword}@${dbAddress}/inventory_db?sslmode=disable"
    $env:WAREHOUSE_AUTH_URL = "http://$gatewayAddress"
    $env:WAREHOUSE_INVENTORY_URL = $env:WAREHOUSE_AUTH_URL
    $env:WAREHOUSE_PUBLIC_KEY = Join-Path $temporary 'public.pem'
    $env:WAREHOUSE_NEGATIVE_PRIVATE_KEY = Join-Path $temporary 'private.pem'
    & go -C $inventory test -p=1 -count=1 -v ./internal/integration -run '^TestIsolatedAuthInventoryGateway$'
    if ($LASTEXITCODE -ne 0) { throw 'Kong warehouse integration failed' }
    CheckSQL 'inventory_db' 'SELECT count(*) FROM warehouses' '2' 'Persisted warehouse rows'
    CheckSQL 'inventory_db' 'SELECT count(*) FROM warehouses WHERE is_default AND is_active' '1' 'Persisted active default'
    # Preserve the existing warehouse test unchanged, then run independent stock
    # fixtures. Catalog is deliberately unavailable during all stock read requests.
    Fixture @('stop','catalog-service') | Out-Null
    $env:STOCK_GATEWAY_ISOLATED='1'
    & go -C $inventory test -p=1 -count=1 -timeout=240s -v ./internal/integration -run '^TestStockReadGateway$'
    if($LASTEXITCODE -ne 0){throw 'Kong stock read integration failed'}
    CheckSQL 'inventory_db' 'SELECT count(*) FROM warehouses' '5' 'Warehouse fixture rows after stock setup'
    if ($OpeningStock) {
        Fixture @('up','-d','--no-deps','--wait','catalog-service') | Out-Null
        $machineSQL="INSERT INTO machine_identities(id,enabled) VALUES('$env:OPENING_FIXTURE_MACHINE_ID',true); INSERT INTO machine_grants(machine_id,audience,permission) VALUES('$env:OPENING_FIXTURE_MACHINE_ID','catalog-stock-references','catalog.stock-references:read'); INSERT INTO machine_credentials(id,machine_id,secret_hash,created_at,expires_at) VALUES('$credentialID','$env:OPENING_FIXTURE_MACHINE_ID',decode('$secretHash','hex'),clock_timestamp(),clock_timestamp()+interval '1 hour');"
        Fixture @('exec','-T','postgres','psql','-X','-v','ON_ERROR_STOP=1','-U','security_test','-d','auth_security_test','-c',$machineSQL) | Out-Null
        Fixture @('exec','-T','postgres','psql','-X','-v','ON_ERROR_STOP=1','-U','security_test','-d','catalog_security_test','-c',"ALTER DATABASE catalog_security_test SET stock.gateway_fixture='$project'") | Out-Null
        $env:OPENING_CATALOG_DATABASE_URL="postgres://security_test:$($env:SECURITY_TEST_DB_PASSWORD)@${dbAddress}/catalog_security_test?sslmode=disable"
        $env:OPENING_GATEWAY_ISOLATED='1'
        & go -C $inventory test -p=1 -count=1 -timeout=240s -v ./internal/integration -run '^TestOpeningStockGateway$'
        if($LASTEXITCODE -ne 0){throw 'Opening Stock HTTPS/Kong integration failed'}
        if ($StockAdjustments) {
            $env:ADJUSTMENT_GATEWAY_ISOLATED='1'
            & go -C $inventory test -p=1 -count=1 -timeout=240s -v ./internal/integration -run '^TestStockAdjustmentGateway$'
            if ($LASTEXITCODE -ne 0) {
                # Print only fixed diagnostic fields from fixture JSON events.
                $events=Fixture @('logs','--no-log-prefix','--tail','40','inventory-service')
                foreach ($line in $events) {
                    try { $diagnosticEvent=([string]$line)|ConvertFrom-Json -ErrorAction Stop } catch {continue}
                    $safe=@{};foreach($field in @('component','operation','reason','sqlstate','request_id','status','route')){if($null -ne $diagnosticEvent.$field){$safe[$field]=$diagnosticEvent.$field}}
                    if($safe.Count){Write-Host ($safe|ConvertTo-Json -Compress)}
                }
                throw 'Adjustment/correction HTTPS Kong integration failed'
            }
        }
        if ($Reservations) {
            foreach($client in $salesClients) {
                $grants=(@('inventory.reservations:consume','inventory.reservations:read','inventory.reservations:release','inventory.reservations:reserve')|ForEach-Object{"('$($client.ID)','inventory-reservations','$_')"}) -join ','
                $salesSQL="INSERT INTO machine_identities(id,enabled) VALUES('$($client.ID)',true); INSERT INTO machine_credentials(id,machine_id,secret_hash,created_at,expires_at) VALUES('$($client.Credential)','$($client.ID)',decode('$($client.Hash)','hex'),clock_timestamp(),clock_timestamp()+interval '1 hour'); INSERT INTO machine_grants(machine_id,audience,permission) VALUES $grants;"
                if ($Fulfillment) {
                    $fulfillmentGrants=(@('inventory.dispatches:cancel','inventory.dispatches:create','inventory.dispatches:read')|ForEach-Object{"('$($client.ID)','inventory-fulfillment','$_')"}) -join ','
                    $salesSQL+=" INSERT INTO machine_grants(machine_id,audience,permission) VALUES $fulfillmentGrants;"
                }
                Fixture @('exec','-T','postgres','psql','-X','-v','ON_ERROR_STOP=1','-U','security_test','-d','auth_security_test','-c',$salesSQL)|Out-Null
            }
            $env:RESERVATION_GATEWAY_ISOLATED='1'
            & go -C $inventory test -p=1 -count=1 -timeout=240s -v ./internal/integration -run '^TestReservationGateway$'
            if($LASTEXITCODE -ne 0){throw 'Reservation HTTPS/Kong integration failed'}
            if ($Fulfillment) {
                $env:FULFILLMENT_GATEWAY_ISOLATED='1'
                & go -C $inventory test -p=1 -count=1 -timeout=240s -v ./internal/integration -run '^TestFulfillmentGateway$'
                if($LASTEXITCODE -ne 0){throw 'Fulfillment HTTPS/Kong acceptance failed'}
            }
            Fixture @('stop','catalog-service')|Out-Null
            $env:RESERVATION_OUTAGE_ISOLATED='1'
            & go -C $inventory test -p=1 -count=1 -timeout=120s -v ./internal/integration -run '^TestReservationGatewayOutage$'
            if($LASTEXITCODE -ne 0){throw 'Reservation outage reconciliation failed'}
            if ($Fulfillment) {
                $env:FULFILLMENT_OUTAGE_ISOLATED='1'
                & go -C $inventory test -p=1 -count=1 -timeout=120s -v ./internal/integration -run '^TestFulfillmentGatewayOutage$'
                if($LASTEXITCODE -ne 0){throw 'Fulfillment outage/replay acceptance failed'}
            } else { AuthMigrate @('down','1') } # Empty fulfillment authority only; populated reservation grants remain on 11.

            $grantRows=Fixture @('exec','-T','postgres','psql','-X','-t','-A','-v','ON_ERROR_STOP=1','-U','security_test','-d','auth_security_test','-c',"SELECT count(*) FROM machine_grants WHERE audience='inventory-reservations'")
            $expectedGrants=([string]::Join('',[string[]]@($grantRows))).Trim()
            $authorityRefused=$false;try{AuthMigrate @('down','1')}catch{$authorityRefused=$true}
            if(!$authorityRefused){throw 'Populated machine authority downgrade unexpectedly succeeded'}
            CheckSQL 'auth_security_test' "SELECT count(*) FROM machine_grants WHERE audience='inventory-reservations'" $expectedGrants 'populated authority downgrade preserved grants'

        }
        Write-Host 'PASS: real human login, HTTPS machine issuance, preparation/post/read/replay through Kong.'
    }
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
