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

## Inventory Docker and gateway integration

See [Inventory build/start flow, isolated verification and deployment proposal](docs/inventory-docker-integration.md). Run `pwsh -NoProfile -File ./scripts/test-inventory-gateway.ps1` for disposable verification. Normal infrastructure is not deployed by the test.


Disposable Stock Adjustments verification: run
`pwsh -NoProfile -File scripts/test-inventory-gateway.ps1 -StockAdjustments` from this
repository (or use its explicit workspace path). It adds the Opening HTTPS fixture
and `docker-compose.adjustment-test.yml`, generates isolated keys/credentials,
applies current Auth 11 / Inventory 6 / Catalog 3 only in the run-owned project, and tests
real human login, secured machine/Catalog references, deltas, whole reversal,
balance/history and replay through Kong. It leaves normal Compose/configuration
unchanged and removes owned fixtures. This is not normal feature enablement or
normal Opening Stock posting acceptance.


Disposable reservation acceptance (Milestone 8):

```powershell
pwsh -NoProfile -File scripts/test-inventory-gateway.ps1 -Reservations
```

This includes Opening/adjustment/read/warehouse regressions and the disposable-only
`docker-compose.reservation-test.yml`. It generates short-lived synthetic Sales
clients, isolated TLS keys/certificates and tmpfs databases, migrates Auth 11 /
Inventory 6 / Catalog 3, and exercises actual Auth HTTPS issuance, exact machine
scope/audience/ownership checks, Catalog HTTPS references, reserve/release/consume,
replay and held-stock protection through Kong. A second phase stops only its own
Catalog fixture and checks completed replay/status/release without Catalog. Kong's
temporary HTTPS listener verifies its generated certificate and localhost hostname.
The script removes only its ownership-marked project/material and checks existing
normal containers remain unchanged. It does not provision normal Sales identities,
change normal TLS/Compose, enable flags, post normal stock or prove real Sales use.

The Inventory PostgreSQL harness `scripts/test-reservations-postgres.ps1` separately
covers local transaction races, immutable SQL guards, legacy replay, migrations and
simulated uncertain-commit faults, plus Auth scoped-grant lifecycle persistence.
See [Inventory reservation specification](../Inventory-Service/docs/stock-reservations-spec.md)
for the proposed Sales contract, strict reserve-before-cancel protocol, default-off
rollout prerequisites and deferred expiry/partial workflows. Auth operator tooling
remains Catalog-specific; normal scoped machine provisioning needs its own reviewed
execution plan. Kafka/Outbox/Inbox/Saga and final Postman delivery remain later work.


Disposable Fulfillment / Delivery acceptance (Milestone9):

```powershell
pwsh -NoProfile -File scripts/test-inventory-gateway.ps1 -Fulfillment
```

This includes reservation, adjustment/correction, Opening, read and warehouse
regressions. The disposable-only docker-compose.fulfillment-test.yml enables the
module inside Inventory; there is no Delivery service. It uses Inventory7/Auth12/
Catalog3, generated fixture Sales credentials, real human logins and verified TLS
through Kong. It checks exact machine owner and human GLOBAL authority, one consume
per dispatch, no-stock draft/delivery/cancel, replay and Catalog-outage behavior.
A stopped Catalog may yield503/reference_unavailable or504/timeout; either must leave
no partial writes. Temporary human relogin credentials are synthetic, kept only in
the owned temporary fixture directory and removed on cleanup; JWTs are not saved.
Normal keys/env/TLS overlay, containers and volumes are not changed. Production stock
acceptance and real Sales integration are not claimed. Older verification sections
name their historical schema versions; current fixture migrations use latest sources.

The matching Inventory harness is scripts/test-fulfillment-postgres.ps1. It owns a
unique labelled tmpfs PostgreSQL container and generated credentials, checks legacy
upgrade/empty down/up/populated refusal, local races and simulated commit faults,
and cleans only owned resources. No normal credentials or database fallback exists.


## Purchasing platform integration

Purchasing now has service-owned migration/startup wiring and the dedicated `/api/v1/purchasing` Kong namespace. See [integration procedures and disposable verification](docs/purchasing-platform-integration.md). Normal rollout and legacy database adoption are separate, unperformed steps. The existing local TLS generated Kong file requires a reviewed future refresh; this task does not regenerate normal TLS or reload Kong.
