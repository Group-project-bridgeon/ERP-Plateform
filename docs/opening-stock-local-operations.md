# Local Opening Stock operations

This opt-in setup is for a **local Docker engine** and adjacent Authentication,
Catalog-Service, Inventory-Service and ERP-Platform checkouts. It does not alter
the base Compose behavior. Review and merge companion tooling before using it.
Normal enablement and any database mutation need separate operator authorization.
Do not run setup again against an already enabled environment to test these tools.

## Configuration and protected files

Use PowerShell 7.4+. Choose an absolute protected directory outside every checkout
and build context. Restrict it to the operator and required local system/runtime
access (Windows ACLs or owner-only POSIX permissions). Do not export secrets into
shell history or print expanded Compose configuration. Keep the existing `.env`
and JWT signing keys unchanged. Never install this CA globally into Windows.

Copy `.env.opening-local.example` outside the repositories. Replace its directory
placeholder and machine UUID only after authorized provisioning. These are
non-secret settings; the credential itself belongs in its protected JSON file.
Missing/placeholder values deliberately fail validation. No actual deployment IDs,
certificates or credentials are shipped in this repository.

The protected directory must contain:

| File | Consumer |
| --- | --- |
| auth-service.pem / auth-service-key.pem | Auth TLS listener only |
| catalog-service.pem / catalog-service-key.pem | Catalog TLS listener only |
| root-ca.pem | Inventory explicit CA trust; public material |
| auth-trust-bundle.pem / catalog-trust-bundle.pem | Existing public roots plus local public CA; readiness and outbound TLS |
| kong.yml | Generated HTTPS upstreams with `tls_verify: true` and explicit CA |
| inventory-credential.json | Inventory read-only machine credential |

The private CA key stays offline in protected operator storage and is never mounted
into a runtime. Every runtime bind is read-only and refuses to create a missing
host path. The overlay changes Auth/Catalog listeners to HTTPS on the existing
internal ports; Inventory uses verified HTTPS for machine issuance/references.
Kong's existing local client listener is unchanged; outside the local loopback
development exception, arrange secure human bearer transport separately.

## Prepare trust material for a NEW authorized setup

Export **public** CA bundles from the reviewed Auth/Catalog images to protected
input files (capture `docker run --rm --entrypoint cat <reviewed-image>
/etc/ssl/certs/ca-certificates.crt`; do not display it). Then:

```powershell
# Replace every variable with an explicit absolute operator-selected path.
pwsh -NoProfile -File ./scripts/prepare-opening-local-tls.ps1 `
  -OutputDirectory $NewProtectedDirectory `
  -AuthTrustBundleFile $AuthPublicBundle `
  -CatalogTrustBundleFile $CatalogPublicBundle
```

The script refuses an existing destination or a directory within a checkout.
It creates a one-year private local CA and 90-day leaf certificates, with service
DNS names, localhost and 127.0.0.1 SANs. It preserves the supplied public roots,
generates the Kong declaration from the unchanged base template, and writes a
non-secret `local.env.example`. It does **not** provision identities, classify
units, grant humans, apply migrations, install system trust or start services.
Never point it at the currently working protected directory. Reconciliation and
rotation are separate lifecycle work, not repeated bootstrap.

## Provisioning prerequisites and explicit commands

Before any normal mutation: inspect merged source/schema dirty flags, authorize
and validate backups, read pending migrations, and review rollback order. Current
feature prerequisites are Auth schema 9, Catalog 3 and Inventory 4. Apply migrations
only through separately authorized service-owned migration operations.

Build operator binaries outside source/build contexts using each repository's
toolchain. For a Linux Docker runtime, set `GOOS=linux`, `GOARCH` to the engine
architecture and `CGO_ENABLED=0` only for the build, restoring prior environment
values afterward. Build these targets:

```text
Authentication: go build -trimpath -o <protected-bin-dir>/auth-local-admin ./cmd/local-machine-admin
Catalog-Service: go build -trimpath -o <protected-bin-dir>/catalog-local-admin ./cmd/local-stock-admin
Inventory-Service: go build -trimpath -o <protected-bin-dir>/reference-local-check ./cmd/local-reference-check
```

Select the local socket/named-pipe Docker context explicitly. Run each utility in
a one-off `docker compose run --rm --no-deps` container for its owning service,
using the reviewed base `.env` and no public provisioning endpoint. Bind only the
binary directory read-only as `/ops` and the selected protected delivery/plan
directory as `/protected`. The owning service's environment supplies DATABASE_URL
and JWT key paths; do not pass a connection string or credential in arguments.
Use the corresponding `/ops/<binary>` entrypoint and arguments:

```text
auth-service: --local-host postgres --local-database auth_db --output-dir /protected
catalog-service: --local-host postgres --local-database catalog_db --selection-file /protected/catalog-selection.json
inventory-service (with the explicit local overlay): --confirm-local --variant <confirmed-variant-uuid>
```

The target host/database flags are acknowledgements, not password sources. Mutating
utilities reject hosts beyond `postgres` and loopback, and mismatching PostgreSQL
fallback hosts. Keep delivery files protected; do not stream credential JSON to
stdout. Auth generates all secrets through the existing MachineService, grants
only the fixed Catalog read authority, delivers the credential, then enables the
machine. Its append-only `machine-journal.jsonl` synchronizes machine/credential
intent IDs **before** database calls. Existing journals, legacy receipts or
credential files block bootstrap. On any uncertain outcome, inspect records by
those IDs; never retry in a new directory, blindly create another identity, or
assume a missing acknowledgement means rollback. A torn final journal line does
not invalidate prior records; preserve the entire journal for reconciliation.
These checks do not claim a filesystem/power-loss fault-injection test.

Catalog accepts a bounded strict selection JSON file; copy and fill
`Catalog-Service/cmd/local-stock-admin/selection.example.json`. First inspect **all**
variants sharing the selected unit and explicitly confirm physical piece meaning.
Only selected variants become eligible. There is no pack creation or stock posting.
Classification and each eligibility call use existing local transactions; the
operator plan is not one all-or-nothing multi-variant transaction. After failure,
inspect existing definitions before any authorized continuation. Do not rebind
units/products or rewrite pack history.

Human authority is a separate reviewed administration step: select the actual user,
verify identity, and use a dedicated role granting only `inventory.opening-stock:post`
with GLOBAL/null scope. Preserve existing roles and grants. No shared script creates
users, guesses credentials or assigns an actual deployment's human UUID. If only SQL
administration is available, review a checked transaction with explicit user/role
IDs, exact permission lookup, lock/statement deadlines and postcondition checks.

## Validate and operate the explicit overlay

From ERP-Platform, using absolute paths:

```powershell
pwsh -NoProfile -File ./scripts/opening-local-compose.ps1 `
  -LocalEnvFile $ProtectedLocalEnvFile -BaseEnvFile $ReviewedBaseEnvFile `
  -ProjectName $LocalProjectName -Action Validate

pwsh -NoProfile -File ./scripts/opening-local-compose.ps1 `
  -LocalEnvFile $ProtectedLocalEnvFile -BaseEnvFile $ReviewedBaseEnvFile `
  -ProjectName $LocalProjectName -Action Status
```

`Build` and `Up` require an explicit `-Services` list limited to auth-service,
catalog-service, inventory-service and kong. They require separate rollout
authorization. `Up` uses `--no-deps`; PostgreSQL is excluded. The wrapper rejects
remote Docker endpoints and never dumps expanded configuration. BaseEnvFile defaults
to the existing ERP-Platform/.env, while the protected LocalEnvFile is mandatory.

The wrapper is optional: its complete equivalent is `docker compose --project-name
<local-project> --env-file <base-env> --env-file <protected-local-env> -f
docker-compose.yml -f docker-compose.opening-local.yml <explicit-operation>`.
Always include both files on future recreations; base-only Compose would remove
the optional local TLS configuration. Do not automatically migrate/reprovision or
recreate the normal setup when reviewing this PR.

Existing protected `security-work` wrappers/material remain local and unchanged.
Their `OPENING_LOCAL_DIR`/`OPENING_LOCAL_MACHINE_ID` contract still applies to the
overlay. No private pointer file or undocumented wrapper is required for a new
checkout using the public instructions above.

## Verification and maintenance

```powershell
pwsh -NoProfile -File ./scripts/test-local-opening-provisioning.ps1
pwsh -NoProfile -File ./scripts/test-opening-local-configuration.ps1
```

The first harness uses only uniquely labelled tmpfs PostgreSQL, generated passwords,
marker-checked loopback databases and synthetic records; it tests real service
provisioning and simulated uncertain-acknowledgement seams. It has no normal fallback.
The second uses newly generated temporary trust/configuration only; it never starts
the normal services. Inspect exit codes; fixture-gated skips in ordinary Go tests
are not runtime proof.

Earlier local enablement verified fresh human login, preparation and stock reads;
**normal stock posting/replay acceptance was not performed and remains pending**.
Preparation count 1 is a non-posting check, not an opening entry. Prior disposable
posting/replay verification is separate evidence; it does not authorize business data.
The local reference probe creates no Inventory DB connection, stock writes or key
claims and emits no tokens. Human-machine token separation remains unchanged.

Maintain expiring machine credentials and certificates before expiry; backend
credential expiry/rotation/revocation and five-minute JWT policies still apply.
Revocation stops future issuance; issued JWTs may survive through expiry plus the
approved clock tolerance. Never remove stock integrity guards while writers remain
enabled. Retain backups and reconcile metadata before recovery; never automatically
restore/drop databases. Full Inventory Postman collection/environment and automation
remain a later deliverable. Inventory Service is not complete.
