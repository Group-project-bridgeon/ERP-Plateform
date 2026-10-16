# Catalog security verification record

Status recorded on 2026-10-16. This document distinguishes user-reported runtime
evidence from checks executed by the finalizing agent. No runtime services,
migrations, permissions or database records were changed during Git finalization.

## User-reported runtime evidence

The user reported these results before finalization; the agent did not rerun
these runtime checks during this Git task:

| Check | Reported result |
|---|---|
| Isolated Docker/Kong security integration suite | Exit 0 |
| Normal Auth migration state | Version 5, dirty=false |
| Auth and Catalog containers | Healthy |
| Catalog host port 8081 | Not published |
| Anonymous Catalog request through Kong | HTTP 401 |
| Test user without brands read permission | GET brands HTTP 403 |
| Same user after controlled read-only assignment and fresh login | GET brands HTTP 200 |
| Same read-only user | POST brands HTTP 403 |
| Auth-to-Catalog request on the Docker network without a token | HTTP 401 |

The isolated harness covers login, authenticated /me, local verification of the
actual RS256 token, GLOBAL versus WAREHOUSE grants, brand read/create/update/status
and denied-write persistence assertions. Its reported passing run does not imply
that every Catalog CRUD endpoint was exercised live. The normal-stack results
above are the explicitly reported smoke checks, not a full regression run.

## Agent-executed review and checks

Earlier agent-run tests, vet and builds passed in both original Go repositories.
During finalization, review found that Auth decoded missing/null token_version as
zero and accepted quoted numeric timestamps, while Catalog rejected these forms.
A new signed-token regression test reproduced five failing cases (exit 1), then
passed after strict JSON claim decoding was added (exit 0). Issued tokens and
required configuration are unchanged. The reported Docker run predates this
small validation correction; it was not rerun during finalization.

Finalization checks executed by the agent:

| Check | Result |
|---|---|
| Authentication: go test -count=1 -json ./... | Exit 0; 82 top-level tests and 81 subtests passed |
| Catalog-Service: go test -count=1 -json ./... | Exit 0; 141 top-level tests and 374 subtests passed |
| go vet ./... and go build ./..., both repositories | All exit 0 |
| Normal and isolated Compose config --quiet with example/placeholder values | Both exit 0; no services started |
| PowerShell script syntax parsing | Passed |
| git diff --check and staged --check, all repositories | Passed |
| Exact staged-file/outgoing-diff review and credential/artifact scans | Passed; no real secrets or unrelated artifacts found |

Three Auth integration tests skipped because TEST_DATABASE_URL and
ERP_SECURITY_ISOLATED were unset: TestCatalogSecurityThroughKong,
TestPermissionRepo_GetGlobalPermissions_Integration, and
TestTransactionManager_RollsBackUserInsert. These skips are not runtime successes.
No actual credentials, JWTs, keys or database records are included here.

## Implemented behavior

- Auth signs RS256 JWTs with issuer erp-auth, audience erp-api, explicit identity
  and token_version, and GLOBAL-only resource:action permission arrays.
- Both services enforce required numeric timestamps and the 15-minute maximum.
  Catalog checks signatures locally without Auth HTTP/database lookups.
- Catalog protects all 58 business endpoints. Missing/invalid tokens return 401;
  missing exact permissions return 403. GET /health and GET /ready remain public.
- Product-detail reads require all five component read permissions; unlisted
  routes are denied. No wildcard or administrator bypass exists.
- Migration 000005 defines 33 permissions but grants none to users or roles.
  Its down migration deliberately retains definitions to preserve existing grants.
- Auth receives only the private key and Catalog only its matching public key,
  mounted read-only with create_host_path=false. Catalog has no default host port.
  The optional development override exposes only a loopback port.

## Coordinated deployment and remaining limits

These changes span Authentication, Catalog-Service and ERP-Platform and must be
rolled out together. Configure the matching RSA key pair, shared issuer/audience,
Auth lifetime and migration 000005 before serving authenticated Catalog traffic.
Deploying Auth's RS256 cutover with old configuration or secured Catalog without
its public-key configuration can break startup or access. Existing HS256 tokens
must be replaced by fresh login tokens. Never mount the private key into Catalog.

After a permission assignment, log in again. Catalog does not immediately detect
permission removal, user deactivation or token_version increments; an already
issued token may remain usable until expiry, up to 15 minutes. Auth /me still
checks its user database. Role assignment is an explicit administrative action;
migration 000005 does not grant access.

All-route authorization is covered by automated router tests. Live CRUD coverage
is limited to the isolated brand workflow and the reported normal-stack smoke
checks. The latest strict claim-decoding fix has local regression coverage, not
a new Docker run. No merge or deployment is part of Git finalization.

See [deployment and repeatable verification](catalog-security-verification.md)
and the Catalog-Service docs/security.md endpoint matrix for operational steps.
