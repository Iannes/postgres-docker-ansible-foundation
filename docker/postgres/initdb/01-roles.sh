#!/usr/bin/env bash
# =============================================================================
# Smart Market — PostgreSQL Bootstrap: Role Provisioning
# =============================================================================
# PURPOSE
#   Runs once when the PostgreSQL data directory is first initialised
#   (i.e. on the first 'docker compose up' against a new or empty volume).
#   It does NOT run on subsequent container starts.
#
# SCOPE
#   Bootstrap only. This script creates roles and the application schema.
#   It does NOT create tables, indexes, or any application-level objects.
#   Schema migrations are owned by the pipeline layer (e.g. golang-migrate,
#   Flyway, Liquibase) — not by this script.
#
# ROLES CREATED
#   smartmarket_migrations
#     DDL rights on the smartmarket schema. Used by the pipeline migration
#     runner to apply schema changes. Not used at runtime.
#
#   smartmarket_pipeline
#     DML rights (SELECT, INSERT, UPDATE, DELETE) on tables in the smartmarket
#     schema. Used by the pipeline at runtime. No DDL access.
#
# IDEMPOTENCY
#   Each role is created only if it does not already exist.
#   Passwords are always updated to the current env var value, so rotating
#   credentials is safe to apply by re-initialising (or running manually).
#
# DEFAULT PRIVILEGES
#   Any table created by smartmarket_migrations in the smartmarket schema
#   is automatically granted SELECT/INSERT/UPDATE/DELETE to smartmarket_pipeline.
#   This means migration-created tables are immediately accessible to the
#   pipeline without additional GRANT statements.
#
# REQUIRED ENVIRONMENT VARIABLES
#   POSTGRES_USER                   — superuser name (set by Docker image)
#   POSTGRES_DB                     — target database (set by Docker image)
#   SMARTMARKET_MIGRATIONS_PASSWORD — password for smartmarket_migrations role
#   SMARTMARKET_PIPELINE_PASSWORD   — password for smartmarket_pipeline role
# =============================================================================

set -euo pipefail

# Verify required env vars are present and non-empty before doing anything.
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${SMARTMARKET_MIGRATIONS_PASSWORD:?SMARTMARKET_MIGRATIONS_PASSWORD is required}"
: "${SMARTMARKET_PIPELINE_PASSWORD:?SMARTMARKET_PIPELINE_PASSWORD is required}"

echo "[initdb:01-roles] Starting role provisioning for database: ${POSTGRES_DB}"

# psql connects via unix socket (local connection). pg_hba.conf treats local
# connections as 'trust' by default in the Docker image, so no password is
# needed here. POSTGRES_HOST_AUTH_METHOD applies to TCP connections only.
psql -v ON_ERROR_STOP=1 \
     --username "${POSTGRES_USER}" \
     --dbname   "${POSTGRES_DB}" \
<<-EOSQL

    -- -------------------------------------------------------------------------
    -- Role: smartmarket_migrations
    -- Owns DDL: used by the migration runner to CREATE/ALTER/DROP objects.
    -- Never used for application runtime connections.
    -- -------------------------------------------------------------------------
    DO \$\$
    BEGIN
        IF NOT EXISTS (
            SELECT FROM pg_catalog.pg_roles WHERE rolname = 'smartmarket_migrations'
        ) THEN
            CREATE ROLE smartmarket_migrations
                WITH LOGIN
                     NOSUPERUSER
                     NOCREATEDB
                     NOCREATEROLE
                     NOINHERIT
                     NOREPLICATION;
            RAISE NOTICE 'Created role: smartmarket_migrations';
        ELSE
            RAISE NOTICE 'Role smartmarket_migrations already exists — skipping CREATE';
        END IF;
    END
    \$\$;
    -- Update password unconditionally so credential rotation is applied on re-init.
    ALTER ROLE smartmarket_migrations WITH PASSWORD '${SMARTMARKET_MIGRATIONS_PASSWORD}';

    -- -------------------------------------------------------------------------
    -- Role: smartmarket_pipeline
    -- DML only: SELECT, INSERT, UPDATE, DELETE on application tables.
    -- No DDL rights. Cannot create or alter schema objects.
    -- -------------------------------------------------------------------------
    DO \$\$
    BEGIN
        IF NOT EXISTS (
            SELECT FROM pg_catalog.pg_roles WHERE rolname = 'smartmarket_pipeline'
        ) THEN
            CREATE ROLE smartmarket_pipeline
                WITH LOGIN
                     NOSUPERUSER
                     NOCREATEDB
                     NOCREATEROLE
                     NOINHERIT
                     NOREPLICATION;
            RAISE NOTICE 'Created role: smartmarket_pipeline';
        ELSE
            RAISE NOTICE 'Role smartmarket_pipeline already exists — skipping CREATE';
        END IF;
    END
    \$\$;
    ALTER ROLE smartmarket_pipeline WITH PASSWORD '${SMARTMARKET_PIPELINE_PASSWORD}';

    -- -------------------------------------------------------------------------
    -- Application schema
    -- Owned by smartmarket_migrations (it will CREATE objects here).
    -- smartmarket_pipeline gets USAGE so it can reference schema-qualified names.
    -- Table-level grants are set via DEFAULT PRIVILEGES below; individual GRANT
    -- statements on tables are the migration runner's responsibility if needed.
    -- -------------------------------------------------------------------------
    CREATE SCHEMA IF NOT EXISTS smartmarket
        AUTHORIZATION smartmarket_migrations;

    GRANT USAGE ON SCHEMA smartmarket TO smartmarket_pipeline;

    -- -------------------------------------------------------------------------
    -- Default privileges
    -- Any table (or sequence) that smartmarket_migrations creates in this schema
    -- is automatically accessible to smartmarket_pipeline. This eliminates the
    -- need for post-migration GRANT statements on individual tables.
    -- -------------------------------------------------------------------------
    ALTER DEFAULT PRIVILEGES
        FOR ROLE smartmarket_migrations
        IN SCHEMA smartmarket
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO smartmarket_pipeline;

    ALTER DEFAULT PRIVILEGES
        FOR ROLE smartmarket_migrations
        IN SCHEMA smartmarket
        GRANT USAGE, SELECT ON SEQUENCES TO smartmarket_pipeline;

EOSQL

echo "[initdb:01-roles] Role provisioning complete."
