#Requires -Version 7.4
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$LocalEnvFile,
 [Parameter(Mandatory)][ValidateSet('Validate','Status','Build','Up')][string]$Action,
 [string]$BaseEnvFile,
 [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')][string]$ProjectName='erp-platform',
 [ValidateSet('auth-service','catalog-service','inventory-service','purchasing-service','purchasing-migrate','kong')][string[]]$Services
)
$ErrorActionPreference='Stop'
$platform=Split-Path $PSScriptRoot -Parent
if(!$BaseEnvFile){$BaseEnvFile=Join-Path $platform '.env'}
foreach($path in @($LocalEnvFile,$BaseEnvFile)){if(![IO.Path]::IsPathFullyQualified($path) -or !(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Supply existing absolute base/local environment file paths'}}
$workspace=Split-Path $platform -Parent
$localPath=[IO.Path]::GetFullPath($LocalEnvFile)
$required=@{}
foreach($line in [IO.File]::ReadAllLines($localPath)){
 if($line -match '^\s*(OPENING_LOCAL_DIR|OPENING_LOCAL_MACHINE_ID)\s*=\s*(.*?)\s*$'){$required[$Matches[1]]=$Matches[2].Trim().Trim('"').Trim("'")}
}
foreach($key in @('OPENING_LOCAL_DIR','OPENING_LOCAL_MACHINE_ID')){if(!$required[$key]){throw "LocalEnvFile must define $key with an explicit non-secret value"}}
$machine=[guid]::Empty
if(![guid]::TryParse($required.OPENING_LOCAL_MACHINE_ID,[ref]$machine) -or $machine -eq [guid]::Empty -or $machine.ToString() -cne $required.OPENING_LOCAL_MACHINE_ID){throw 'OPENING_LOCAL_MACHINE_ID must be the canonical UUID from the protected provisioning receipt'}
if(![IO.Path]::IsPathFullyQualified($required.OPENING_LOCAL_DIR)){throw 'OPENING_LOCAL_DIR must be an absolute protected host directory'}
foreach($repo in @('Authentication','Catalog-Service','Inventory-Service','purchasing','ERP-Platform')){
 $prefix=[IO.Path]::GetFullPath((Join-Path $workspace $repo))+[IO.Path]::DirectorySeparatorChar
 if($localPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Local deployment file must be outside repository/build contexts'}
 if(([IO.Path]::GetFullPath($required.OPENING_LOCAL_DIR)+[IO.Path]::DirectorySeparatorChar).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'OPENING_LOCAL_DIR must be outside repository/build contexts'}
}
if($Action -in @('Build','Up') -and !$Services){throw 'Choose explicit application services; PostgreSQL is excluded'}
if($env:DOCKER_HOST -and $env:DOCKER_HOST -notmatch '^(unix|npipe)://'){throw 'This local-only wrapper rejects remote DOCKER_HOST endpoints'}
$endpoint=& docker context inspect --format '{{.Endpoints.docker.Host}}' 2>$null
if($LASTEXITCODE -ne 0 -or ([string]$endpoint).Trim() -notmatch '^(unix|npipe)://'){throw 'Select a local Unix-socket or Windows named-pipe Docker context'}
$compose=@('compose','--project-name',$ProjectName,'--env-file',$BaseEnvFile,'--env-file',$LocalEnvFile,'-f',(Join-Path $platform 'docker-compose.yml'),'-f',(Join-Path $platform 'docker-compose.opening-local.yml'))
# Always validate without emitting expanded credentials.
& docker @compose config --quiet *> $null
if($LASTEXITCODE){throw 'Local Compose configuration invalid; check required paths/variables without printing expanded secrets'}
# Purchasing rollout remains explicit: never start PostgreSQL implicitly.
if($Action -eq 'Build' -and $Services -contains 'purchasing-migrate'){throw 'Migration uses a pinned runner image; choose purchasing-service for Build'}
if($Action -eq 'Up' -and ($Services -contains 'purchasing-service' -or $Services -contains 'purchasing-migrate')){
 if($Services -contains 'purchasing-migrate' -and $Services.Count -ne 1){throw 'Run purchasing-migrate alone, then start purchasing-service separately'}
 $pg=(& docker @compose ps -q postgres 2>$null)
 if($LASTEXITCODE -ne 0 -or !$pg){throw 'Existing PostgreSQL must already be healthy; this wrapper never starts it'}
 $health=& docker inspect --format '{{.State.Health.Status}}' $pg 2>$null
 if($LASTEXITCODE -ne 0 -or ([string]$health).Trim() -ne 'healthy'){throw 'Existing PostgreSQL is not healthy'}
 if($Services -contains 'purchasing-service'){
  $migration=(& docker @compose ps -a -q purchasing-migrate 2>$null)
  if($LASTEXITCODE -ne 0 -or !$migration){throw 'Run the reviewed purchasing-migrate job first'}
  $result=& docker inspect --format '{{.State.Status}}|{{.State.ExitCode}}' $migration 2>$null
  if($LASTEXITCODE -ne 0 -or ([string]$result).Trim() -ne 'exited|0'){throw 'Purchasing migration job has not completed successfully'}
 }
}
switch($Action){
 Validate {Write-Output 'PASS: explicit local overlay validates';exit 0}
 Status {$operation=@('ps')}
 Build {$operation=@('build')+$Services}
 Up {if($Services -contains 'purchasing-migrate'){$operation=@('up','--no-deps','--exit-code-from','purchasing-migrate','purchasing-migrate')}else{$operation=@('up','-d','--no-deps','--wait','--wait-timeout','90')+$Services}}
}
& docker @compose @operation
if($LASTEXITCODE){throw 'Explicit local Compose operation failed'}
