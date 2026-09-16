-- ─────────────────────────────────────────────────────────────────────────────
-- Datadog Database Monitoring (DBM) setup for the PostgreSQL 'ledger' database.
--
-- Applied by `make dbm-setup` (also auto-run by `make deploy-k8s-dd` when a DBM
-- password is present). Idempotent — safe to re-run.
--
-- Requires the psql variable `dbm_password` to be set, e.g.:
--   psql -U finance -d ledger -v ON_ERROR_STOP=1 -v dbm_password='...' -f dbm-setup.sql
--
-- Server prerequisite (already satisfied in postgres.yaml args):
--   shared_preload_libraries = 'pg_stat_statements'
--
-- Docs: https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Read-only monitoring role. Create only if missing; always (re)sync the
--    password so it matches DATADOG_DBM_PASSWORD / the datadog-secret.
--    (\gexec runs the generated CREATE ROLE only when the role is absent, so
--    this stays idempotent under ON_ERROR_STOP=1.)
SELECT 'CREATE ROLE datadog WITH LOGIN'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'datadog')
\gexec
ALTER ROLE datadog WITH PASSWORD :'dbm_password';

-- 2. Monitoring grants (pg_monitor covers pg_stat_*, pg_stat_statements, etc.)
GRANT pg_monitor TO datadog;
GRANT SELECT ON pg_stat_database TO datadog;

-- 2b. Table-level grant for the Finance-specific custom_queries in
--     postgres-check.yaml (finance.db.ledger.pending_count / failed_count).
--     pg_monitor only covers system catalogs/stat views, not application
--     tables, so the 'transactions' table needs an explicit read-only grant.
GRANT SELECT ON transactions TO datadog;

-- 3. Query metrics extension.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 4. Datadog schema + explain function — enables EXPLAIN plans on query samples.
--    Without this you still get query metrics/samples, but no execution plans.
CREATE SCHEMA IF NOT EXISTS datadog;
GRANT USAGE ON SCHEMA datadog TO datadog;
GRANT USAGE ON SCHEMA public TO datadog;

CREATE OR REPLACE FUNCTION datadog.explain_statement(
   l_query TEXT,
   OUT explain JSON
)
RETURNS SETOF JSON AS
$$
DECLARE
   curs REFCURSOR;
   plan JSON;
BEGIN
   OPEN curs FOR EXECUTE pg_catalog.concat('EXPLAIN (FORMAT JSON) ', l_query);
   FETCH curs INTO plan;
   CLOSE curs;
   RETURN QUERY SELECT plan;
END;
$$
LANGUAGE 'plpgsql'
RETURNS NULL ON NULL INPUT
SECURITY DEFINER;
