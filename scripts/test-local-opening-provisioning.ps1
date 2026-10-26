#Requires -Version 7.4
$ErrorActionPreference='Stop'
$workspace=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$run='local-opening-provision-'+[guid]::NewGuid().ToString('N')
$container=$null
if($env:DOCKER_HOST -and $env:DOCKER_HOST -notmatch '^(unix|npipe)://'){throw 'Disposable local test refuses a remote Docker host'}
$endpoint=& docker context inspect --format '{{.Endpoints.docker.Host}}' 2>$null
if($LASTEXITCODE -ne 0 -or ([string]$endpoint).Trim() -notmatch '^(unix|npipe)://'){throw 'Select a local socket/named-pipe Docker context for this fixture'}
$names=@('POSTGRES_PASSWORD','PGPASSWORD','LOCAL_PROVISION_AUTH_URL','LOCAL_PROVISION_CATALOG_URL','LOCAL_PROVISION_RUN_ID')
$previous=@{};foreach($n in $names){$previous[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
function D([string[]]$a){$o=& docker @a 2>&1;if($LASTEXITCODE){throw ('Disposable provisioning Docker operation failed: '+$a[0]+'; raw output suppressed')};return $o}
try{
 $bytes=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
 $env:POSTGRES_PASSWORD=[Convert]::ToHexString($bytes);$env:PGPASSWORD=$env:POSTGRES_PASSWORD
 $container=([string](D @('run','--rm','-d','--name',$run,'--label',"local.opening.fixture=$run",'--tmpfs','/var/lib/postgresql/data','-e','POSTGRES_USER=local_provision_test','-e','POSTGRES_PASSWORD','-e','POSTGRES_DB=local_provision_auth_test','-p','127.0.0.1::5432','postgres:17-alpine'))).Trim()
 if($container -notmatch '^[a-f0-9]{64}$'){throw 'Invalid fixture ID'}
 $ready=$false;for($i=0;$i -lt 40;$i++){& docker exec $container psql -h 127.0.0.1 -U local_provision_test -d local_provision_auth_test -t -A -c "SELECT 1" *> $null;if($LASTEXITCODE -eq 0){$ready=$true;break};Start-Sleep -Milliseconds 500};if(!$ready){throw 'Fixture not ready'}
 D @('exec',$container,'psql','-X','-v','ON_ERROR_STOP=1','-U','local_provision_test','-d','local_provision_auth_test','-c','CREATE DATABASE local_provision_catalog_test') | Out-Null
 foreach($entry in @(@('Authentication','local_provision_auth_test'),@('Catalog-Service','local_provision_catalog_test'))){
  $path=Join-Path $workspace "$($entry[0])/db/migrations"
  D @('run','--rm','--network',"container:$container",'-e','PGPASSWORD','-v',"${path}:/migrations:ro",'migrate/migrate:v4.18.3','-path=/migrations',"-database=postgres://local_provision_test@127.0.0.1:5432/$($entry[1])?sslmode=disable",'up') | Out-Null
  D @('exec',$container,'psql','-X','-v','ON_ERROR_STOP=1','-U','local_provision_test','-d',$entry[1],'-c',"ALTER DATABASE $($entry[1]) SET local.provision_fixture='$run'") | Out-Null
 }
 $mapping=([string](D @('port',$container,'5432/tcp'))).Trim();if($mapping -notmatch '^127\.0\.0\.1:(\d+)$'){throw 'Fixture port'};$port=$Matches[1]
 $env:LOCAL_PROVISION_AUTH_URL="postgres://local_provision_test:$($env:POSTGRES_PASSWORD)@127.0.0.1:$port/local_provision_auth_test?sslmode=disable"
 $env:LOCAL_PROVISION_CATALOG_URL=$env:LOCAL_PROVISION_AUTH_URL.Replace('/local_provision_auth_test?','/local_provision_catalog_test?');$env:LOCAL_PROVISION_RUN_ID=$run
 & go -C (Join-Path $workspace 'Authentication') test -count=1 -timeout=120s -v ./cmd/local-machine-admin;if($LASTEXITCODE){throw 'Auth provisioning fixture test failed'}
 & go -C (Join-Path $workspace 'Catalog-Service') test -count=1 -timeout=120s -v ./cmd/local-stock-admin;if($LASTEXITCODE){throw 'Catalog provisioning fixture test failed'}
}finally{
 try {
 if(!$container){$owned=@(D @('ps','-a','--no-trunc','--filter',"label=local.opening.fixture=$run",'--format','{{.ID}}'));if($owned.Count -gt 1){throw 'Ambiguous fixture cleanup'};if($owned.Count -eq 1){$container=([string]$owned[0]).Trim()}}
 if($container -match '^[a-f0-9]{64}$'){$label=([string](D @('inspect','--format','{{index .Config.Labels "local.opening.fixture"}}',$container))).Trim();if($label -ne $run){throw 'Refusing non-owned cleanup'};D @('rm','-f',$container)|Out-Null;Write-Output 'PASS: owned provisioning fixture removed'}
 } finally {foreach($n in $names){if($null -eq $previous[$n]){Remove-Item -LiteralPath ('Env:'+$n) -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($n,$previous[$n],'Process')}}}
}
