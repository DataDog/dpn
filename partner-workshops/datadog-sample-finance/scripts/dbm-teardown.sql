-- ─────────────────────────────────────────────────────────────────────────────
-- Datadog Database Monitoring (DBM) teardown for the PostgreSQL 'ledger'
-- database — reverses scripts/dbm-setup.sql.
--
-- Applied by `make undbm`. Idempotent — safe to re-run, safe to run even if
-- `make dbm` was never run (every statement below is a no-op in that case).
--
-- Usage:
--   psql -U finance -d ledger -v ON_ERROR_STOP=1 -f dbm-teardown.sql
--
-- Docs: https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Drop the explain-plan function + schema created for query samples.
DROP FUNCTION IF EXISTS datadog.explain_statement(TEXT);
DROP SCHEMA IF EXISTS datadog CASCADE;

-- 2. Revoke the Finance-specific table grant (postgres-check.yaml custom_queries).
REVOKE SELECT ON transactions FROM datadog;

-- 3. Revoke monitoring grants.
REVOKE SELECT ON pg_stat_database FROM datadog;
REVOKE pg_monitor FROM datadog;

-- 3b. Revoke the schema usage grant from dbm-setup.sql step 4 (public schema
--     usage, not the 'datadog' schema — that one is dropped via CASCADE
--     above). Without this, DROP ROLE below fails: "role datadog cannot be
--     dropped because some objects depend on it / privileges for schema
--     public".
REVOKE USAGE ON SCHEMA public FROM datadog;

-- NOTE: pg_stat_statements is left installed — it's a server-wide extension,
-- not owned by or scoped to the 'datadog' role, and other checks/queries may
-- rely on it. Dropping it here would be a bigger, unrelated change than
-- "undo what make dbm did".

-- 4. Drop the monitoring role itself, now that it owns nothing and has no
--    remaining grants. Only if it exists (keeps this idempotent).
DO $$
BEGIN
   IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'datadog') THEN
      DROP ROLE datadog;
   END IF;
END
$$;
