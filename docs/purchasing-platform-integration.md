# Purchasing platform integration

Scope: source integration and uniquely owned disposable verification only. No normal rollout, credentials, grants, data, migrations, TLS replacement or service restarts are authorized by this document. Existing Purchasing prerequisite work remains intact.

## Services and migration ownership

Base docker-compose.yml adds purchasing-migrate (migrate/migrate:v4.18.3) and purchasing-service (../purchasing reviewed Dockerfile). Both use the existing PostgreSQL/network: purchasing_db, purchasing_service, postgres:5432. Bootstrap already defines that role/database; its existence in a normal volume is not proven by bootstrap source and bootstrap was not changed.

PURCHASING_DB_PASSWORD is required and delivered separately as PGPASSWORD. Password-free URIs avoid escaping reserved characters. The application uses pgx; the runner uses its postgres/lib-pq driver. Actual reserved-character migration/runtime acceptance is recorded in the external report rather than assumed from either client.

PostgreSQL healthy -> purchasing-migrate completes successfully -> purchasing-service starts and /ready becomes healthy. Startup checks clean schema 9 read-only; it never creates/converts history. The scoped Auth public PEM mount is read-only, create_host_path=false, and must be readable by UID 10001. Never mount signing keys. No normal host port is added; 8080 remains internal. Production JSON slog, reviewed limits and disabled Outbox are explicit. Stop grace 15s exceeds shutdown budget 10s.

Auth 000013_purchasing_permissions is unique in the inspected local migration files/refs, following pending Inventory 10–12. It defines 41 permissions, grants none. No Party repository/route/migration was available locally; this is not external teammate coordination. Coordinate numbering again before publication/merge, and never rename a migration applied to a shared database.

## Kong mapping and public surface

Kong 3.9.3 uses service URL http://purchasing-service:8080/api/v1/ and two segment-bounded routes: an exact regex for /api/v1/purchasing and a descendant prefix /api/v1/purchasing/. Both use strip_path=true and path_handling=v0. This avoids unsupported look-ahead in Kong's regex engine and prevents /api/v1/purchasing-extra/... from matching. Runtime verification proves /api/v1/purchasing/purchase-orders reaches /api/v1/purchase-orders. Existing Auth/Catalog/Inventory namespaces remain separate; no /api/v1 catch-all is added. Authorization headers and query parameters are forwarded unchanged.

Root /health, /ready, /docs and /metrics are not routed to Purchasing. Prefix /ready, /docs and /metrics translate to nonexistent application /api/v1 paths. Outbox administration stays unregistered. The existing public application /api/v1/health translates to external /api/v1/purchasing/health; this legacy liveness accessibility is documented without silently changing its approved policy. Exact runtime statuses are recorded in the report.

## Local TLS tooling and a future config refresh

The Opening Stock overlay remains unchanged. Auth/Catalog keep HTTPS, verified CA trust/hostnames and read-only mounts. Public prepare-opening-local-tls.ps1 now delegates only its new Kong rendering to render-opening-local-kong.ps1. The renderer preserves unrelated service/route/trust entries, changes only expected Auth/Catalog upstreams to HTTPS with tls_verify=true, and appends public CA definitions. It accepts a new output path outside repositories; it refuses to overwrite existing files. It neither creates TLS material nor reloads services.

For a separately authorized normal refresh, use the **current committed base template** plus the existing PUBLIC Opening Stock root CA/bundle:

```powershell
pwsh -NoProfile -File scripts/render-opening-local-kong.ps1 `
  -OutputFile <absolute-protected-directory>/kong.review.yml `
  -TrustBundleFile <existing-public-root-ca.pem>
```

Review the new file with DB-less Kong parsing and compare namespaces/trust against the current protected generated file. Then separately authorize replacement of that generated config and Kong reload/recreation. Do not rerun TLS preparation to refresh routes; that would create a different CA/certificate set. This task does not read/replace normal generated Kong or any protected security-work script, certificate, key or local environment file.

opening-local-compose.ps1 accepts purchasing-service and purchasing-migrate. Existing actions remain explicit and exclude PostgreSQL startup. Build selects only the app. For later authorized Up, run migration alone first; the wrapper requires existing PostgreSQL health, then requires a retained successfully exited migration container before starting Purchasing. It does not infer normal database adoption safety from job exit alone. Existing Auth/Catalog/Inventory/Kong actions retain their behavior.

## Existing embedded-runner adoption remains blocked

Fresh installation applies service-owned migrations 1–9 through golang-migrate before the new binary. An existing filename/VARCHAR embedded-runner tracker is incompatible and rejected read-only. Actual backup/recovery, schema/history and historical creator provenance must be reviewed before an adoption procedure is approved. No force, baseline, renamed migration, guessed creator, automatic history conversion or normal migration was performed. See Purchasing docs/platform-prerequisites.md for the approved authority and rollback boundaries.

## Reproducible owned verification

```powershell
# Workspace root, Docker Linux engine, PowerShell 7.4+, Go 1.27.3
pwsh -NoProfile -File ERP-Platform/scripts/test-purchasing-gateway.ps1 -ConfigurationOnly
pwsh -NoProfile -File ERP-Platform/scripts/test-purchasing-gateway.ps1 -GoExe go
```

The standalone docker-compose.purchasing-test.yml never combines with normal Compose. Only Purchasing service definitions are extended from base; synthetic overrides replace key mounts and image tags. A unique labelled project, tmpfs PostgreSQL, ownership tables, loopback ephemeral ports, generated raw passwords, private temporary directory and scoped temporary signing/TLS files isolate it. Explicit empty env files prevent normal dotenv loading. Every mutation/cleanup checks container/network/image ownership. Process environment and pre-existing container states are preserved.

The Go fixture requires explicit isolation/state flags, a run/directory marker, owned DB markers, loopback URLs and custom CA verification. It registers synthetic users through Auth HTTPS, explicitly verifies only those fixture users and assigns synthetic GLOBAL grants, then obtains actual Auth login tokens over HTTPS. Positive authority never comes from locally signed tokens. Locally signed expired/wrong-kind tokens are negative tests only. No TLS verification bypass is used.

Acceptance covers clean migrations, no automatic grants, failing-migration startup gating, non-root/public-key readability, internal probes, authentication/permissions/compound pairs, trusted creators, actor separation, lifecycle rejection, Outbox preservation, real database outage, prefix/query/header mapping and real Auth/Catalog/Inventory read regressions. An injected Party-like route/CA preservation case proves renderer preservation, not actual Party runtime behavior. Builds, tests, exact HTTP results, skips and cleanup are reported in review-artifacts/purchasing-platform-integration/<run>/report.md.

## Remaining work

Coordinate unavailable Party changes/Auth numbering before publication. Review/commit/push/PR/merge only under separate authorization. Normal rollout requires reviewed legacy adoption or verified fresh DB status, recoverable backups, public-key permissions, correct credentials, explicit human grants and a reviewed generated TLS Kong refresh. Purchasing-to-Inventory business integration, Kafka and production-readiness certification are out of scope.
