#Requires -Version 7.4
[CmdletBinding()]
param([switch]$ConfigurationOnly,[string]$GoExe='go',[string]$EvidenceDirectory)
$ErrorActionPreference='Stop';$PSNativeCommandUseErrorActionPreference=$false
$platform=Split-Path $PSScriptRoot -Parent;$workspace=Split-Path $platform -Parent
$project='purchasing-gateway-'+[guid]::NewGuid().ToString('N')
$temporary=Join-Path ([IO.Path]::GetTempPath()) $project
$names=@('PURCHASING_GATEWAY_RUN_ID','PURCHASING_GATEWAY_DIR','PURCHASING_GATEWAY_ADMIN_PASSWORD','PURCHASING_GATEWAY_ISOLATED','PURCHASING_GATEWAY_STATE','GOTOOLCHAIN','GOMAXPROCS')
foreach($line in Get-Content -LiteralPath (Join-Path $platform '.env.example')){if($line -match '^([A-Z][A-Z0-9_]*)='){$names+=$Matches[1]}}
$names=@($names|Select-Object -Unique);$previous=@{};foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$compose=@('compose','--project-name',$project,'--env-file',(Join-Path $temporary 'empty.env'),'-f',(Join-Path $platform 'docker-compose.purchasing-test.yml'))
$success=$false;$started=$false;$buildStarted=$false;$normalBefore=$null;$failures=[Collections.Generic.List[string]]::new();$checks=[Collections.Generic.List[string]]::new()
$images=@('auth','catalog','inventory','purchasing','context')|ForEach-Object{"erp/purchasing-gateway-${_}:$project"}
function NativeDocker([string[]]$Arguments){$out=& docker.exe @Arguments 2>&1;$code=$LASTEXITCODE;if($code -ne 0){throw "Disposable Docker operation $($Arguments[0]) failed (exit $code); raw output withheld"};return $out}
function Fixture([string[]]$Arguments){NativeDocker ($compose+$Arguments)}
function Pass([string]$Label){$checks.Add($Label);Write-Host "PASS: $Label"}
function Snapshot{$state=@{};foreach($id in @(NativeDocker @('ps','-aq','--no-trunc'))){if($id){$state[$id]=([string](NativeDocker @('inspect','--format','{{.Id}}|{{.State.StartedAt}}|{{.State.Running}}|{{.RestartCount}}',$id))).Trim()}};return $state}
function Owned([string]$ID){if($ID -notmatch '^[a-f0-9]{64}$'){throw 'Invalid fixture container identity'};$label=([string](NativeDocker @('inspect','--format','{{index .Config.Labels "purchasing.gateway.fixture"}}',$ID))).Trim();if($label -ne $project){throw 'Container ownership guard refused operation'}}
function Container([string]$Service){$id=([string](Fixture @('ps','-a','-q','--no-trunc',$Service))).Trim();Owned $id;return $id}
function Status([string]$ID,[string]$Path){Owned $ID;$out=& docker.exe exec $ID wget -T 4 -S -O /dev/null "http://127.0.0.1:8080$Path" 2>&1;$match=[regex]::Match(([string]::Join("`n",[string[]]@($out))),'HTTP/\S+\s+(\d{3})');if(!$match.Success){throw 'Owned HTTP probe status unavailable; raw output withheld'};return [int]$match.Groups[1].Value}
try{
 if($env:DOCKER_HOST -and $env:DOCKER_HOST -notmatch '^(npipe|unix)://'){throw 'Fixture requires a local Docker socket/named pipe'}
 $endpoint=([string](NativeDocker @('context','inspect','--format','{{.Endpoints.docker.Host}}'))).Trim();if($endpoint -notmatch '^(npipe|unix)://'){throw 'Select a local Docker context'}
 $normalBefore=Snapshot
 New-Item -ItemType Directory -Path $temporary|Out-Null
 [IO.File]::WriteAllText((Join-Path $temporary 'owner.txt'),$project);[IO.File]::WriteAllText((Join-Path $temporary 'empty.env'),'')
 if($IsWindows){$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name;& icacls $temporary /inheritance:r /grant:r "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' *> $null;if($LASTEXITCODE){throw 'Fixture ACL setup failed'}}else{& chmod 700 -- $temporary;if($LASTEXITCODE){throw 'Fixture permissions failed'}}
 # Populate only public example values; actual normal environment files are never read.
 foreach($line in Get-Content -LiteralPath (Join-Path $platform '.env.example')){if($line -match '^([A-Z][A-Z0-9_]*)=(.*)$'){[Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')}}
 $password=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()+'@:/?#%+$ space'
 $env:PURCHASING_DB_PASSWORD=$password;$env:PURCHASING_GATEWAY_ADMIN_PASSWORD=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
 $env:PURCHASING_GATEWAY_RUN_ID=$project;$env:PURCHASING_GATEWAY_DIR=$temporary.Replace('\','/');$env:GOMAXPROCS='2';$env:GOTOOLCHAIN='go1.27.3'
 $rsa=[Security.Cryptography.RSA]::Create(2048)
 try{[IO.File]::WriteAllText((Join-Path $temporary 'jwt-private.pem'),$rsa.ExportRSAPrivateKeyPem());[IO.File]::WriteAllText((Join-Path $temporary 'jwt-public.pem'),$rsa.ExportSubjectPublicKeyInfoPem())}finally{$rsa.Dispose()}
 $key=[Security.Cryptography.RSA]::Create(2048)
 try{$request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Disposable fixture public trust input',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true));$certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(1));[IO.File]::WriteAllText((Join-Path $temporary 'input-root.pem'),$certificate.ExportCertificatePem());$certificate.Dispose()}finally{$key.Dispose()}
 $material=Join-Path $temporary 'material'
 & (Join-Path $PSScriptRoot 'prepare-opening-local-tls.ps1') -OutputDirectory $material -AuthTrustBundleFile (Join-Path $temporary 'input-root.pem') -CatalogTrustBundleFile (Join-Path $temporary 'input-root.pem') *> $null
 # Regression: unrelated Party-like routes and existing CA entries survive rendering.
 $template=[IO.File]::ReadAllText((Join-Path $platform 'infrastructure/kong/kong.yml'))
 $template+="`n  - name: party-preservation-probe`n    url: http://party-service:8083`n    routes:`n      - name: party-preservation-probe`n        paths: [/api/v1/party]`n        strip_path: false`n"
 $template+="`nca_certificates:`n  - id: $([guid]::NewGuid().ToString())`n    cert: |`n"+(([IO.File]::ReadAllText((Join-Path $temporary 'input-root.pem')) -split '\r?\n'|ForEach-Object{'      '+$_}) -join "`n")+"`n"
 [IO.File]::WriteAllText((Join-Path $temporary 'template.yml'),$template)
 & (Join-Path $PSScriptRoot 'render-opening-local-kong.ps1') -OutputFile (Join-Path $temporary 'preserved.yml') -TrustBundleFile (Join-Path $material 'root-ca.pem') -KongTemplateFile (Join-Path $temporary 'template.yml') *> $null
 $preserved=[IO.File]::ReadAllText((Join-Path $temporary 'preserved.yml'));if(!$preserved.Contains('party-preservation-probe') -or !$preserved.Contains('tls_verify: true') -or !$preserved.Contains([IO.File]::ReadAllText((Join-Path $temporary 'input-root.pem')).Split("`n")[1])){throw 'Renderer lost existing route/trust configuration'}
 New-Item -ItemType Directory -Path (Join-Path $temporary 'failure')|Out-Null;[IO.File]::WriteAllText((Join-Path $temporary 'failure/000001_expected_failure.up.sql'),'SELECT 1/0;')
 Fixture @('config','--quiet')|Out-Null
 $modelRaw=Fixture @('config','--format','json');$model=([string]::Join("`n",[string[]]@($modelRaw)))|ConvertFrom-Json
 $p=$model.services.'purchasing-service';$migration=$model.services.'purchasing-migrate'
 if($p.ports){throw 'Purchasing unexpectedly publishes a host port'}
 if($p.environment.DATABASE_URL -ne 'postgres://purchasing_service@postgres:5432/purchasing_db?sslmode=disable'){throw 'Purchasing URI differs from password-free service target'}
 # Compose config serialization doubles dollars for re-interpolation. Runtime
 # SCRAM migration/application checks below independently prove the raw value.
 if($p.environment.PGPASSWORD.Replace('$$','$') -cne $password -or $migration.environment.PGPASSWORD.Replace('$$','$') -cne $password){throw 'Raw-password configuration mismatch; values withheld'}
 if($p.depends_on.'purchasing-migrate'.condition -ne 'service_completed_successfully' -or $migration.depends_on.postgres.condition -ne 'service_healthy' -or $p.environment.OUTBOX_PUBLISHER_ENABLED -ne 'false' -or $p.stop_grace_period -ne '15s'){throw 'Purchasing lifecycle configuration invalid'}
 foreach($mount in $p.volumes){if(!$mount.read_only -or $mount.bind.create_host_path -ne $false -or $mount.source -match 'private|server-key|root-ca-key'){throw 'Unsafe Purchasing key mount'}}
 if($model.volumes){throw 'Disposable fixture must not create persistent volumes'}
 $model=$null;$modelRaw=$null
 NativeDocker @('run','--rm','--name',"$project-parse",'--label',"purchasing.gateway.fixture=$project",'--network','none','--mount',"type=bind,src=$material/kong.yml,dst=/fixture.yml,readonly",'-e','KONG_DATABASE=off','kong:3.9.3','kong','config','parse','/fixture.yml')|Out-Null
 NativeDocker @('run','--rm','--name',"$project-preserved-parse",'--label',"purchasing.gateway.fixture=$project",'--network','none','--mount',"type=bind,src=$temporary/preserved.yml,dst=/fixture.yml,readonly",'-e','KONG_DATABASE=off','kong:3.9.3','kong','config','parse','/fixture.yml')|Out-Null
 Pass 'secret-suppressed Compose validation, scoped raw-password/key mounts, migration ordering and DB-less Kong parsing; unrelated route/trust preservation'
 if(!$ConfigurationOnly){
  $version=& $GoExe version 2>&1;if($LASTEXITCODE -ne 0 -or [string]$version -notmatch 'go1\.27\.3 '){throw 'Go 1.27.3 required'}
  Write-Host 'Building unique fixture images (normal tags/services untouched)'
  foreach($image in $images){$null=& docker.exe image inspect $image 2>$null;if($LASTEXITCODE -eq 0){throw 'Refusing to reuse an existing fixture image tag'}}
  $buildStarted=$true;Fixture @('build')|Out-Null
  $contextFile=Join-Path $temporary 'Dockerfile.context'
  [IO.File]::WriteAllText($contextFile,@'
FROM alpine:3.23
COPY . /context
RUN test ! -e /context/.env && test ! -d /context/.git && test ! -d /context/keys && test ! -d /context/backups && test ! -d /context/.vscode && test ! -d /context/.idea && test -z "$(find /context -type f \( -name '*.pem' -o -name '*.key' -o -name '*.pfx' -o -name '*.p12' \) -print -quit)"
'@)
  NativeDocker @('build','--network','none','--label',"purchasing.gateway.fixture=$project",'-t',"erp/purchasing-gateway-context:$project",'-f',$contextFile,(Join-Path $workspace 'purchasing'))|Out-Null
  Pass 'effective Purchasing build context excludes real env, keys, Git, backups and editor settings'
  $started=$true;Fixture @('up','-d','--wait','--wait-timeout','180')|Out-Null
  $app=Container 'purchasing-service';$postgres=Container 'postgres'
  if(([string](NativeDocker @('exec',$app,'id','-u'))).Trim() -ne '10001'){throw 'Purchasing not UID 10001'}
  NativeDocker @('exec',$app,'test','-r','/run/secrets/auth-jwt-public.pem')|Out-Null
  if((Status $app '/health') -ne 200 -or (Status $app '/ready') -ne 200){throw 'Purchasing internal probes failed'}
  Pass 'fresh migrations and ready non-root Purchasing with scoped public key'
  $failure=& docker.exe @compose --profile migration-failure up -d purchasing-blocked 2>&1;$failureCode=$LASTEXITCODE
  if($failureCode -eq 0){throw 'Expected migration failure was accepted'}
  $blocked=([string](Fixture @('ps','-a','-q','--no-trunc','purchasing-blocked'))).Trim()
  if($blocked){Owned $blocked;$state=([string](NativeDocker @('inspect','--format','{{.State.Status}}|{{.State.StartedAt}}',$blocked))).Trim();if($state -notmatch '^created\|0001-'){throw 'Application started despite failed migration'}}
  Pass 'migration failure prevents application startup through completed-successfully dependency'
  $dbPort=([string](Fixture @('port','postgres','5432'))).Trim().Split(':')[-1];$tlsPort=([string](Fixture @('port','kong','8443'))).Trim().Split(':')[-1]
  if($dbPort -notmatch '^\d+$' -or [int]$dbPort -in @(5432,5433) -or $tlsPort -notmatch '^\d+$'){throw 'Unsafe fixture port allocation'}
  $state=@{RunID=$project;BaseURL="https://localhost:$tlsPort";AuthDSN="postgres://auth_fixture@127.0.0.1:${dbPort}/auth_purchasing_gateway?sslmode=disable";PurchasingDSN="postgres://purchasing_service@127.0.0.1:${dbPort}/purchasing_db?sslmode=disable";Password=$password;CAFile=(Join-Path $material 'root-ca.pem');PrivateKey=(Join-Path $temporary 'jwt-private.pem')}
  $env:PURCHASING_GATEWAY_STATE=Join-Path $temporary 'state.json';$env:PURCHASING_GATEWAY_ISOLATED='1';[IO.File]::WriteAllText($env:PURCHASING_GATEWAY_STATE,($state|ConvertTo-Json -Compress));$state=$null
  $output=& $GoExe -C (Join-Path $workspace 'purchasing') test -p=1 -count=1 -timeout=180s -v ./internal/integration -run '^TestPurchasingGateway$' 2>&1;$goCode=$LASTEXITCODE
  foreach($line in $output){Write-Host (([string]$line).Replace($password,'[fixture-password-redacted]'))}
  if($goCode -ne 0){throw 'Purchasing HTTPS/Kong acceptance failed'}
  if($EvidenceDirectory){if(!(Test-Path -LiteralPath $EvidenceDirectory -PathType Container)){throw 'Explicit evidence directory must exist'};[IO.File]::WriteAllText((Join-Path $EvidenceDirectory "$project-http.txt"),[string]::Join("`n",[string[]]@($output)).Replace($password,'[redacted]'))}
  Pass 'actual Auth HTTPS issuance and Purchasing gateway acceptance; Auth/Catalog/Inventory runtime regressions'
  Owned $postgres;NativeDocker @('stop',$postgres)|Out-Null
  if((Status $app '/ready') -ne 503 -or (Status $app '/health') -ne 200){throw 'Actual PostgreSQL outage contract failed'}
  Pass 'actual owned PostgreSQL outage: readiness 503, liveness 200'
 }else{Write-Host 'SKIP: builds, service startup and HTTP acceptance (ConfigurationOnly)'}
 $success=$true
}finally{
 try{
  foreach($id in @(NativeDocker @('ps','-aq','--no-trunc','--filter',"label=purchasing.gateway.fixture=$project"))){if($id){Owned $id;NativeDocker @('rm','--force',$id)|Out-Null}}
  foreach($id in @(NativeDocker @('network','ls','-q','--filter',"label=purchasing.gateway.fixture=$project"))){if($id){$label=([string](NativeDocker @('network','inspect','--format','{{index .Labels "purchasing.gateway.fixture"}}',$id))).Trim();if($label -ne $project){throw 'Network ownership mismatch'};NativeDocker @('network','rm',$id)|Out-Null}}
  if($buildStarted){foreach($image in $images){$label=& docker.exe image inspect --format '{{index .Config.Labels "purchasing.gateway.fixture"}}' $image 2>$null;if($LASTEXITCODE -eq 0){if(([string]$label).Trim() -ne $project){throw 'Image ownership mismatch'};NativeDocker @('image','rm',$image)|Out-Null}}}
 }catch{$failures.Add('Owned resource cleanup not confirmed')}
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
 if(Test-Path -LiteralPath $temporary){$resolved=[IO.Path]::GetFullPath($temporary);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if(!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -ne $project -or [IO.File]::ReadAllText((Join-Path $resolved 'owner.txt')) -ne $project){$failures.Add('Temporary ownership guard refused cleanup')}else{Remove-Item -LiteralPath $resolved -Recurse -Force}}
 if($null -ne $normalBefore){try{$after=Snapshot;foreach($id in $normalBefore.Keys){if(!$after.ContainsKey($id) -or $after[$id] -ne $normalBefore[$id]){throw 'Existing state changed'}};Pass "$($normalBefore.Count) pre-existing containers retain IDs/start times/running/restart state"}catch{$failures.Add('Pre-existing container preservation not confirmed')}}
 if($failures.Count){throw ([string]::Join('; ',$failures))}
 Pass 'only run-owned containers/network/images/temp data removed; process environment restored'
 if($EvidenceDirectory -and (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)){[IO.File]::WriteAllText((Join-Path $EvidenceDirectory "$project-checks.json"),(@{run=$project;configuration_only=[bool]$ConfigurationOnly;completed=$success;checks=@($checks)}|ConvertTo-Json -Depth 4))}
}
