#Requires -Version 7.4
$ErrorActionPreference='Stop'
$platform=Split-Path $PSScriptRoot -Parent
$run='opening-config-test-'+[guid]::NewGuid().ToString('N')
$temporary=Join-Path ([IO.Path]::GetTempPath()) $run
$names=@('OPENING_LOCAL_DIR','OPENING_LOCAL_MACHINE_ID','DOCKER_HOST')
foreach($line in (Get-Content (Join-Path $platform '.env.example'))){if($line -match '^([A-Z][A-Z0-9_]*)='){$names+=$Matches[1]}}
$names=@($names|Select-Object -Unique);$previous=@{}
foreach($n in $names){$previous[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
try {
 if($env:DOCKER_HOST -and $env:DOCKER_HOST -notmatch '^(unix|npipe)://'){throw 'Configuration fixture refuses remote Docker endpoints'}
 $endpoint=& docker context inspect --format '{{.Endpoints.docker.Host}}' 2>$null
 if($LASTEXITCODE -ne 0 -or ([string]$endpoint).Trim() -notmatch '^(unix|npipe)://'){throw 'Select a local Docker socket/named pipe'}
 foreach($n in $names|Where-Object {$_ -ne 'DOCKER_HOST'}){Remove-Item -LiteralPath ('Env:'+ $n) -ErrorAction SilentlyContinue}
 New-Item -ItemType Directory -Path $temporary|Out-Null
 $key=[Security.Cryptography.RSA]::Create(2048)
 try{
  $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Disposable public trust input',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
  $cert=$req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(1))
  $public=$cert.ExportCertificatePem();$cert.Dispose()
 }finally{$key.Dispose()}
 $roots=Join-Path $temporary 'public-input.pem';[IO.File]::WriteAllText($roots,$public)
 $material=Join-Path $temporary 'material'
 & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'prepare-opening-local-tls.ps1') -OutputDirectory $material -AuthTrustBundleFile $roots -CatalogTrustBundleFile $roots *> $null
 if($LASTEXITCODE){throw 'Portable TLS generator failed'}
 & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'prepare-opening-local-tls.ps1') -OutputDirectory $material -AuthTrustBundleFile $roots -CatalogTrustBundleFile $roots *> $null
 if($LASTEXITCODE -eq 0){throw 'TLS generator overwrote an existing directory'}
 foreach($name in @('auth-service','catalog-service')){
  $root=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText((Join-Path $material 'root-ca.pem')))
  $leaf=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText((Join-Path $material "$name.pem")))
  $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
  try{
   $chain.ChainPolicy.TrustMode=[Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
   $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
   [void]$chain.ChainPolicy.CustomTrustStore.Add($root)
   if(!$chain.Build($leaf)){throw 'Generated certificate chain invalid'}
   $san=($leaf.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.17'}).Format($false)
   if(!$san.Contains($name) -or !$san.Contains('localhost') -or !$san.Contains('127.0.0.1')){throw 'Generated certificate SANs missing'}
  }finally{$chain.Dispose();$leaf.Dispose();$root.Dispose()}
  $bundle=if($name -eq 'auth-service'){'auth-trust-bundle.pem'}else{'catalog-trust-bundle.pem'}
  if(![IO.File]::ReadAllText((Join-Path $material $bundle)).Contains($public)){throw 'Existing public roots not preserved'}
 }
 $bytes=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
 [IO.File]::WriteAllText((Join-Path $material 'inventory-credential.json'),(@{credential_id=[guid]::NewGuid().ToString();secret=[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')}|ConvertTo-Json -Compress))
 $localEnv=Join-Path $temporary 'local.env';$baseEnv=Join-Path $temporary 'base.env'
 [IO.File]::WriteAllText($localEnv,"OPENING_LOCAL_DIR=$($material.Replace('\','/'))`nOPENING_LOCAL_MACHINE_ID=$([guid]::NewGuid().ToString())`n")
 Copy-Item -LiteralPath (Join-Path $platform '.env.example') -Destination $baseEnv
 if(!(Get-Content -LiteralPath $baseEnv | Where-Object {$_ -match '^INVENTORY_DB_PASSWORD=.+$'})){throw 'Synthetic base environment has no Inventory placeholder'}
 if(Test-Path Env:INVENTORY_DB_PASSWORD){throw 'Process credential override was not cleared'}
 $preflight=@('compose','--project-name',$run,'--env-file',$baseEnv,'--env-file',$localEnv,'-f',(Join-Path $platform 'docker-compose.yml'),'-f',(Join-Path $platform 'docker-compose.opening-local.yml'))
 $diagnostics=& docker @preflight config --quiet 2>&1
 if($LASTEXITCODE){throw ('Synthetic-only Compose preflight: '+[string]::Join(' ',[string[]]@($diagnostics)))}
 $wrapper=Join-Path $PSScriptRoot 'opening-local-compose.ps1'
 $wrapperOutput=& pwsh -NoProfile -File $wrapper -LocalEnvFile $localEnv -BaseEnvFile $baseEnv -ProjectName $run -Action Validate 2>&1
 if($LASTEXITCODE){$wrapperOutput|ForEach-Object {Write-Output $_};throw 'Portable wrapper validation failed'}
 $compose=@('compose','--project-name',$run,'--env-file',$baseEnv,'--env-file',$localEnv,'-f',(Join-Path $platform 'docker-compose.yml'),'-f',(Join-Path $platform 'docker-compose.opening-local.yml'))
 $raw=& docker @compose config --format json 2>$null;if($LASTEXITCODE){throw 'Sanitized Compose model invalid'}
 $model=([string]::Join("`n",$raw))|ConvertFrom-Json
 if($model.services.'inventory-service'.environment.OPENING_STOCK_ENABLED -ne 'true'){throw 'Opening flag missing'}
 foreach($svc in @('auth-service','catalog-service','inventory-service','kong')){foreach($mount in $model.services.$svc.volumes){if($mount.source.Replace('\','/').StartsWith($material.Replace('\','/'))){if(!$mount.read_only -or $mount.bind.create_host_path -ne $false){throw 'Unsafe runtime bind semantics'};if($mount.source -match 'root-ca-key'){throw 'Private CA mounted'}}}}
 $model=$null;$raw=$null
 $missing=Join-Path $temporary 'missing.env';[IO.File]::WriteAllText($missing,'')
 & pwsh -NoProfile -File $wrapper -LocalEnvFile $missing -BaseEnvFile $baseEnv -ProjectName $run -Action Validate *> $null
 if($LASTEXITCODE -eq 0){throw 'Missing variables accepted'}
 & pwsh -NoProfile -File $wrapper -LocalEnvFile $localEnv -BaseEnvFile $baseEnv -ProjectName $run -Action Up *> $null
 if($LASTEXITCODE -eq 0){throw 'Unscoped Up accepted'}
 $env:DOCKER_HOST='tcp://invalid.example:2376'
 & pwsh -NoProfile -File $wrapper -LocalEnvFile $localEnv -BaseEnvFile $baseEnv -ProjectName $run -Action Validate *> $null
 if($LASTEXITCODE -eq 0){throw 'Remote Docker host accepted'}
 [Environment]::SetEnvironmentVariable('DOCKER_HOST',$previous.DOCKER_HOST,'Process')
 & docker run --rm --network none --name "$run-kong" --label "opening.config.fixture=$run" -v "${material}/kong.yml:/kong/declarative/kong.yml:ro" -e KONG_DATABASE=off kong:3.9.3 kong config parse /kong/declarative/kong.yml *> $null
 if($LASTEXITCODE){throw 'Generated Kong configuration failed parsing'}
 Write-Output 'PASS: new TLS chains/SANs, preserved public roots, portable wrapper, required-variable/target guards, read-only mounts and Kong parser'
}finally{
 try{
  $resolved=[IO.Path]::GetFullPath($temporary)
  $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if(!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -ne $run){throw 'Refusing temporary cleanup outside fixture'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
 }finally{foreach($n in $names){if($null -eq $previous[$n]){Remove-Item -LiteralPath ('Env:'+$n) -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($n,$previous[$n],'Process')}}}
 Write-Output 'PASS: generated temporary material removed; process environment restored'
}
