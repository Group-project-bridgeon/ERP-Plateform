# ERP Database Migration and SQL Access Standard

## 1. Purpose

This document defines the database migration and SQL access standard for all services in the Fashion Wholesale ERP.

The goals are:

- keep database schemas reproducible
- prevent manual undocumented schema changes
- maintain service database ownership
- allow team members to use a consistent database workflow
- allow sqlc or database/sql depending on the needs of each service

---

## 2. Database Ownership

Each microservice owns its own PostgreSQL database.

| Service | Database | Database User |
|---|---|---|
| Authentication | auth_db | auth_service |
| Catalog | catalog_db | catalog_service |
| Party | party_db | party_service |
| Purchasing | purchasing_db | purchasing_service |
| Inventory | inventory_db | inventory_service |
| Sales | sales_db | sales_service |
| Returns | returns_db | returns_service |
| Finance | finance_db | finance_service |
| Reporting | reporting_db | reporting_service |
| Notification | notification_db | notification_service |

A service must access only its own database.

Cross-service database queries are not allowed.

Cross-service physical foreign keys are not allowed.

Services communicate with other services through APIs or events.

---

## 3. ERP-Platform Responsibility

ERP-Platform owns the local database infrastructure.

ERP-Platform is responsible for:

- PostgreSQL Docker infrastructure
- creating service databases
- creating service database users
- database connection isolation
- infrastructure configuration

ERP-Platform does not create domain tables for individual services.

Example:

ERP-Platform creates:

auth_db

The Authentication service migrations create the Authentication tables inside auth_db.

---

## 4. Migration Tool

The standard migration tool for Go services is:

golang-migrate/migrate

Database schema migrations must use plain SQL migration files.

An ORM or application startup code must not be used as the main mechanism for automatically creating or changing production database schemas.

---

## 5. Migration Location

Migration files belong inside the repository of the service that owns the database.

Example:

Authentication/
    migrations/
        000001_initial_schema.up.sql
        000001_initial_schema.down.sql

Inventory/
    migrations/
        000001_initial_schema.up.sql
        000001_initial_schema.down.sql

Sales/
    migrations/
        000001_initial_schema.up.sql
        000001_initial_schema.down.sql

Domain migrations must not be stored inside ERP-Platform.

---

## 6. Migration Naming

Use sequential migration numbers.

Format:

NNNNNN_description.up.sql
NNNNNN_description.down.sql

Examples:

000001_initial_schema.up.sql
000001_initial_schema.down.sql

000002_add_refresh_tokens.up.sql
000002_add_refresh_tokens.down.sql

000003_add_stock_indexes.up.sql
000003_add_stock_indexes.down.sql

Migration numbers must not be reused.

After a migration has been merged and used by the team, do not rename or silently rewrite it.

Create a new migration for later schema changes.

---

## 7. Up and Down Migrations

The .up.sql file applies a schema change.

Example:

CREATE TABLE users (
    id UUID PRIMARY KEY,
    email TEXT NOT NULL UNIQUE
);

The corresponding .down.sql file reverses the change when a safe rollback is supported.

Example:

DROP TABLE users;

Down migrations must be reviewed carefully because destructive operations can remove data.

---

## 8. SQL Is Mandatory for Schema Changes

All database schema changes must be represented as SQL migrations.

This includes:

- CREATE TABLE
- ALTER TABLE
- CREATE INDEX
- constraints
- database indexes
- schema-level database objects

Manual changes made through pgAdmin, psql, or another database tool are not enough.

The equivalent migration must exist in Git.

Migration files are the source of truth for database schema evolution.

---

## 9. Application Database Access

SQL is the database query language used by all services.

For Go application code, a service may use either:

1. sqlc
2. Go database/sql with handwritten SQL

sqlc does not replace SQL.

With sqlc, developers still write SQL queries and sqlc generates type-safe Go code for executing those queries.

---

## 10. When to Use sqlc

sqlc is preferred for services that contain many database queries.

Examples include:

- Inventory
- Sales
- Purchasing
- Catalog
- Finance

sqlc is useful when a service has many operations such as:

- GetStock
- ReserveStock
- ReleaseStock
- CreateStockMovement
- FindOrder
- CreateOrder
- UpdateOrder
- ListPayments

Benefits include:

- generated type-safe Go code
- less repetitive row scanning code
- SQL remains visible and explicit
- compile-time integration with Go types
- easier maintenance when the number of queries grows

Example sqlc query:

-- name: GetUser :one
SELECT id, email
FROM users
WHERE id = $1;

sqlc generates the Go code used to execute the query.

---

## 11. When database/sql With Raw SQL Is Allowed

A service may use Go database/sql with handwritten SQL when:

- the service is small
- the number of queries is limited
- the developer is more comfortable with database/sql
- introducing sqlc would add unnecessary complexity

Example:

Authentication may use database/sql if its owner prefers that approach and the query layer remains manageable.

Using database/sql does not mean migrations can be skipped.

Schema migrations must still follow the same SQL migration standard.

---

## 12. Service-Level Consistency

Different services may use different query approaches.

Example:

Authentication
    -> database/sql + SQL

Catalog
    -> sqlc + SQL

Inventory
    -> sqlc + SQL

This is allowed because each microservice is independently implemented and owns its database access layer.

However, inside one service, developers should keep one primary database access approach.

Do not randomly mix sqlc and database/sql throughout the same service without a clear technical reason.

---

## 13. Recommended Project Standard

For this ERP project:

Database schema management:
    Always plain SQL migrations using golang-migrate.

Application database queries:
    sqlc is preferred for query-heavy services.

Small/simple services:
    database/sql with handwritten SQL is allowed.

This provides consistency for database schemas while allowing developers to choose an appropriate query implementation for each service.

---

## 14. Migration Connection Rule

Migrations must run using the credentials of the service that owns the database.

Examples:

auth_service
    -> auth_db

inventory_service
    -> inventory_db

sales_service
    -> sales_db

The PostgreSQL administrator account must not be used by normal service application code.

---

## 15. Schema Change Workflow

When a service requires a database schema change:

1. Pull the latest development branch.
2. Create a feature or chore branch.
3. Create the next migration files.
4. Apply the migration to the local service database.
5. Verify the resulting schema.
6. Test the application with the new schema.
7. Commit the migration with the related application changes.
8. Push the branch.
9. Create a Pull Request to development.
10. Review and merge the Pull Request.
11. Other developers pull the latest development branch.
12. Other developers apply the new migrations to their local databases.

---

## 16. Important Rules

Every service must follow these rules:

- modify only its own database
- do not create cross-service foreign keys
- do not directly query another service database
- do not commit .env files or real passwords
- do not perform undocumented manual schema changes
- keep migrations under version control
- use proper database constraints where appropriate
- create a new migration for later schema changes
- test migrations locally before merging them

---

## 17. Developer Environment Synchronization

Each developer runs their own local PostgreSQL environment.

Developers do not share PostgreSQL Docker volumes or database files through Git.

Git contains:

- infrastructure configuration
- application source code
- SQL migration files
- sqlc query/configuration files when sqlc is used

A developer should be able to reproduce the expected database schema by pulling the repository and applying all migrations.

---

## 18. Final Rule

Infrastructure ownership and schema ownership are separate.

ERP-Platform:

    creates and manages PostgreSQL infrastructure

Each microservice:

    owns and evolves its own database schema

For schema evolution:

    SQL migrations are mandatory

For Go application queries:

    sqlc is preferred for query-heavy services
    database/sql with handwritten SQL is allowed when appropriate
