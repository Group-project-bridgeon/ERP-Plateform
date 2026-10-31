#Requires -Version 7.4
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$OutputFile,
 [Parameter(Mandatory)][string]$TrustBundleFile,
 [string]$KongTemplateFile
)
$ErrorActionPreference='Stop'
$platform=Split-Path $PSScriptRoot -Parent
$workspace=Split-Path $platform -Parent
if(!$KongTemplateFile){$KongTemplateFile=Join-Path $platform 'infrastructure/kong/kong.yml'}
if(![IO.Path]::IsPathFullyQualified($OutputFile) -or (Test-Path -LiteralPath $OutputFile)){throw 'Supply a new absolute output file; existing generated configuration is never overwritten'}
$target=[IO.Path]::GetFullPath($OutputFile)
foreach($repo in Get-ChildItem -LiteralPath $workspace -Directory){if(Test-Path -LiteralPath (Join-Path $repo.FullName '.git')){if($target.StartsWith($repo.FullName+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Generated configuration must stay outside repositories/build contexts'}}}
if(!(Test-Path -LiteralPath (Split-Path $target -Parent) -PathType Container)){throw 'Output parent must already exist'}
if(!(Test-Path -LiteralPath $TrustBundleFile -PathType Leaf) -or (Get-Item -LiteralPath $TrustBundleFile).Length -gt 1048576){throw 'Supply a bounded public trust bundle'}
$bundle=[IO.File]::ReadAllText($TrustBundleFile)
if($bundle -match 'PRIVATE KEY'){throw 'Trust input must not contain private keys'}
$certs=[regex]::Matches($bundle,'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
if(!$certs.Count -or [regex]::Replace($bundle,'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----','').Trim()){throw 'Trust input must contain public certificate PEM blocks only'}
$ids=@();$entries=''
foreach($cert in $certs){
 $parsed=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($cert.Value);$parsed.Dispose()
 $id=[guid]::NewGuid().ToString();$ids+=$id
 $entries+="  - id: $id`n    cert: |`n"+(($cert.Value -split '\r?\n'|ForEach-Object{'      '+$_}) -join "`n")+"`n"
}
$template=[IO.File]::ReadAllText($KongTemplateFile).Replace("`r`n","`n")
foreach($entry in @(@('auth-service','8080'),@('catalog-service','8081'))){
 $url="url: http://$($entry[0]):$($entry[1])"
 if(([regex]::Matches($template,'(?m)^    '+[regex]::Escape($url)+'[ \t]*$')).Count -ne 1){throw 'Use the committed base template with exactly one expected HTTP Auth/Catalog upstream each; review custom TLS templates separately'}
 $template=$template.Replace($url,"url: https://$($entry[0]):$($entry[1])`n    tls_verify: true`n    ca_certificates: [$($ids -join ', ')]")
}
# Preserve every other service/route and existing top-level trust entries.
$section=[regex]::Match($template,'(?m)^ca_certificates:[ \t]*$')
if($section.Success){
 $next=[regex]::Match($template.Substring($section.Index+$section.Length),'(?m)^[A-Za-z_][A-Za-z0-9_]*:')
 $position=if($next.Success){$section.Index+$section.Length+$next.Index}else{$template.Length}
 $template=$template.Insert($position,"`n"+$entries)
}else{if($template -match '(?m)^ca_certificates:'){throw 'Review non-list trust configuration before rendering'};$template+="`nca_certificates:`n"+$entries}
[IO.File]::WriteAllText($target,$template)
Write-Output 'PASS: new Kong configuration rendered; Auth/Catalog TLS verification and unrelated routes preserved; no TLS material generated or service reloaded'
