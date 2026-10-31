#!/bin/sh
set -eu
: "${FIXTURE_PASSWORD:?}" "${FIXTURE_RUN_ID:?}"
case "$FIXTURE_RUN_ID" in purchasing-gateway-????????????????????????????????) ;; *) exit 1;; esac
for entry in auth_fixture:auth_purchasing_gateway catalog_fixture:catalog_purchasing_gateway inventory_service:inventory_db purchasing_service:purchasing_db; do
 role=${entry%%:*}; database=${entry#*:}
 psql -X -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -v role="$role" -v password="$FIXTURE_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION', :'role', :'password') \gexec
SQL
 createdb -U "$POSTGRES_USER" -O "$role" "$database"
 psql -X -U "$POSTGRES_USER" -d "$database" -v ON_ERROR_STOP=1 -v role="$role" -v database="$database" -v run="$FIXTURE_RUN_ID" <<'SQL'
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC;GRANT CONNECT ON DATABASE %I TO %I', :'database', :'database', :'role') \gexec
CREATE TABLE purchasing_gateway_fixture_ownership(run_id TEXT PRIMARY KEY);
INSERT INTO purchasing_gateway_fixture_ownership VALUES(:'run');
SELECT format('ALTER TABLE purchasing_gateway_fixture_ownership OWNER TO %I', :'role') \gexec
SQL
 done
createdb -U "$POSTGRES_USER" -O purchasing_service purchasing_failure
