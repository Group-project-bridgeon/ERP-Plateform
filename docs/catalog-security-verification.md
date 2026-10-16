# Catalog security deployment and verification

Keep Authentication, Catalog-Service and ERP-Platform as sibling directories.
Preserve your existing .env
files and signing keys separately. Do not overwrite them when installing changes.

The Auth RS256 cutover, secured Catalog and Platform configuration are a coordinated deployment. Old Auth runtime configuration or missing Catalog public-key configuration can break startup or access. Apply migration 000005 and explicitly assign required permissions; the migration itself grants none. Fresh login is needed after assignment, and existing Catalog tokens can remain valid until expiry, up to 15 minutes.

## Public key and normal deployment

Auth already signs RS256 tokens. Derive the corresponding public key from the
existing private key; do not generate a replacement signing key for this change.
From ERP-Platform, with OpenSSL installed:

```powershell
if (!(Test-Path ../Authentication/keys/jwt-private.pem -PathType Leaf)) { throw 'Existing Auth private key is missing' }
if (Test-Path ../Authentication/keys/jwt-public.pem) { throw 'Public key already exists; verify its provenance before replacing it' }
openssl pkey -in ../Authentication/keys/jwt-private.pem -pubout -out ../Authentication/keys/jwt-public.pem
if ($LASTEXITCODE -ne 0) { throw 'Public key export failed' }
docker compose config --quiet
docker compose up -d --build auth-service catalog-service kong
```

The last command applies pending service migrations to your configured databases;
review/back up those databases first. This guide does not execute that command.
Migration 000005 is additive, inserts 33 permission definitions and assigns no
users. Previous migrations are unchanged. Its down migration intentionally keeps
definitions to preserve grants/pre-existing permission rows.

Both services share AUTH_JWT_ISSUER (default erp-auth) and AUTH_JWT_AUDIENCE
(default erp-api). Auth validates AUTH_JWT_EXPIRY between 1s and 15m. Catalog
enforces the 15-minute ceiling independently. Both mounts are read-only and use
create_host_path: false. Catalog receives only jwt-public.pem; Auth receives only
jwt-private.pem. Keep host private-key ACLs restricted. Check actual readability
under each configured runtime user rather than making the private key public:

```powershell
docker compose exec -T auth-service id -u
docker compose exec -T auth-service test -r /run/secrets/auth-jwt-private.pem
docker compose exec -T catalog-service id -u
docker compose exec -T catalog-service test -r /run/secrets/auth-jwt-public.pem
docker compose exec -T catalog-service wget -qO- http://127.0.0.1:8081/health
docker compose exec -T catalog-service wget -qO- http://127.0.0.1:8081/ready
```

Expect a nonzero UID, exit 0 for readability, and successful probe JSON.
No JWT is required for these direct probes. Kong's unchanged API routes do not
expose the root /health and /ready paths. Kong forwards to
http://catalog-service:8081 with strip_path: false over Compose networking.

Catalog has no default host-published port. Explicit local debugging only:

```powershell
docker compose -f docker-compose.yml -f docker-compose.catalog-dev.yml up -d catalog-service
```

This publishes 127.0.0.1:8081 (or CATALOG_DEV_PORT). JWT/permission enforcement
remains identical. Removing the port does not replace service-side security.

## Repeatable isolated runtime verification

Requires Docker Desktop with Linux containers, Compose supporting --wait and
long bind syntax, PowerShell 7.2+, and Go toolchains/dependencies for both source
modules (Catalog go.mod: 1.25.4; Auth go.mod: 1.27.1). From ERP-Platform:

```powershell
pwsh -NoProfile -File ./scripts/test-catalog-security.ps1
```

The script uses only docker-compose.security-test.yml, a random project name,
loopback ephemeral ports, tmpfs PostgreSQL, generated temporary keys and a random
database password. It ignores the normal .env and publishes no Catalog port.
It never runs docker compose down -v or accesses normal project volumes. Finally
it stops only its own project and removes its generated temporary directory.
If cleanup fails, it prints the isolated project name for manual cleanup.

The Go integration test creates new UUID identities with random passwords and
verified test email addresses, without invoking SMTP. Explicit fixture roles are:

| Identity | Assignment | Expected behavior |
|---|---|---|
| Brand editor | GLOBAL catalog.brands:read/create/update | Read/create/update/status permitted |
| Brand reader | GLOBAL catalog.brands:read | Read permitted, writes 403 |
| Empty grants | No role | Login and /me 200, Catalog 403 |
| Warehouse editor | Same brand role permissions, WAREHOUSE scope | Login and /me 200, empty global claims, Catalog 403 |

The harness verifies actual login responses and RS256 signatures locally using
the temporary public key, issuer/audience/timestamps/identity, and authenticated
/me. It logs HTTP status codes without passwords, tokens, response bodies or
personal records. It checks rejected creates/updates against the database, then
checks authorized create/read/update/status behavior and persistence. Catalog
has no DELETE route. Fixture records are cleaned up; tmpfs data is discarded
when the isolated containers stop. It also runs existing Auth PostgreSQL tests.

Expected statuses: login and /me 200; anonymous /me and Catalog writes 401;
missing GLOBAL grants 403; authorized brand create 201; read/update/status 200;
direct health/readiness 200. The user reported this isolated suite completing
with exit 0. See [the verification record](catalog-security-results.md) for
the reported normal-stack checks and the separate agent-executed checks.

## Existing-account check (read-only)

Use only a known authorized account and its actual credentials. Do not guess,
reset passwords or grant permissions to get a passing result. PowerShell 7.2+
example from ERP-Platform; this does not create or update Catalog data:

```powershell
$credential = Get-Credential -Message 'Known ERP account: email and current password'
$loginBody = @{email=$credential.UserName; password=$credential.GetNetworkCredential().Password} | ConvertTo-Json -Compress
$login = Invoke-RestMethod -Method Post -Uri http://localhost:8000/api/v1/auth/login -ContentType application/json -Body $loginBody
$loginBody = $null
$parts = $login.access_token.Split('.')
if ($parts.Count -ne 3) { throw 'Invalid JWT structure' }
function ConvertFrom-Base64Url([string]$value) {
    $value = $value.Replace('-','+').Replace('_','/')
    [Convert]::FromBase64String($value.PadRight($value.Length + ((4 - $value.Length % 4) % 4),'='))
}
$header = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[0])) | ConvertFrom-Json
if ($header.alg -ne 'RS256') { throw 'Unexpected signing algorithm' }
$rsa = [Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem([IO.File]::ReadAllText((Resolve-Path ../Authentication/keys/jwt-public.pem)))
    $verified = $rsa.VerifyData([Text.Encoding]::ASCII.GetBytes($parts[0]+'.'+$parts[1]),(ConvertFrom-Base64Url $parts[2]),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (!$verified) { throw 'Signature verification failed' }
} finally { $rsa.Dispose() }
$claims = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1])) | ConvertFrom-Json
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($claims.iss -cne 'erp-auth' -or !(@($claims.aud) -ccontains 'erp-api') -or $claims.exp -le $now -or $claims.nbf -gt $now -or $claims.iat -gt $now -or $claims.exp -le $claims.iat -or $claims.nbf -lt $claims.iat -or $claims.exp -le $claims.nbf -or ($claims.exp - $claims.iat) -gt 900) { throw 'Claim contract mismatch' }
$headers = @{Authorization='Bearer '+$login.access_token}
$me = Invoke-RestMethod -Uri http://localhost:8000/api/v1/auth/me -Headers $headers
if ($me.id -cne $claims.sub -or $claims.user_id -cne $claims.sub) { throw 'Identity mismatch' }
$result = Invoke-WebRequest -Uri http://localhost:8000/api/v1/catalog/brands -Headers $headers -SkipHttpErrorCheck
$expected = if (@($claims.permissions) -ccontains 'catalog.brands:read') {200} else {403}
if ([int]$result.StatusCode -ne $expected) { throw 'Catalog permission result mismatch' }
Write-Host "Signature verified; login and /me succeeded; Catalog HTTP $($result.StatusCode)"
$login=$null; $parts=$null; $headers=$null; $claims=$null; $me=$null; $result=$null; $credential=$null
```

If you configured different issuer/audience values, adjust the two assertions
accordingly. A successful signature check is separate from decoding. The
service verifier and isolated tests perform the full required-claim validation.
Do not print the login object, headers, claims or credential. Permission changes
require a fresh login; existing Catalog tokens may remain usable until expiry.

See ../../Catalog-Service/docs/security.md for the complete endpoint matrix,
claim contract, least-privilege assignment policy and regression gotchas.
