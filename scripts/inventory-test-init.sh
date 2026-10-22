#!/bin/sh
# Only mounted by the disposable inventory test overlay. Never normal databases.
set -eu
psql -X --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 <<'SQL'
\getenv fixture_password INVENTORY_FIXTURE_PASSWORD
SELECT format('CREATE ROLE inventory_service LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION', :'fixture_password')
\gexec
CREATE DATABASE inventory_db OWNER inventory_service;
SQL
