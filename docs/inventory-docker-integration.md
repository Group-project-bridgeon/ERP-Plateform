# Inventory Docker and gateway integration

## Scope and dependencies

Inventory warehouse management is available in development at 7238613. Auth's
000006 warehouse permission migration is available at 3490657. Inventory migration
000001 creates the warehouse schema. Fulfillment/Delivery is planned as a separate
internal Inventory module. Stock ledger, reservations, transfers and delivery
implementation are outside this task.

Inventory changes: README.md, Dockerfile, .dockerignore, the existing HTTP integration test
(shared with the gateway fixture), and docs/docker.md. Platform changes:
README.md, docker-compose.yml, infrastructure/kong/kong.yml, .env.example, this document,
docker-compose.inventory-test.yml, scripts/inventory-test-init.sh and
scripts/test-inventory-gateway.ps1 and inventory-docker-results.md. Existing Auth/Catalog source is preserved.

## Build and startup

The Inventory builder is golang:1.25.4-alpine, matching go.mod. Inspected module
requirements are at most Go 1.25.0. GOTOOLCHAIN=local prevents silent toolchain
upgrades. BuildKit caches module downloads and compilation. go mod verify checks
downloaded module contents. Only cmd/internal source is copied into the builder;
only the static Linux executable enters the Alpine runtime. CA certificates and
BusyBox wget support TLS clients and probes. The app runs as a non-root user.

.dockerignore excludes environment files, keys, credentials, Git/editor metadata,
archives/backups, executables/logs/coverage/temp files and Go test fixtures. DB SQL
is mounted into a separate migrate container, not shipped in the runtime image.

Normal startup follows:

1. Existing PostgreSQL becomes healthy.
2. inventory-migrate connects to inventory_db as inventory_service, applies up,
   then exits successfully. Missing migration source paths fail rather than being
   silently created. The migrate image is pinned to v4.18.3.
3. inventory-service starts after the migration completes. It validates the RSA
   public key, opens its pool and starts HTTP on 8082. /ready checks the DB.
4. Kong routes /api/v1/inventory to http://inventory-service:8082, preserving the
   complete path and Authorization header. Inventory validates the RS256 JWT,
   issuer/audience/time/identity contract, then exact GLOBAL permission.
5. Authorized warehouse writes run in Inventory's existing transaction and lock.

The Dockerfile uses /health for process liveness; normal Compose uses /ready for
DB-aware readiness. The Go binary is PID 1 through exec-form ENTRYPOINT. SIGTERM
triggers existing HTTP draining before pool close. SHUTDOWN_TIMEOUT is explicitly
10s and Compose allows 15s before forced termination. JSON zerolog output stays on
stdout/stderr; no new application logging path is introduced.

## Addresses, configuration and credentials

Clients use http://localhost:8000/api/v1/inventory/warehouses. Inventory publishes
no host port by default. Containers resolve the Compose service name postgres
and use port 5432. Host tools use localhost and the configured published
POSTGRES_PORT; that host port is not the container-to-container destination.

Inventory receives PORT=8082, DATABASE_URL selecting inventory_db as
inventory_service, PGPASSWORD from existing INVENTORY_DB_PASSWORD,
JWT_PUBLIC_KEY_PATH, JWT_ISSUER, JWT_AUDIENCE and SHUTDOWN_TIMEOUT. Remaining
Inventory config retains its tested defaults. Issuer/audience share
AUTH_JWT_ISSUER/AUTH_JWT_AUDIENCE with Auth. Inventory does not need Auth online to
verify a previously issued token. token_version is signed-contract validation,
not a live revocation lookup; existing tokens last at most 15 minutes.

The connection URL contains no password. pgx (runtime) and lib/pq (migrate) read
PGPASSWORD separately. Keep INVENTORY_DB_PASSWORD raw; do not URI-encode it.
Quote literal dollar signs correctly when editing a Compose env file. Do not
print expanded Compose configuration or Docker environment inspection output.
Changing an env variable does not alter a role password in an existing DB volume.
The PostgreSQL initialization convention creates roles only on initial setup.

Only ../Authentication/keys/jwt-public.pem is mounted into Inventory, read-only,
at /run/secrets/auth-jwt-public.pem. create_host_path=false rejects a missing file.
The runtime user must be able to read the public key. A public key verifies
signatures; only Auth receives the private key that creates them. Neither key is
baked into Inventory. Keep the corresponding issuer/audience and key pair aligned.

Kong remains DB-less. Root /health and /ready have no public gateway route.
The existing normal Admin API binding remains localhost:8001; the fixture disables
it. Editing the declarative file alone does not prove a running Kong loaded it.

## Repeatable isolated verification

From ERP-Platform:

```powershell
pwsh -NoProfile -File ./scripts/test-inventory-gateway.ps1 -ConfigurationOnly
pwsh -NoProfile -File ./scripts/test-inventory-gateway.ps1
```

Requires PowerShell 7.4+, Go and Docker Desktop's Linux engine. ConfigurationOnly
checks Compose models without claiming runtime success. Full verification extends
the existing security fixture with the Inventory definitions from normal Compose.
It uses a unique project, project-specific images, tmpfs PostgreSQL, fresh keys,
fresh roles/identities and loopback ephemeral gateway/DB ports. An empty env file
prevents regular .env loading. Initialization waits for a successful TCP query to
the intended DB, excluding PostgreSQL's temporary initialization server.

The fixture creates inventory_db owned by a restricted inventory_service role.
Its password deliberately includes URI-reserved characters, proving the separate
PGPASSWORD path. The host test URI is explicitly encoded. Other fixture databases
are auth_security_test and catalog_security_test. No normal database is accessed.

Full-run assertions:

- Compose validation and Kong 3.9.3 declarative parsing.
- Effective Docker context exclusion, real image builds, nonzero runtime UIDs,
  readable mounted public key, binary-only app and no host Inventory binding.
- Inventory internal health/readiness 200 and direct unauthenticated API 401.
- Migrations Inventory 1:false, Auth 6:false, Catalog 2:false.
- Actual Auth login and /me 200 through Kong; local signature and claim checks.
- Anonymous/invalid/expired tokens 401; no permissions or WAREHOUSE-only 403.
- Reader list/detail 200 and denied writes 403; editor create 201/update/status 200.
- Denied writes leave a full DB snapshot unchanged. Duplicate codes and invalid
  default transitions return 409; exactly two rows and one active default persist.
- Auth/Catalog route regression checks, gateway root probes 404, and distinguishable
  Inventory missing-warehouse 404.
- SIGTERM shutdown exits 0. Only fixture containers/network/images/temp keys are
  removed, tmpfs data disappears and prior environment is restored.

Every successful authorized test uses an actual login token. A locally signed
expired token is used solely for the negative expiry test. Passwords, tokens,
headers, request bodies and raw service/DB failures are not printed. A failure
remains a failed run even if cleanup succeeds. Ordinary Go tests skip fixture
cases when their explicit environment flags are absent.

## Troubleshooting

| Observation | Interpretation and next check |
| --- | --- |
| Kong 404 for root /health or /ready | Expected: no gateway route exposes root probes. Use internal probes. |
| Other Kong 404 | Check loaded declarative config and the /api/v1/inventory prefix. |
| Inventory 404 with warehouse_not_found and request_id | Routing/auth succeeded; the requested warehouse ID does not exist. |
| 502/503 at gateway | Check Inventory health, service DNS/8082, migration completion and Docker network. |
| 401 | Check Bearer token, matching public key, RS256, issuer/audience and time claims. Get a fresh login. |
| 403 | Check exact GLOBAL warehouse permission. WAREHOUSE-only assignments do not become GLOBAL. |
| /ready fails or container cannot start | Inspect safe component/operation/reason/SQLSTATE diagnostics; verify DB identity/connectivity/credentials. |
| Missing key mount | Ensure the corresponding public-key file exists; bind source creation is disabled. |
| Unreadable/invalid key | Check public-file readability by the app UID and valid RSA public PEM, not the private key. |

Use bounded logs and safe reason fields; do not paste full environment/config,
JWTs, headers or raw connection errors into reports. Distinguish network/routing,
authentication, authorization and database failures before changing credentials.

## Proposed normal deployment: separate approval required

These are future operator steps, not commands executed by the fixture:

1. Review and merge the source/config changes through the usual process. Verify
   warehouse code and Auth migration 000006 are in the selected deployment refs.
2. Back up inventory_db and confirm recovery options. Verify intended existing
   DB roles/passwords and the matching RSA key/issuer/audience locally. Resolve
   previously identified credential exposures through a coordinated process.
3. Validate with `docker compose config --quiet` without printing expanded values.
   Check current migration status using the pinned migration container. For
   example, override its command with `-path=/migrations
   -database=postgres://inventory_service@postgres:5432/inventory_db?sslmode=disable
   version`. A dirty state blocks rollout; an unapplied initial migration needs
   explicit confirmation, not a reset.
4. Confirm Auth 000006 is applied through Auth's deployment process. It defines
   inventory.warehouses:read/create/update; it grants no users or roles access.
5. Build Inventory, run its migration once, then start/recreate only Inventory
   after successful migration. Check internal /ready and safe startup logs.
6. Reload/restart Kong through the approved change window and verify it loaded
   the new DB-less file. Account for the brief effect on existing gateway traffic.
7. Assign approved GLOBAL roles through the existing authorization workflow. Use
   a fresh real login to verify authorized list/create/update/status through
   localhost:8000, anonymous 401, denied 403 and persisted warehouse rules.

Rollback application images and Compose/Kong configuration to reviewed prior
versions if necessary, then verify existing routes. Retain warehouse data.
Do not casually run migration down: Inventory 000001 down drops the table. Never
use normal docker compose down -v as an application rollback. Database recovery
requires the agreed backup/restore procedure. No normal deployment is automated
by this task's test script.

See [executed results and limitations](inventory-docker-results.md) for the 2026-10-22 verification record.
