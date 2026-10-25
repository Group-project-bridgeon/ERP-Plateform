# Inventory Docker/Kong verification record

Latest checkpoint: **2026-10-25 — GATEWAY VERIFIED for Stock Read APIs**, recorded
at the end of this document. The original warehouse-delivery record below remains
historical and is not evidence of normal deployment.

Executed 2026-10-22. Verdict: READY FOR REVIEW.
Implementation complete; isolated verification passed; normal deployment not performed.

## Baselines and branches

- Inventory: development/origin at 7238613d7558293d4f8539426ed2d7c03b00fe75;
  work branch chore/inventory-docker.
- Platform: development/origin at b450cc10fc6b8c136776afddd977cd71643b8cb7;
  work branch chore/inventory-platform-integration.
- Auth: development at 3490657647869f5b34c63b47ab74a950850b3bc7, unchanged.
- Catalog: development at b60cb583f5009fe0272013e80ac8704500aa77fb, unchanged.

All four origin remotes were fetched successfully after sandbox DNS restrictions
were bypassed through an approved unrestricted retry. All local development
baselines matched origin/development; warehouse and Auth 000006 prerequisites
were already merged. No merge or history manipulation was performed.

## Commands and actual results

| Check | Result | Exit |
| --- | --- | --- |
| go test -count=1 ./... (Inventory) | Passed; ordinary fixture tests skipped without explicit flags | 0 |
| go vet ./... (Inventory) | Passed | 0 |
| go build ./... (Inventory) | Passed | 0 |
| changed Go file gofmt | Passed | 0 |
| test-inventory-gateway.ps1 -ConfigurationOnly | Both Compose models and isolation assertions passed | 0 |
| test-inventory-gateway.ps1 (full, final source) | All image/parser/runtime/HTTP/DB/shutdown/cleanup assertions passed | 0 |
| git diff --check and new-file whitespace checks | Passed | 0 |

The full runner includes normal `docker compose config --quiet` with placeholder
.env.example, fixture config validation, Kong 3.9.3 `kong config parse` in DB-less
mode, effective build-context inspection and real Auth/Catalog/Inventory builds.
Both final full runs passed; the final run includes expanded partial-build image
cleanup. Docker was initially stopped; the user started Desktop. Initial parser
invocation incorrectly used Kong's default database mode; explicitly setting
KONG_DATABASE=off corrected it. Configuration-only checks exposed and corrected
stderr warnings entering JSON and Windows separator comparison. Failed attempts
were reported as failures and generated temporary files were cleaned.

## Runtime and request evidence

- Actual Auth, Catalog and Inventory runtime UID: 100 each.
- Inventory public key readable by actual app user; no private-key mount; no
  Inventory host port binding; binary-only app and no baked .env/source tree.
- Internal Inventory /health and /ready: 200; direct anonymous warehouse call: 401.
- Inventory migrate 1:false; Auth 6:false; Catalog 2:false.
- Inventory DB role has no superuser/create-db/create-role privileges.
- Inventory password deliberately contained URI-reserved characters. Both migrate
  and runtime connected successfully using password-free URLs plus PGPASSWORD.
- Four real Auth logins and /me through Kong: 200 each; signatures, matching keys,
  issuer/audience/time/user/version/permission contract validated locally.
- Anonymous, invalid and expired tokens: 401. The expired token was locally signed
  solely for the negative test; successful tokens all came from real login.
- No permissions and WAREHOUSE-only assignments: 403. Reader list/detail: 200,
  writes: 403. Editor creates: 201; update/promotion/status: 200.
- Duplicate normalized code: 409. Current-default deactivation and inactive
  promotion: 409. Authorized promotion and former-default deactivation persisted.
- Full warehouse snapshot unchanged after denied mutations. Final persisted count:
  two warehouses, one active default; expected names/active flags verified.
- Gateway root /health and /ready: 404. Routed nonexistent warehouse: 404.
  Existing Catalog route: anonymous 401, valid Inventory-only token 403, proving
  the preserved route reached Catalog's own permission enforcement. Auth routes
  were exercised by real login and /me.
- Inventory stopped on SIGTERM with exit code 0.

## Cleanup and preserved environment

Runner confirmed no containers or networks remained for its unique project.
Only project-specific images were removed. PostgreSQL used tmpfs, so all fixture
identities, grants and warehouse rows disappeared with the container. Temporary
keys/binaries/context files were removed and prior environment was restored.
No normal Compose down, volume deletion, migration, role/password/key change,
service rebuild/restart, commit, push, PR or merge was performed.

Six existing ERP container IDs, states and start times matched before/after the
fixture. This comparison begins after the user started Docker Desktop; it does
not claim Docker Desktop startup left previously stopped containers stopped.
Existing Platform .vscode/settings.json was preserved. Auth/Catalog source trees
remained clean. Changed/new source remains unstaged on the two work branches.

## Unverified and operator follow-up

The normal stack has not loaded these application or Kong changes, and normal
migration/credential/key readiness was not tested. Follow the separate deployment
proposal in inventory-docker-integration.md after review, backup and approval.
Changing .env does not rotate a PostgreSQL role password. Existing permission
definitions do not grant access; fresh-login GLOBAL assignments require the
approved role workflow. Resolve prior credential-exposure follow-ups separately.
This milestone does not complete the Inventory service or ERP; Fulfillment/Delivery
is planned as a separate internal Inventory module and stock workflows remain later.

## Stock Read APIs gateway verification (2026-10-25)

Verdict: **GATEWAY VERIFIED** in the disposable fixture. Normal deployment, normal
grants and the wider Stock Foundation/Inventory Service remain incomplete.

The fixture now asserts actual migrated versions Inventory 3:false, Auth 8:false
and Catalog 3:false. Auth's two stock-read definitions exist without application
migrations assigning users/grants. Test setup explicitly creates six isolated
human profiles and authenticates them through real Auth login and /me via Kong.

| Identity / negative case | Balances | Movements |
| --- | --- | --- |
| Missing / malformed / tampered / locally signed expired token | 401 | 401 |
| Real login, no stock grants | 403 | 403 |
| Real login, balance-only GLOBAL grant | 200 | 403 |
| Real login, movement-only GLOBAL grant | 403 | 200 |
| Real login, both GLOBAL grants | 200 | 200 |
| Real login, equivalent WAREHOUSE-only grants | 403 | 403 |
| Real login, warehouse-management read only | 403 | 403 |

Routes are GET /api/v1/inventory/warehouses/:id/stock-balances with
inventory.stock-balances:read, and GET on /stock-movements with
inventory.stock-movements:read. Positive status/data assertions and Kong Via
headers prove the full path and Authorization header reached Inventory.

The unchanged warehouse gateway regression passed first (11.72s). The new
TestStockReadGateway passed (3.54s; package 6.660s). Real internal posting with
explicit synthetic references created 105 balances, 107 movements, eight operations
and eight completed keys across two populated new warehouses plus an empty one.
The first populated warehouse was then made inactive. There were five warehouses
in total, including the two preserved warehouse-regression records.

The main variant received 9007199254741093 pieces and issued three, leaving
9007199254741090, verified against PostgreSQL and exact string JSON. Another pair
returned to zero; selected packs retain factor six and historical labels. Gateway
checks covered variant/nonzero filtering, warehouse isolation, 50/100 limits,
complete static pagination, cursor/filter/warehouse mismatch rejection, malformed
input 400, nonexistent warehouse 404 and existing empty items:[].

The fixture Catalog service was stopped before stock setup/read checks. Optional
reference clients stayed disabled. Product/pack snapshots came from synthetic test
adapters; no live Catalog provenance is claimed. Before/after stock-table SHA256:
fd4c86982ac393bec4a162dfd3aaf7e18020f03a9e04072e0fe11a0db3dabf41
matched exactly over balances, operations, movements and idempotency records.

Actual final commands/checks:

- PowerShell parser: passed. -ConfigurationOnly: exit 0, without runtime claims.
- Full scripts/test-inventory-gateway.ps1: exit 0, real Kong 3.9.3, actual Auth login
  and /me, existing warehouse/Auth/Catalog route regressions and stock reads passed.
- Auth, Catalog and Inventory runtime UID=100; internal Inventory health/ready 200;
  no published Inventory port; fixture role is non-superuser/non-role-creator.
- Inventory go test ./internal/security ./internal/router ./internal/integration:
  exit 0; ordinary fixture cases skip without flags. Explicit ungated new-test run
  reports SKIP; the full harness supplies the runtime evidence.
- go vet ./internal/integration and go build ./...: exit 0; changed Go formatting,
  fixture parser and scoped whitespace checks passed.
- Inventory SIGTERM exit 0. Fixture containers/network/images/temp files were
  cleaned and environment restored. All 36 pre-existing container IDs/start times/
  running states/restart counts matched before/after.

Gateway machine-token coverage is NOT TESTED: the human-login fixture deliberately
does not enable TLS machine issuance. Existing Inventory security/router tests keep
the separation evidence. No concurrent-write snapshot-stability or real network
disruption claim is made. Successful tokens are actual login-issued; the locally
signed expired token is solely a labeled negative test.

Detailed source/state/check evidence is in workspace
review-artifacts/stock-read-gateway/20261025T064438Z/report.md. Existing Inventory
warehouse_test.go and all previous source/migrations/dirty work are byte-preserved;
the new Go test is separate. Authentication/Catalog source, normal Compose, Kong
configuration, real .env/keys/accounts and normal services were unchanged.
