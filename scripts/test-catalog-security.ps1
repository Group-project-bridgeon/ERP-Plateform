#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$platform = Split-Path $PSScriptRoot -Parent
$project = 'erp-security-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$temporary = Join-Path ([IO.Path]::GetTempPath()) $project
New-Item -ItemType Directory -Path $temporary | Out-Null
$names = @('SECURITY_TEST_DB_PASSWORD','SECURITY_TEST_KEY_DIR','TEST_DATABASE_URL','CATALOG_TEST_DATABASE_URL','ERP_SECURITY_ISOLATED','ERP_SECURITY_GATEWAY_URL','ERP_SECURITY_PUBLIC_KEY')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
$emptyEnv = Join-Path $temporary 'empty.env'
[IO.File]::WriteAllText($emptyEnv,'')
$compose = @('compose','--project-name',$project,'--env-file',$emptyEnv,'-f',(Join-Path $platform 'docker-compose.security-test.yml'))
function Invoke-FixtureDocker {
    param([string[]]$DockerArgs)
    # Capture output to avoid exposing interpolated credentials on failures.
    $result = & docker @compose @DockerArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker fixture operation failed: $($DockerArgs[0]). Output suppressed to protect credentials." }
    return $result
}
$started = $false
try {
    $random = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $env:SECURITY_TEST_DB_PASSWORD = [Convert]::ToHexString($random).ToLowerInvariant()
    $env:SECURITY_TEST_KEY_DIR = $temporary.Replace('\','/')
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        [IO.File]::WriteAllText((Join-Path $temporary 'private.pem'),$rsa.ExportRSAPrivateKeyPem())
        [IO.File]::WriteAllText((Join-Path $temporary 'public.pem'),$rsa.ExportSubjectPublicKeyInfoPem())
    } finally { $rsa.Dispose() }
    Invoke-FixtureDocker -DockerArgs @('config','--quiet') | Out-Null
    Write-Host 'Building and starting disposable Auth, Catalog, PostgreSQL and Kong (may take several minutes).'
    $started = $true
    Invoke-FixtureDocker -DockerArgs @('up','--build','--detach','--wait','--wait-timeout','180') | Out-Null
    foreach ($service in @('auth-service','catalog-service')) {
        $keyPath = if ($service -eq 'auth-service') {'/run/secrets/private.pem'} else {'/run/secrets/public.pem'}
        $uid = Invoke-FixtureDocker -DockerArgs @('exec','-T',$service,'id','-u')
        if ([string]::Join('', $uid).Trim() -eq '0') { throw "$service unexpectedly runs as root" }
        Invoke-FixtureDocker -DockerArgs @('exec','-T',$service,'test','-r',$keyPath) | Out-Null
        $port = if ($service -eq 'auth-service') {'8080'} else {'8081'}
        foreach ($probe in @('health','ready')) {
            Invoke-FixtureDocker -DockerArgs @('exec','-T',$service,'wget','-qO-',"http://127.0.0.1:$port/$probe") | Out-Null
            Write-Host "$service /$probe HTTP 200; runtime key readable by non-root user"
        }
    }
    $dbAddress = [string](Invoke-FixtureDocker -DockerArgs @('port','postgres','5432'))
    $gateway = [string](Invoke-FixtureDocker -DockerArgs @('port','kong','8000'))
    $env:TEST_DATABASE_URL = "postgres://security_test:$($env:SECURITY_TEST_DB_PASSWORD)@$($dbAddress.Trim())/auth_security_test?sslmode=disable"
    $env:CATALOG_TEST_DATABASE_URL = "postgres://security_test:$($env:SECURITY_TEST_DB_PASSWORD)@$($dbAddress.Trim())/catalog_security_test?sslmode=disable"
    $env:ERP_SECURITY_GATEWAY_URL = 'http://' + $gateway.Trim()
    $env:ERP_SECURITY_PUBLIC_KEY = Join-Path $temporary 'public.pem'
    $env:ERP_SECURITY_ISOLATED = '1'
    & go -C (Join-Path $platform '../Authentication') test ./internal/integration -run '^TestCatalogSecurityThroughKong$' -count=1 -v
    if ($LASTEXITCODE -ne 0) { throw 'Kong security integration test failed' }
    & go -C (Join-Path $platform '../Authentication') test ./internal/repository/postgres -count=1
    if ($LASTEXITCODE -ne 0) { throw 'Auth PostgreSQL integration tests failed' }
    Write-Host 'PASS: isolated runtime login, verified RS256 claims, /me, Kong authorization and Catalog persistence checks.'
} finally {
    if ($started) {
        # This project uses tmpfs, no named DB volumes. Never use down -v.
        try { Invoke-FixtureDocker -DockerArgs @('down','--remove-orphans') | Out-Null }
        catch { Write-Warning "Could not stop isolated project $project. Stop that exact project manually." }
    }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
    $resolved = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -ne $project) { throw 'Refusing cleanup outside the generated temporary fixture directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
