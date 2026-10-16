# ERP-Plateform
Infrastructure platform for Fashion Wholesale ERP

## Catalog authentication and authorization

Catalog validates Auth RS256 JWTs locally and requires exact GLOBAL permissions.
Only the public key is mounted into Catalog. Host port 8081 is no longer published
by default; opt in with docker-compose.catalog-dev.yml for local debugging.

See [deployment, test assignments and PowerShell verification](docs/catalog-security-verification.md)
and [the endpoint permission matrix](../Catalog-Service/docs/security.md).

Run the disposable end-to-end fixture from this directory with:

```powershell
pwsh -NoProfile -File ./scripts/test-catalog-security.ps1
```

It uses separate containers, tmpfs data, temporary keys and fresh test identities.
See [the verification record](docs/catalog-security-results.md) for user-reported runtime results and separately attributed agent checks. Auth, Catalog and Platform require a coordinated configuration/key rollout; migration 000005 defines permissions but grants none.
