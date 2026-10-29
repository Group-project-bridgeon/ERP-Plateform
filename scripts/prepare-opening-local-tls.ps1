#Requires -Version 7.4
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$AuthTrustBundleFile,
 [Parameter(Mandatory)][string]$CatalogTrustBundleFile,
 [string]$KongTemplateFile
)
$ErrorActionPreference='Stop'
$platform=Split-Path $PSScriptRoot -Parent
$workspace=Split-Path $platform -Parent
if(!$KongTemplateFile){$KongTemplateFile=Join-Path $platform 'infrastructure/kong/kong.yml'}
if(![IO.Path]::IsPathFullyQualified($OutputDirectory)){throw 'OutputDirectory must be an absolute protected path outside all repositories'}
$dir=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $dir){throw 'Refusing to overwrite existing local material'}
foreach($repo in @('Authentication','Catalog-Service','Inventory-Service','purchasing','ERP-Platform')){
 $prefix=[IO.Path]::GetFullPath((Join-Path $workspace $repo))+[IO.Path]::DirectorySeparatorChar
 if(($dir+[IO.Path]::DirectorySeparatorChar).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'OutputDirectory must be outside repository/build contexts'}
}
$trust=@{}
foreach($entry in @(@('auth-service',$AuthTrustBundleFile),@('catalog-service',$CatalogTrustBundleFile))){
 if(!(Test-Path -LiteralPath $entry[1] -PathType Leaf)){throw 'Supply both existing PUBLIC trust-bundle files'}
 $bundle=[IO.File]::ReadAllText([IO.Path]::GetFullPath($entry[1]))
 if($bundle -notmatch '-----BEGIN CERTIFICATE-----' -or $bundle -match 'PRIVATE KEY'){throw 'Trust input must contain only public certificate material'}
 $trust[$entry[0]]=$bundle
}
$template=Get-Content -LiteralPath $KongTemplateFile -Raw
foreach($url in @('url: http://auth-service:8080','url: http://catalog-service:8081')){if(([regex]::Matches($template,[regex]::Escape($url))).Count -ne 1){throw 'Kong template must contain each expected base upstream exactly once'}}
New-Item -ItemType Directory -Path $dir | Out-Null
if($IsWindows){
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
 & icacls $dir /inheritance:r /grant:r "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' *> $null
 if($LASTEXITCODE){throw 'Protected directory ACL failed'}
}else{& chmod 700 -- $dir;if($LASTEXITCODE){throw 'Protected directory permission setup failed'}}
$caKey=[Security.Cryptography.RSA]::Create(3072)
try {
 $caReq=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=ERP Local Opening Stock CA',$caKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $caReq.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$true,0,$true))
 $caReq.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,$true))
 $ca=$caReq.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddYears(1))
 [IO.File]::WriteAllText((Join-Path $dir 'root-ca.pem'),$ca.ExportCertificatePem())
 [IO.File]::WriteAllText((Join-Path $dir 'root-ca-key.pem'),$caKey.ExportPkcs8PrivateKeyPem())
 $certificates=@()
 foreach($name in @('auth-service','catalog-service')) {
  $key=[Security.Cryptography.RSA]::Create(2048)
  try {
   $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$name",$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
   $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
   $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,$true))
   $eku=[Security.Cryptography.OidCollection]::new();[void]$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$true))
   $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName($name);$san.AddDnsName('localhost');$san.AddIpAddress([Net.IPAddress]::Loopback);$req.CertificateExtensions.Add($san.Build())
   $serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial)
   $leaf=$req.Create($ca,[DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddDays(90),$serial)
   [IO.File]::WriteAllText((Join-Path $dir "$name.pem"),$leaf.ExportCertificatePem())
   [IO.File]::WriteAllText((Join-Path $dir "$name-key.pem"),$key.ExportPkcs8PrivateKeyPem())
   $certificates+=@{service=$name;dns_sans=@($name,'localhost');ip_sans=@('127.0.0.1');expires_at=$leaf.NotAfter.ToUniversalTime().ToString('O');thumbprint=$leaf.Thumbprint}
   $leaf.Dispose()
  }finally{$key.Dispose()}
 }
 & (Join-Path $PSScriptRoot 'render-opening-local-kong.ps1') -OutputFile (Join-Path $dir 'kong.yml') -TrustBundleFile (Join-Path $dir 'root-ca.pem') -KongTemplateFile $KongTemplateFile | Out-Null
 $certificates|ConvertTo-Json -Depth 4|Set-Content (Join-Path $dir 'certificate-metadata.json') -Encoding utf8
 foreach($name in @('auth-service','catalog-service')){
  $file=if($name -eq 'auth-service'){'auth-trust-bundle.pem'}else{'catalog-trust-bundle.pem'}
  [IO.File]::WriteAllText((Join-Path $dir $file),$trust[$name]+"`n"+$ca.ExportCertificatePem())
 }
 [IO.File]::WriteAllText((Join-Path $dir 'local.env.example'),"OPENING_LOCAL_DIR=$($dir.Replace('\','/'))`nOPENING_LOCAL_MACHINE_ID=REPLACE_WITH_PROVISIONED_MACHINE_UUID`n")
 $ca.Dispose()
 Write-Output "Prepared restricted local TLS directory: $dir"
}finally{$caKey.Dispose()}
