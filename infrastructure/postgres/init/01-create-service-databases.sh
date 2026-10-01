#!/usr/bin/env sh
set -eu

create_service_database() {
    role_name="$1"
    database_name="$2"
    role_password="$3"

    echo "Configuring database: ${database_name}"

    psql \
        --username "$POSTGRES_USER" \
        --dbname postgres \
        --set=role_name="$role_name" \
        --set=role_password="$role_password" \
        --set=ON_ERROR_STOP=1 <<'EOSQL'
SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
    :'role_name',
    :'role_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'role_name'
)
\gexec
EOSQL

    database_exists="$(
        psql \
            --username "$POSTGRES_USER" \
            --dbname postgres \
            --tuples-only \
            --no-align \
            --command="SELECT 1 FROM pg_database WHERE datname = '$database_name';"
    )"

    if [ "$database_exists" != "1" ]; then
        createdb \
            --username "$POSTGRES_USER" \
            --owner "$role_name" \
            "$database_name"
    fi

    psql \
        --username "$POSTGRES_USER" \
        --dbname postgres \
        --set=database_name="$database_name" \
        --set=role_name="$role_name" \
        --set=ON_ERROR_STOP=1 <<'EOSQL'
SELECT format(
    'REVOKE CONNECT ON DATABASE %I FROM PUBLIC',
    :'database_name'
)
\gexec

SELECT format(
    'GRANT CONNECT ON DATABASE %I TO %I',
    :'database_name',
    :'role_name'
)
\gexec
EOSQL
}

create_service_database auth_service auth_db "$AUTH_DB_PASSWORD"
create_service_database catalog_service catalog_db "$CATALOG_DB_PASSWORD"
create_service_database party_service party_db "$PARTY_DB_PASSWORD"
create_service_database purchasing_service purchasing_db "$PURCHASING_DB_PASSWORD"
create_service_database inventory_service inventory_db "$INVENTORY_DB_PASSWORD"
create_service_database sales_service sales_db "$SALES_DB_PASSWORD"
create_service_database returns_service returns_db "$RETURNS_DB_PASSWORD"
create_service_database finance_service finance_db "$FINANCE_DB_PASSWORD"
create_service_database reporting_service reporting_db "$REPORTING_DB_PASSWORD"
create_service_database notification_service notification_db "$NOTIFICATION_DB_PASSWORD"

echo "ERP service databases and roles created successfully."